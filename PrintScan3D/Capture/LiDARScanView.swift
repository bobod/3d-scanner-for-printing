#if !targetEnvironment(simulator)
import RealityKit
import SwiftUI

/// Fast scan using the LiDAR scene mesh. Lower detail than Object Capture
/// but works on larger objects and finishes instantly.
struct LiDARScanView: View {
    let onFinish: (TriangleMesh) -> Void
    let onCancel: () -> Void

    @StateObject private var scanner = LiDARScanner()
    @State private var isExtracting = false
    @State private var emptyResult = false

    var body: some View {
        ZStack {
            ARViewContainer(arView: scanner.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                header
                Spacer()
                if scanner.boxPlaced {
                    boxControls
                }
                captureButton
            }
            .padding()
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .alert("Nothing inside the box", isPresented: $emptyResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Scan around the object until the mesh covers it, and make sure the box surrounds it.")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Toggle("Mesh", isOn: $scanner.showMesh)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
            }
            Text(instruction)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var instruction: String {
        if let message = scanner.trackingMessage { return message }
        if let hint = scanner.placementHint { return hint }
        if !scanner.boxPlaced {
            return scanner.meshAnchorCount == 0
                ? "Move slowly to start mapping the area."
                : "Tap your object to place the scan box around it."
        }
        return "Walk around the object until the mesh covers every side, then tap Capture."
    }

    private var boxControls: some View {
        VStack(spacing: 6) {
            dimensionSlider("Width", value: $scanner.boxSize.x)
            dimensionSlider("Depth", value: $scanner.boxSize.z)
            dimensionSlider("Height", value: $scanner.boxSize.y)
            HStack {
                Text("Base").frame(width: 56, alignment: .leading)
                Slider(value: $scanner.baseOffset, in: -0.05...0.1)
                Text("\(Int((scanner.baseOffset * 1000).rounded())) mm")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .font(.footnote)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func dimensionSlider(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: value, in: 0.05...2)
            Text("\(Int((value.wrappedValue * 100).rounded())) cm")
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var captureButton: some View {
        Button {
            isExtracting = true
            let mesh = scanner.extractMesh()
            isExtracting = false
            if mesh.isEmpty {
                emptyResult = true
            } else {
                scanner.stop()
                onFinish(mesh)
            }
        } label: {
            Label(isExtracting ? "Capturing…" : "Capture", systemImage: "cube.transparent")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!scanner.boxPlaced || isExtracting)
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif
