#if !targetEnvironment(simulator)
import Foundation
import RealityKit
import UIKit

/// Runs Apple's guided Object Capture (LiDAR-assisted image capture) and
/// then on-device photogrammetry to produce a textured USDZ model.
@MainActor
final class ObjectCaptureController: ObservableObject {

    enum Phase {
        case capturing
        case reconstructing
        case finished
        case failed(String)
    }

    static var isSupported: Bool {
        ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
    }

    @Published private(set) var phase: Phase = .capturing
    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var captureState: ObjectCaptureSession.CaptureState = .initializing
    @Published private(set) var feedback: [String] = []
    @Published private(set) var userCompletedScanPass = false
    @Published private(set) var shotsTaken = 0
    @Published private(set) var maximumShots = 0
    @Published private(set) var scanPasses = 1
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressMessage = "Preparing…"

    let scanID: UUID
    let workspace: URL
    var modelURL: URL { workspace.appendingPathComponent("source.usdz") }
    private var imagesURL: URL { workspace.appendingPathComponent("Images", isDirectory: true) }
    private var checkpointURL: URL { workspace.appendingPathComponent("Checkpoint", isDirectory: true) }

    private var captureTasks: [Task<Void, Never>] = []
    private var reconstructionTask: Task<Void, Never>?
    private var photogrammetry: PhotogrammetrySession?
    private var pollTimer: Timer?

    init(scanID: UUID, workspace: URL) {
        self.scanID = scanID
        self.workspace = workspace
    }

    // MARK: Capture

    func start() {
        guard session == nil else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: checkpointURL, withIntermediateDirectories: true)

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointURL
        configuration.isOverCaptureEnabled = true

        let session = ObjectCaptureSession()
        session.start(imagesDirectory: imagesURL, configuration: configuration)
        self.session = session
        UIApplication.shared.isIdleTimerDisabled = true

        captureTasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state)
                if case .completed = state { break }
                if case .failed = state { break }
            }
        })
        captureTasks.append(Task { [weak self] in
            for await feedback in session.feedbackUpdates {
                self?.feedback = Self.messages(for: feedback)
            }
        })

        // Counters are plain properties; sample them for the HUD.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                self.shotsTaken = session.numberOfShotsTaken
                self.maximumShots = session.maximumNumberOfInputImages
                if self.userCompletedScanPass != session.userCompletedScanPass {
                    self.userCompletedScanPass = session.userCompletedScanPass
                }
            }
        }
    }

    func startDetecting() {
        _ = session?.startDetecting()
    }

    func resetDetection() {
        session?.resetDetection()
    }

    func startCapturing() {
        session?.startCapturing()
    }

    func beginNewPass(flipped: Bool) {
        guard let session else { return }
        if flipped {
            session.beginNewScanPassAfterFlip()
        } else {
            session.beginNewScanPass()
        }
        scanPasses += 1
        userCompletedScanPass = false
    }

    func finishCapture() {
        session?.finish()
    }

    func cancel() {
        session?.cancel()
        tearDownCapture()
        photogrammetry?.cancel()
        reconstructionTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        captureState = state
        switch state {
        case .completed:
            // The capture session must be released before photogrammetry
            // starts so the device has enough memory to reconstruct.
            tearDownCapture()
            phase = .reconstructing
            reconstructionTask = Task { [weak self] in await self?.reconstruct() }
        case .failed(let error):
            tearDownCapture()
            phase = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private func tearDownCapture() {
        pollTimer?.invalidate()
        pollTimer = nil
        captureTasks.forEach { $0.cancel() }
        captureTasks.removeAll()
        session = nil
    }

    // MARK: Reconstruction

    private func reconstruct() async {
        progressMessage = "Processing images…"
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpointURL
            let photogrammetry = try PhotogrammetrySession(input: imagesURL, configuration: configuration)
            self.photogrammetry = photogrammetry
            defer { self.photogrammetry = nil }
            try photogrammetry.process(requests: [.modelFile(url: modelURL)])

            outputLoop: for try await output in photogrammetry.outputs {
                switch output {
                case .inputComplete:
                    progressMessage = "Building 3D model…"
                case .requestProgress(_, let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    throw error
                case .processingCancelled:
                    phase = .failed("Reconstruction was cancelled.")
                    return
                case .processingComplete:
                    break outputLoop
                default:
                    break
                }
            }

            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            // Raw images are large; only the model is kept.
            try? FileManager.default.removeItem(at: imagesURL)
            try? FileManager.default.removeItem(at: checkpointURL)
            progress = 1
            phase = .finished
        } catch {
            phase = .failed("Reconstruction failed: \(error.localizedDescription)")
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Feedback

    private static func messages(for feedback: Set<ObjectCaptureSession.Feedback>) -> [String] {
        feedback.compactMap { item in
            switch item {
            case .objectTooClose: return "Move farther away"
            case .objectTooFar: return "Move closer"
            case .movingTooFast: return "Move slower"
            case .environmentLowLight: return "More light needed"
            case .environmentTooDark: return "It's too dark"
            case .outOfFieldOfView: return "Aim at the object"
            case .objectNotFlippable: return "This object can't be flipped"
            case .overCapturing: return "Enough images here — move on"
            default: return nil
            }
        }
        .sorted()
    }

    deinit {
        captureTasks.forEach { $0.cancel() }
        reconstructionTask?.cancel()
    }
}
#endif
