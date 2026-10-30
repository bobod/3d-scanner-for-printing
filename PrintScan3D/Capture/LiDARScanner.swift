#if !targetEnvironment(simulator)
import ARKit
import Combine
import RealityKit
import UIKit
import simd

/// Drives an ARKit scene-reconstruction session and crops the live LiDAR
/// mesh to a user-placed box around the object.
@MainActor
final class LiDARScanner: NSObject, ObservableObject {

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var boxPlaced = false
    @Published private(set) var meshAnchorCount = 0
    @Published private(set) var trackingMessage: String?
    @Published private(set) var placementHint: String?
    @Published var showMesh = true { didSet { updateDebugOptions() } }

    /// Box dimensions in meters (width X, height Y, depth Z).
    @Published var boxSize = SIMD3<Float>(0.3, 0.3, 0.3) { didSet { updateBox() } }
    /// Raises or lowers the box bottom relative to the detected surface.
    @Published var baseOffset: Float = 0.005 { didSet { updateBox() } }

    /// Center of the box footprint on the supporting surface.
    private var floorPoint: SIMD3<Float>?
    private let boxAnchor = AnchorEntity(world: .zero)
    private let boxEntity: ModelEntity = {
        var material = UnlitMaterial(color: .systemTeal)
        material.blending = .transparent(opacity: 0.25)
        return ModelEntity(mesh: .generateBox(size: 1), materials: [material])
    }()

    override init() {
        super.init()
        arView.session.delegate = self
        boxAnchor.addChild(boxEntity)
        boxEntity.isEnabled = false
        arView.scene.addAnchor(boxAnchor)
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        updateDebugOptions()
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        arView.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Box placement

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: arView)
        guard let hit = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal).first else {
            placementHint = "No surface found there — keep moving around the object and try again."
            return
        }
        let point = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        floorPoint = SIMD3(point.x, supportHeight(below: point), point.z)
        placementHint = nil
        boxPlaced = true
        boxEntity.isEnabled = true
        updateBox()
    }

    /// If the tap landed on top of the object, drop the box to the largest
    /// detected horizontal surface (table or floor) underneath it.
    private func supportHeight(below point: SIMD3<Float>) -> Float {
        let planes = arView.session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? []
        let candidates = planes.filter { plane in
            let y = plane.transform.columns.3.y
            let area = plane.planeExtent.width * plane.planeExtent.height
            return plane.alignment == .horizontal && y <= point.y + 0.01 && area >= 0.09
        }
        return candidates.map { $0.transform.columns.3.y }.max() ?? point.y
    }

    private func updateBox() {
        guard let floorPoint else { return }
        boxEntity.scale = boxSize
        boxAnchor.position = SIMD3(floorPoint.x, floorPoint.y + baseOffset + boxSize.y / 2, floorPoint.z)
    }

    private func updateDebugOptions() {
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    // MARK: Mesh extraction

    /// LiDAR scene-mesh triangles are several centimeters across, so objects
    /// smaller than this come out as shapeless blobs.
    static let minimumUsefulObjectSize: Float = 0.15

    var boxIsTooSmallForLiDAR: Bool {
        boxSize.max() < Self.minimumUsefulObjectSize
    }

    /// Collects every LiDAR mesh triangle whose center lies inside the box, in world
    /// space (meters, Y up). The box bottom sits just above the support
    /// surface so the floor is excluded and the base is left open for the
    /// print pipeline to cap.
    func extractMesh() -> TriangleMesh {
        guard let floorPoint, let frame = arView.session.currentFrame else { return TriangleMesh() }
        let half = boxSize / 2
        let center = SIMD3(floorPoint.x, floorPoint.y + baseOffset + half.y, floorPoint.z)
        let lo = center - half, hi = center + half

        var mesh = TriangleMesh()
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }

            var world = [SIMD3<Float>](repeating: .zero, count: vertices.count)
            let vertexPointer = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let p = vertexPointer.advanced(by: vertices.offset + vertices.stride * i)
                    .assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                world[i] = SIMD3(w.x, w.y, w.z)
            }

            var remap = [UInt32](repeating: .max, count: vertices.count)
            let indexPointer = faces.buffer.contents()
            for f in 0..<faces.count {
                var ids = SIMD3<UInt32>.zero
                for k in 0..<3 {
                    let offset = (f * 3 + k) * faces.bytesPerIndex
                    ids[k] = faces.bytesPerIndex == 4
                        ? indexPointer.load(fromByteOffset: offset, as: UInt32.self)
                        : UInt32(indexPointer.load(fromByteOffset: offset, as: UInt16.self))
                }
                // Testing the centroid (rather than requiring all three corners
                // inside) keeps the coarse triangles that cover small objects.
                let centroid = (world[Int(ids.x)] + world[Int(ids.y)] + world[Int(ids.z)]) / 3
                guard all(centroid .>= lo), all(centroid .<= hi) else { continue }
                for k in 0..<3 where remap[Int(ids[k])] == .max {
                    remap[Int(ids[k])] = UInt32(mesh.vertices.count)
                    mesh.vertices.append(world[Int(ids[k])])
                }
                mesh.triangles.append(SIMD3(remap[Int(ids.x)], remap[Int(ids.y)], remap[Int(ids.z)]))
            }
        }
        return mesh
    }
}

extension LiDARScanner: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let count = frame.anchors.reduce(0) { $0 + ($1 is ARMeshAnchor ? 1 : 0) }
        let message: String?
        switch frame.camera.trackingState {
        case .normal: message = nil
        case .notAvailable: message = "Tracking unavailable"
        case .limited(.excessiveMotion): message = "Slow down"
        case .limited(.insufficientFeatures): message = "Point at a more detailed area"
        case .limited(.initializing), .limited(.relocalizing): message = "Initializing — move the phone slowly"
        case .limited: message = "Limited tracking"
        }
        Task { @MainActor in
            if self.meshAnchorCount != count { self.meshAnchorCount = count }
            if self.trackingMessage != message { self.trackingMessage = message }
        }
    }
}
#endif
