import Metal
import SceneKit
import UIKit
import simd

/// Builds SceneKit scenes that show a print-space mesh (millimeters, Z up)
/// sitting on a virtual print bed.
enum PrintSceneBuilder {

    static let filamentColor = UIColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1)

    struct Result {
        let scene: SCNScene
        let camera: SCNNode
        let target: SCNVector3
    }

    static func geometry(for mesh: TriangleMesh, color: UIColor) -> SCNGeometry {
        let positions = mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = mesh.vertexNormals().map { SCNVector3($0.x, $0.y, $0.z) }
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for t in mesh.triangles {
            indices.append(t.x)
            indices.append(t.y)
            indices.append(t.z)
        }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = 0.55
        material.metalness.contents = 0.0
        geometry.materials = [material]
        return geometry
    }

    static func makeScene(for mesh: TriangleMesh, showBed: Bool = true) -> Result {
        let scene = SCNScene()

        // Everything below the print-space node is in millimeters with Z up;
        // rotating -90° about X shows it with SceneKit's Y up.
        let printSpace = SCNNode()
        printSpace.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(printSpace)

        printSpace.addChildNode(SCNNode(geometry: geometry(for: mesh, color: filamentColor)))

        let size = mesh.size
        if showBed {
            printSpace.addChildNode(bedNode(footprint: max(size.x, size.y)))
        }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        // Display space (Y up): the part's center sits at half its height.
        let radius = max(simd_length(size) / 2, 5)
        let target = SCNVector3(0, size.z / 2, 0)
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = Double(radius) * 0.01
        camera.camera?.zFar = Double(radius) * 50
        camera.camera?.fieldOfView = 40
        camera.position = SCNVector3(radius * 1.6, size.z / 2 + radius * 1.4, radius * 2.2)
        camera.look(at: target)
        scene.rootNode.addChildNode(camera)

        return Result(scene: scene, camera: camera, target: target)
    }

    /// A square build plate with a 10 mm grid.
    private static func bedNode(footprint: Float) -> SCNNode {
        let extent = max(100, (footprint * 1.6 / 20).rounded(.up) * 20)
        let half = extent / 2
        let node = SCNNode()

        let plate = SCNBox(width: CGFloat(extent), height: CGFloat(extent), length: 1, chamferRadius: 0)
        let plateMaterial = SCNMaterial()
        plateMaterial.diffuse.contents = UIColor(white: 0.18, alpha: 1)
        plateMaterial.lightingModel = .physicallyBased
        plateMaterial.roughness.contents = 0.9
        plate.materials = [plateMaterial]
        let plateNode = SCNNode(geometry: plate)
        plateNode.position = SCNVector3(0, 0, -0.55)
        node.addChildNode(plateNode)

        var points: [SCNVector3] = []
        var indices: [UInt32] = []
        var x = -half
        while x <= half + 0.01 {
            for p in [SCNVector3(x, -half, 0.01), SCNVector3(x, half, 0.01),
                      SCNVector3(-half, x, 0.01), SCNVector3(half, x, 0.01)] {
                indices.append(UInt32(points.count))
                points.append(p)
            }
            x += 10
        }
        let grid = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let gridMaterial = SCNMaterial()
        gridMaterial.lightingModel = .constant
        gridMaterial.diffuse.contents = UIColor(white: 0.45, alpha: 1)
        grid.materials = [gridMaterial]
        node.addChildNode(SCNNode(geometry: grid))
        return node
    }
}

enum ThumbnailRenderer {
    static func render(_ mesh: TriangleMesh, size: CGSize = CGSize(width: 480, height: 480)) -> UIImage? {
        guard !mesh.isEmpty, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let built = PrintSceneBuilder.makeScene(for: mesh, showBed: false)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = built.scene
        renderer.pointOfView = built.camera
        renderer.autoenablesDefaultLighting = true
        built.scene.background.contents = UIColor(white: 0.12, alpha: 1)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
