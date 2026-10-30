#if !targetEnvironment(simulator)
import RealityKit
import SwiftUI

/// Full-screen guided capture: detect the object, orbit it (optionally
/// flipping it for the underside), then reconstruct on device.
struct ObjectCaptureFlowView: View {
    @StateObject private var controller: ObjectCaptureController
    let onFinish: () -> Void
    let onCancel: () -> Void

    init(scanID: UUID, workspace: URL, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: ObjectCaptureController(scanID: scanID, workspace: workspace))
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        Group {
            switch controller.phase {
            case .capturing:
                captureView
            case .reconstructing:
                ReconstructionProgressView(progress: controller.progress, message: controller.progressMessage) {
                    controller.cancel()
                    onCancel()
                }
            case .finished:
                ProgressView("Saving…")
                    .onAppear(perform: onFinish)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Close", action: onCancel)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { controller.start() }
    }

    @ViewBuilder
    private var captureView: some View {
        if let session = controller.session {
            ZStack {
                // Equatable so HUD updates (photo count, feedback) never
                // re-render Apple's camera view; it can freeze when redrawn often.
                CaptureCameraView(session: session, showPointCloud: controller.userCompletedScanPass)
                    .equatable()
                    .id(ObjectIdentifier(session)) // fresh view after Restart Camera
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    if controller.userCompletedScanPass {
                        passCompletePanel
                    } else {
                        bottomControls
                    }
                }
                .padding()
            }
        } else {
            ProgressView("Starting camera…")
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Cancel") {
                    controller.cancel()
                    onCancel()
                }
                .buttonStyle(.bordered)
                Spacer()
                if case .capturing = controller.captureState {
                    Text("Pass \(controller.scanPasses) · \(controller.shotsTaken)/\(controller.maximumShots) photos")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            if controller.initializationStalled {
                VStack(spacing: 8) {
                    Text("The camera is taking longer than usual to start.")
                        .font(.callout.weight(.medium))
                    Text("Close other camera or AR apps, make sure the phone isn't hot, then restart.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Restart Camera", systemImage: "arrow.clockwise") { controller.restart() }
                        .buttonStyle(.borderedProminent)
                }
                .multilineTextAlignment(.center)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let message = controller.feedback.first ?? instruction {
                Text(message)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var instruction: String? {
        switch controller.captureState {
        case .initializing: return "Starting LiDAR and camera…"
        case .ready: return "Center the object in the frame and tap Continue. For small objects, use a textured, non-reflective surface and fill most of the frame."
        case .detecting: return "Adjust the box to fit the object, then start capturing. If no box appears, move a little closer or farther away."
        case .capturing: return "Walk slowly around the object, keeping it in view."
        case .finishing: return "Finishing capture…"
        default: return nil
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch controller.captureState {
        case .ready:
            primaryButton("Continue", systemImage: "viewfinder") { controller.startDetecting() }
        case .detecting:
            HStack {
                Button("Reset Box") { controller.resetDetection() }
                    .buttonStyle(.bordered)
                primaryButton("Start Capture", systemImage: "camera.fill") { controller.startCapturing() }
            }
        case .capturing:
            primaryButton("Finish Early", systemImage: "checkmark") { controller.finishCapture() }
                .disabled(controller.shotsTaken < 10)
        default:
            EmptyView()
        }
    }

    private var passCompletePanel: some View {
        VStack(spacing: 10) {
            Text("Scan pass \(controller.scanPasses) complete")
                .font(.headline)
            Text("For a closed, printable model, flip the object over and scan its underside too.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Flip Object") { controller.beginNewPass(flipped: true) }
                    .buttonStyle(.bordered)
                Button("Same Side") { controller.beginNewPass(flipped: false) }
                    .buttonStyle(.bordered)
            }
            primaryButton("Process Model", systemImage: "cube.fill") { controller.finishCapture() }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct CaptureCameraView: View, Equatable {
    let session: ObjectCaptureSession
    let showPointCloud: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.showPointCloud == rhs.showPointCloud
    }

    var body: some View {
        if showPointCloud {
            ObjectCapturePointCloudView(session: session)
        } else {
            ObjectCaptureView(session: session)
        }
    }
}

struct ReconstructionProgressView: View {
    let progress: Double
    let message: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text("Reconstructing your model")
                .font(.title2.bold())
            ProgressView(value: progress)
                .padding(.horizontal, 40)
            Text("\(message) \(Int(progress * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Keep the app open. This usually takes a few minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}
#endif
