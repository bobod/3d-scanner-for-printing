#if !targetEnvironment(simulator)
import AVFoundation
import Foundation
import OSLog
import RealityKit
// ObjectCaptureSession is declared in RealityKit's SwiftUI cross-import
// overlay, which only loads when both modules are imported.
import SwiftUI
import UIKit

/// Runs Apple's guided Object Capture (LiDAR-assisted image capture) and
/// then on-device photogrammetry to produce a textured USDZ model.
private let log = Logger(subsystem: "PrintScan3D", category: "ObjectCapture")

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
    /// Set when the session sits in `.initializing` for too long.
    @Published private(set) var initializationStalled = false

    let scanID: UUID
    let workspace: URL
    var modelURL: URL { workspace.appendingPathComponent("source.usdz") }
    private var imagesURL: URL { workspace.appendingPathComponent("Images", isDirectory: true) }
    private var checkpointURL: URL { workspace.appendingPathComponent("Checkpoint", isDirectory: true) }

    private var captureTasks: [Task<Void, Never>] = []
    private var reconstructionTask: Task<Void, Never>?
    private var photogrammetry: PhotogrammetrySession?
    private var pollTimer: Timer?
    private var isCancelled = false

    init(scanID: UUID, workspace: URL) {
        self.scanID = scanID
        self.workspace = workspace
    }

    // MARK: Capture

    func start() {
        guard session == nil else { return }
        Task {
            // Object Capture does not reliably prompt for camera access itself;
            // without it the session never leaves `.initializing`.
            let granted = await Self.requestCameraAccess()
            guard !isCancelled else { return }
            guard granted else {
                phase = .failed("Camera access is turned off. Enable it in Settings → Privacy & Security → Camera → PrintScan 3D.")
                return
            }
            startSession()
        }
    }

    /// Throws away the current session and images and starts over.
    func restart() {
        session?.cancel()
        tearDownCapture()
        try? FileManager.default.removeItem(at: imagesURL)
        try? FileManager.default.removeItem(at: checkpointURL)
        captureState = .initializing
        feedback = []
        userCompletedScanPass = false
        scanPasses = 1
        start()
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func startSession() {
        guard session == nil else { return }
        let fileManager = FileManager.default
        // The images folder must be empty when the session starts.
        try? fileManager.removeItem(at: imagesURL)
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: checkpointURL, withIntermediateDirectories: true)

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointURL
        // Over-capture images are only used by macOS reconstruction.
        configuration.isOverCaptureEnabled = false

        let session = ObjectCaptureSession()
        session.start(imagesDirectory: imagesURL, configuration: configuration)
        self.session = session
        initializationStalled = false
        UIApplication.shared.isIdleTimerDisabled = true

        log.info("Session started")

        captureTasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state)
                if case .completed = state { break }
                if case .failed = state { break }
            }
        })
        captureTasks.append(Task { [weak self] in
            for await feedback in session.feedbackUpdates {
                guard let self else { return }
                let messages = Self.messages(for: feedback)
                if self.feedback != messages { self.feedback = messages }
            }
        })

        // Pick up a state change that happened before `stateUpdates` was
        // subscribed. This is a one-off read: polling the session on the
        // main thread during detection can stall the UI.
        handle(session.state)

        // One-shot check instead of polling: offer a restart if the camera
        // never comes up.
        let startedSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.session === startedSession else { return }
            if case .initializing = self.captureState {
                log.error("Session still initializing after 10 s")
                self.initializationStalled = true
            }
        }
    }

    /// Photo count and pass completion only matter while capturing, so they
    /// are sampled (once a second) only in that state.
    private func updateCaptureCounters(active: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                // Only assign changed values: every @Published assignment
                // re-renders the capture screen, even if the value is equal.
                if self.shotsTaken != session.numberOfShotsTaken { self.shotsTaken = session.numberOfShotsTaken }
                if self.maximumShots != session.maximumNumberOfInputImages {
                    self.maximumShots = session.maximumNumberOfInputImages
                }
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
        isCancelled = true
        session?.cancel()
        tearDownCapture()
        photogrammetry?.cancel()
        reconstructionTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        // Updates arrive from both the async sequence and the initial read.
        guard case .capturing = phase, Self.key(for: state) != Self.key(for: captureState) else { return }
        log.info("State: \(Self.key(for: self.captureState)) -> \(Self.key(for: state))")
        captureState = state
        if initializationStalled, Self.key(for: state) != "initializing" { initializationStalled = false }
        if case .capturing = state {
            updateCaptureCounters(active: true)
        } else {
            updateCaptureCounters(active: false)
        }
        switch state {
        case .completed:
            // The capture session must be released before photogrammetry
            // starts so the device has enough memory to reconstruct.
            tearDownCapture()
            phase = .reconstructing
            reconstructionTask = Task { [weak self] in await self?.reconstruct() }
        case .failed(let error):
            log.error("Capture failed: \(error.localizedDescription)")
            tearDownCapture()
            phase = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private static func key(for state: ObjectCaptureSession.CaptureState) -> String {
        switch state {
        case .initializing: return "initializing"
        case .ready: return "ready"
        case .detecting: return "detecting"
        case .capturing: return "capturing"
        case .finishing: return "finishing"
        case .completed: return "completed"
        case .failed: return "failed"
        @unknown default: return "unknown"
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
