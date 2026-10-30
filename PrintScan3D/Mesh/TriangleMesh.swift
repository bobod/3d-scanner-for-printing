import Foundation
import simd

/// A minimal indexed triangle mesh. All geometry processing in the app
/// (repair, slicing, export) works on this type.
struct TriangleMesh {
    var vertices: [SIMD3<Float>] = []
    var triangles: [SIMD3<UInt32>] = []

    var isEmpty: Bool { triangles.isEmpty }

    /// Axis-aligned bounds. Returns zero bounds for an empty mesh.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = vertices.first else { return (.zero, .zero) }
        var hi = lo
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    var size: SIMD3<Float> {
        let b = bounds
        return b.max - b.min
    }

    /// Signed volume via the divergence theorem. Positive when triangles are
    /// wound counter-clockwise as seen from outside (outward normals).
    var signedVolume: Float {
        var volume: Float = 0
        for t in triangles {
            let a = vertices[Int(t.x)], b = vertices[Int(t.y)], c = vertices[Int(t.z)]
            volume += simd_dot(a, simd_cross(b, c))
        }
        return volume / 6
    }

    var surfaceArea: Float {
        var area: Float = 0
        for t in triangles {
            let a = vertices[Int(t.x)], b = vertices[Int(t.y)], c = vertices[Int(t.z)]
            area += simd_length(simd_cross(b - a, c - a)) * 0.5
        }
        return area
    }

    func faceNormal(_ t: SIMD3<UInt32>) -> SIMD3<Float> {
        let a = vertices[Int(t.x)], b = vertices[Int(t.y)], c = vertices[Int(t.z)]
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        return len > 0 ? n / len : .zero
    }

    /// Area-weighted smooth vertex normals, used for previews.
    func vertexNormals() -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for t in triangles {
            let a = vertices[Int(t.x)], b = vertices[Int(t.y)], c = vertices[Int(t.z)]
            let n = simd_cross(b - a, c - a)
            normals[Int(t.x)] += n
            normals[Int(t.y)] += n
            normals[Int(t.z)] += n
        }
        return normals.map { n in
            let len = simd_length(n)
            return len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
        }
    }

    mutating func append(_ other: TriangleMesh) {
        let offset = UInt32(vertices.count)
        vertices.append(contentsOf: other.vertices)
        triangles.append(contentsOf: other.triangles.map { $0 &+ offset })
    }

    mutating func apply(_ transform: (SIMD3<Float>) -> SIMD3<Float>) {
        for i in vertices.indices {
            vertices[i] = transform(vertices[i])
        }
    }

    mutating func flipWinding() {
        triangles = triangles.map { SIMD3($0.x, $0.z, $0.y) }
    }

    /// Drops vertices that no triangle references and renumbers the rest.
    mutating func removeUnusedVertices() {
        var remap = [UInt32](repeating: .max, count: vertices.count)
        var kept: [SIMD3<Float>] = []
        kept.reserveCapacity(vertices.count)
        for t in triangles {
            for i in [t.x, t.y, t.z] where remap[Int(i)] == .max {
                remap[Int(i)] = UInt32(kept.count)
                kept.append(vertices[Int(i)])
            }
        }
        triangles = triangles.map { SIMD3(remap[Int($0.x)], remap[Int($0.y)], remap[Int($0.z)]) }
        vertices = kept
    }
}
