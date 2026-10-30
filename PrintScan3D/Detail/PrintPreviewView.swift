import SceneKit
import SwiftUI

/// Interactive 3D preview (drag to orbit, pinch to zoom) of the printable
/// mesh on a virtual print bed.
struct PrintPreviewView: UIViewRepresentable {
    let mesh: TriangleMesh?
    /// Changes whenever `mesh` changes, so the scene is only rebuilt then.
    let meshID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemBackground
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.maximumVerticalAngle = 89
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.meshID != meshID else { return }
        context.coordinator.meshID = meshID
        guard let mesh, !mesh.isEmpty else {
            view.scene = nil
            return
        }
        let built = PrintSceneBuilder.makeScene(for: mesh)
        view.scene = built.scene
        view.pointOfView = built.camera
        view.defaultCameraController.target = built.target
    }

    final class Coordinator {
        var meshID: UUID?
    }
}
