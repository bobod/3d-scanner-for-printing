import Foundation
import SceneKit
import simd

enum MeshImportError: LocalizedError {
    case noGeometry
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .noGeometry: return "The file does not contain any triangle geometry."
        case .unreadableFile(let name): return "Could not read \(name)."
        }
    }
}

/// Loads triangle geometry from STL (native parser) or any format SceneKit
/// understands (USDZ, USD, OBJ, PLY, DAE, SCN).
enum MeshImporter {

    static let supportedExtensions = ["usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "dae", "scn"]

    static func load(url: URL) throws -> TriangleMesh {
        let mesh: TriangleMesh
        if url.pathExtension.lowercased() == "stl" {
            mesh = try STLReader.read(url: url)
        } else {
            mesh = try loadWithSceneKit(url: url)
        }
        guard !mesh.isEmpty else { throw MeshImportError.noGeometry }
        return mesh
    }

    // MARK: - SceneKit

    static func loadWithSceneKit(url: URL) throws -> TriangleMesh {
        let scene: SCNScene
        do {
            scene = try SCNScene(url: url, options: [.checkConsistency: false])
        } catch {
            throw MeshImportError.unreadableFile(url.lastPathComponent)
        }

        var mesh = TriangleMesh()
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let transform = node.simdWorldTransform
            append(geometry: geometry, transform: transform, to: &mesh)
        }
        return mesh
    }

    private static func append(geometry: SCNGeometry, transform: simd_float4x4, to mesh: inout TriangleMesh) {
        guard let source = geometry.sources(for: .vertex).first else { return }
        let positions = readPositions(source)
        guard !positions.isEmpty else { return }

        let base = UInt32(mesh.vertices.count)
        mesh.vertices.append(contentsOf: positions.map { p in
            let w = transform * SIMD4<Float>(p, 1)
            return SIMD3(w.x, w.y, w.z)
        })

        let count = UInt32(positions.count)
        for element in geometry.elements {
            for t in readTriangles(element) where t.x < count && t.y < count && t.z < count {
                mesh.triangles.append(t &+ base)
            }
        }
    }

    private static func readPositions(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.componentsPerVector >= 3 else { return [] }
        let data = source.data
        let stride = source.dataStride
        let offset = source.dataOffset
        let size = source.bytesPerComponent
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(source.vectorCount)

        data.withUnsafeBytes { raw in
            for i in 0..<source.vectorCount {
                let start = offset + i * stride
                guard start + size * 3 <= raw.count else { break }
                if source.usesFloatComponents && size == 4 {
                    result.append(SIMD3(
                        raw.loadUnaligned(fromByteOffset: start, as: Float.self),
                        raw.loadUnaligned(fromByteOffset: start + 4, as: Float.self),
                        raw.loadUnaligned(fromByteOffset: start + 8, as: Float.self)))
                } else if source.usesFloatComponents && size == 8 {
                    result.append(SIMD3(
                        Float(raw.loadUnaligned(fromByteOffset: start, as: Double.self)),
                        Float(raw.loadUnaligned(fromByteOffset: start + 8, as: Double.self)),
                        Float(raw.loadUnaligned(fromByteOffset: start + 16, as: Double.self))))
                }
            }
        }
        return result
    }

    private static func readTriangles(_ element: SCNGeometryElement) -> [SIMD3<UInt32>] {
        let data = element.data
        let bytes = element.bytesPerIndex
        guard bytes == 1 || bytes == 2 || bytes == 4, !data.isEmpty else { return [] }

        let indexCount = data.count / bytes
        var indices = [UInt32](repeating: 0, count: indexCount)
        data.withUnsafeBytes { raw in
            for i in 0..<indexCount {
                switch bytes {
                case 1: indices[i] = UInt32(raw.load(fromByteOffset: i, as: UInt8.self))
                case 2: indices[i] = UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                default: indices[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                }
            }
        }

        var triangles: [SIMD3<UInt32>] = []
        switch element.primitiveType {
        case .triangles:
            let count = min(element.primitiveCount, indexCount / 3)
            triangles.reserveCapacity(count)
            for i in 0..<count {
                triangles.append(SIMD3(indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2]))
            }
        case .triangleStrip:
            guard indexCount >= 3 else { break }
            for i in 0..<(indexCount - 2) {
                let a = indices[i], b = indices[i + 1], c = indices[i + 2]
                triangles.append(i % 2 == 0 ? SIMD3(a, b, c) : SIMD3(b, a, c))
            }
        case .polygon:
            // Layout: `primitiveCount` vertex counts followed by the indices.
            let polygonCount = element.primitiveCount
            guard polygonCount <= indexCount else { break }
            var cursor = polygonCount
            for p in 0..<polygonCount {
                let n = Int(indices[p])
                guard n >= 3, cursor + n <= indexCount else { cursor += n; continue }
                for k in 1..<(n - 1) {
                    triangles.append(SIMD3(indices[cursor], indices[cursor + k], indices[cursor + k + 1]))
                }
                cursor += n
            }
        default:
            break
        }
        return triangles
    }
}

/// Binary and ASCII STL reader.
enum STLReader {

    static func read(url: URL) throws -> TriangleMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if isBinary(data) {
            return readBinary(data)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw MeshImportError.unreadableFile(url.lastPathComponent)
        }
        return readASCII(text)
    }

    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        return 84 + Int(UInt32(littleEndian: count)) * 50 == data.count
    }

    static func readBinary(_ data: Data) -> TriangleMesh {
        var mesh = TriangleMesh()
        data.withUnsafeBytes { raw in
            let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self)))
            mesh.vertices.reserveCapacity(count * 3)
            mesh.triangles.reserveCapacity(count)

            func float(_ offset: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }

            for i in 0..<count {
                let record = 84 + i * 50 + 12 // skip the facet normal
                let base = UInt32(mesh.vertices.count)
                for k in 0..<3 {
                    let o = record + k * 12
                    mesh.vertices.append(SIMD3(float(o), float(o + 4), float(o + 8)))
                }
                mesh.triangles.append(SIMD3(base, base + 1, base + 2))
            }
        }
        return mesh
    }

    static func readASCII(_ text: String) -> TriangleMesh {
        var mesh = TriangleMesh()
        var pending: [SIMD3<Float>] = []
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        var i = 0
        while i < tokens.count {
            if tokens[i] == "vertex", i + 3 < tokens.count,
               let x = Float(tokens[i + 1]), let y = Float(tokens[i + 2]), let z = Float(tokens[i + 3]) {
                pending.append(SIMD3(x, y, z))
                i += 4
                if pending.count == 3 {
                    let base = UInt32(mesh.vertices.count)
                    mesh.vertices.append(contentsOf: pending)
                    mesh.triangles.append(SIMD3(base, base + 1, base + 2))
                    pending.removeAll(keepingCapacity: true)
                }
            } else {
                if tokens[i] == "endfacet" { pending.removeAll(keepingCapacity: true) }
                i += 1
            }
        }
        return mesh
    }
}
