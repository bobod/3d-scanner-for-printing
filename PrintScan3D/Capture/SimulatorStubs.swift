#if targetEnvironment(simulator)
import SwiftUI

// LiDAR scanning and Object Capture need real camera hardware and their
// APIs are unavailable in the Simulator SDK. These stand-ins keep the app
// building so import, preview and export can be tested in the Simulator.

enum LiDARScanner {
    static var isSupported: Bool { false }
}

enum ObjectCaptureController {
    static var isSupported: Bool { false }
}

struct LiDARScanView: View {
    let onFinish: (TriangleMesh) -> Void
    let onCancel: () -> Void

    var body: some View {
        UnsupportedCaptureView(onCancel: onCancel)
    }
}

struct ObjectCaptureFlowView: View {
    let onCancel: () -> Void

    init(scanID: UUID, workspace: URL, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    var body: some View {
        UnsupportedCaptureView(onCancel: onCancel)
    }
}

private struct UnsupportedCaptureView: View {
    let onCancel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Scanning unavailable", systemImage: "sensor")
        } description: {
            Text("Run on an iPhone or iPad with LiDAR to scan objects.")
        } actions: {
            Button("Close", action: onCancel)
        }
    }
}
#endif
