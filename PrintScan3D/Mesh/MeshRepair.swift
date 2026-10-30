import Foundation
import simd

/// Geometry clean-up operations that turn scan output into a closed,
/// consistently oriented solid that slicers accept.
enum MeshRepair {

    @inline(__always)
    static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    @inline(__always)
    static func undirectedKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        a < b ? edgeKey(a, b) : edgeKey(b, a)
    }

    // MARK: - Welding & cleanup

    /// Merges vertices closer than `tolerance` (snapped to a grid) so that
    /// triangles which only touched geometrically become connected.
    static func weld(_ mesh: TriangleMesh, tolerance: Float) -> TriangleMesh {
        let inverse = 1 / tolerance
        var lookup: [SIMD3<Int32>: UInt32] = [:]
        lookup.reserveCapacity(mesh.vertices.count)
        var remap = [UInt32](repeating: 0, count: mesh.vertices.count)
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(mesh.vertices.count)

        for (i, v) in mesh.vertices.enumerated() {
            let q = (v * inverse).rounded(.toNearestOrAwayFromZero)
            let key = SIMD3<Int32>(Int32(clamping: Int(q.x)), Int32(clamping: Int(q.y)), Int32(clamping: Int(q.z)))
            if let existing = lookup[key] {
                remap[i] = existing
            } else {
                let index = UInt32(vertices.count)
                lookup[key] = index
                remap[i] = index
                vertices.append(v)
            }
        }

        var result = TriangleMesh(vertices: vertices, triangles: [])
        result.triangles = mesh.triangles.map { SIMD3(remap[Int($0.x)], remap[Int($0.y)], remap[Int($0.z)]) }
        return result
    }

    /// Removes zero-area triangles and exact duplicates (including
    /// back-to-back duplicates, which create non-manifold sheets).
    static func removeDegenerateAndDuplicateTriangles(_ mesh: inout TriangleMesh) {
        var seen = Set<SIMD3<UInt32>>()
        seen.reserveCapacity(mesh.triangles.count)
        var kept: [SIMD3<UInt32>] = []
        kept.reserveCapacity(mesh.triangles.count)

        for t in mesh.triangles {
            if t.x == t.y || t.y == t.z || t.x == t.z { continue }
            let a = mesh.vertices[Int(t.x)], b = mesh.vertices[Int(t.y)], c = mesh.vertices[Int(t.z)]
            if simd_length_squared(simd_cross(b - a, c - a)) < 1e-14 { continue }
            let sorted = sortedTriple(t)
            if seen.insert(sorted).inserted {
                kept.append(t)
            }
        }
        mesh.triangles = kept
        mesh.removeUnusedVertices()
    }

    private static func sortedTriple(_ t: SIMD3<UInt32>) -> SIMD3<UInt32> {
        var a = t.x, b = t.y, c = t.z
        if a > b { swap(&a, &b) }
        if b > c { swap(&b, &c) }
        if a > b { swap(&a, &b) }
        return SIMD3(a, b, c)
    }

    // MARK: - Connected components

    /// Splits triangles into vertex-connected parts. Returns, for each part,
    /// the indices of its triangles.
    static func components(of mesh: TriangleMesh) -> [[Int]] {
        var parent = Array(0..<mesh.vertices.count)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for t in mesh.triangles {
            union(Int(t.x), Int(t.y))
            union(Int(t.y), Int(t.z))
        }

        var groups: [Int: [Int]] = [:]
        for (i, t) in mesh.triangles.enumerated() {
            groups[find(Int(t.x)), default: []].append(i)
        }
        return Array(groups.values)
    }

    /// Removes small disconnected parts (scan noise, floor fragments).
    /// - Returns: number of parts removed.
    @discardableResult
    static func removeSmallParts(_ mesh: inout TriangleMesh, keepLargestOnly: Bool, minimumFraction: Float = 0.02) -> Int {
        let parts = components(of: mesh)
        guard parts.count > 1 else { return 0 }

        // Rank parts by surface area so a large thin shell beats dense noise.
        let areas: [Float] = parts.map { part in
            part.reduce(Float(0)) { sum, index in
                let t = mesh.triangles[index]
                let a = mesh.vertices[Int(t.x)], b = mesh.vertices[Int(t.y)], c = mesh.vertices[Int(t.z)]
                return sum + simd_length(simd_cross(b - a, c - a)) * 0.5
            }
        }
        let largest = areas.max() ?? 0
        let largestIndex = areas.firstIndex(of: largest) ?? 0

        var keptTriangles: [SIMD3<UInt32>] = []
        var removed = 0
        for (i, part) in parts.enumerated() {
            let keep = keepLargestOnly ? i == largestIndex : areas[i] >= largest * minimumFraction
            if keep {
                keptTriangles.append(contentsOf: part.map { mesh.triangles[$0] })
            } else {
                removed += 1
            }
        }
        mesh.triangles = keptTriangles
        mesh.removeUnusedVertices()
        return removed
    }

    // MARK: - Planar cut

    /// Removes everything below the plane `z = height`, splitting triangles
    /// that cross it. Intersection vertices are shared between neighbouring
    /// triangles so the resulting cut outline is a clean closed loop which
    /// `fillHoles` then caps with a flat face.
    static func cutBelow(_ mesh: inout TriangleMesh, z height: Float) {
        var vertices = mesh.vertices
        var cache: [UInt64: UInt32] = [:]
        var result: [SIMD3<UInt32>] = []
        result.reserveCapacity(mesh.triangles.count)

        func intersection(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = undirectedKey(a, b)
            if let existing = cache[key] { return existing }
            let pa = vertices[Int(a)], pb = vertices[Int(b)]
            let t = (height - pa.z) / (pb.z - pa.z)
            var p = pa + (pb - pa) * t
            p.z = height
            let index = UInt32(vertices.count)
            vertices.append(p)
            cache[key] = index
            return index
        }

        for t in mesh.triangles {
            let ids = [t.x, t.y, t.z]
            let above = ids.map { vertices[Int($0)].z >= height }
            switch above.filter({ $0 }).count {
            case 3:
                result.append(t)
            case 1:
                let i = above.firstIndex(of: true)!
                let a = ids[i], b = ids[(i + 1) % 3], c = ids[(i + 2) % 3]
                result.append(SIMD3(a, intersection(a, b), intersection(a, c)))
            case 2:
                let i = above.firstIndex(of: false)!
                let c = ids[i], a = ids[(i + 1) % 3], b = ids[(i + 2) % 3]
                let ca = intersection(c, a), bc = intersection(b, c)
                result.append(SIMD3(ca, a, b))
                result.append(SIMD3(ca, b, bc))
            default:
                break
            }
        }

        mesh.vertices = vertices
        mesh.triangles = result
        removeDegenerateAndDuplicateTriangles(&mesh)
    }

    // MARK: - Hole filling

    /// Finds open boundary loops and closes each with new triangles.
    /// Planar-ish holes are ear-clipped; anything else falls back to a fan
    /// around the loop centroid.
    /// - Returns: number of holes filled.
    @discardableResult
    static func fillHoles(_ mesh: inout TriangleMesh) -> Int {
        var directed = Set<UInt64>()
        directed.reserveCapacity(mesh.triangles.count * 3)
        for t in mesh.triangles {
            directed.insert(edgeKey(t.x, t.y))
            directed.insert(edgeKey(t.y, t.z))
            directed.insert(edgeKey(t.z, t.x))
        }

        // Boundary half-edges: a->b whose twin b->a does not exist.
        var outgoing: [UInt32: [UInt32]] = [:]
        var boundaryCount = 0
        for t in mesh.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where !directed.contains(edgeKey(b, a)) {
                outgoing[a, default: []].append(b)
                boundaryCount += 1
            }
        }
        guard boundaryCount > 0 else { return 0 }

        var loops: [[UInt32]] = []
        for start in Array(outgoing.keys) {
            while let first = outgoing[start]?.popLast() {
                var loop: [UInt32] = [start]
                var current = first
                var closed = false
                while loop.count <= boundaryCount {
                    if current == start {
                        closed = true
                        break
                    }
                    guard let next = outgoing[current]?.popLast() else { break }
                    loop.append(current)
                    current = next
                }
                if closed && loop.count >= 3 {
                    loops.append(loop)
                }
            }
        }

        for loop in loops {
            mesh.triangles.append(contentsOf: triangulate(loop: loop, in: &mesh.vertices))
        }
        return loops.count
    }

    /// Triangulates a boundary loop. The loop follows the existing faces'
    /// boundary half-edges, so the patch uses the reversed order to keep
    /// orientation consistent with its neighbours.
    static func triangulate(loop: [UInt32], in vertices: inout [SIMD3<Float>]) -> [SIMD3<UInt32>] {
        let polygon = Array(loop.reversed())
        if polygon.count == 3 {
            return [SIMD3(polygon[0], polygon[1], polygon[2])]
        }

        let points = polygon.map { vertices[Int($0)] }

        // Newell's method gives a robust average normal for the polygon.
        var normal = SIMD3<Float>.zero
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            normal.x += (p.y - q.y) * (p.z + q.z)
            normal.y += (p.z - q.z) * (p.x + q.x)
            normal.z += (p.x - q.x) * (p.y + q.y)
        }

        if simd_length(normal) > 1e-9 {
            let n = simd_normalize(normal)
            let helper: SIMD3<Float> = abs(n.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
            let u = simd_normalize(simd_cross(helper, n))
            let v = simd_cross(n, u)
            let projected = points.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
            if let ears = earClip(projected) {
                return ears.map { SIMD3(polygon[$0.0], polygon[$0.1], polygon[$0.2]) }
            }
        }

        // Fallback: fan around the centroid.
        let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let center = UInt32(vertices.count)
        vertices.append(centroid)
        return polygon.indices.map { i in
            SIMD3(polygon[i], polygon[(i + 1) % polygon.count], center)
        }
    }

    /// Ear clipping for a simple counter-clockwise polygon. Returns `nil`
    /// when the polygon is not simple or not counter-clockwise.
    static func earClip(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)]? {
        guard points.count >= 3 else { return nil }

        var area: Float = 0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            area += p.x * q.y - q.x * p.y
        }
        guard area > 0 else { return nil }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        func contains(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
        }

        var remaining = Array(points.indices)
        var result: [(Int, Int, Int)] = []
        result.reserveCapacity(points.count - 2)
        var i = 0
        var attempts = 0

        while remaining.count > 3 {
            let m = remaining.count
            if attempts > m { return nil }
            let prev = remaining[(i + m - 1) % m], cur = remaining[i % m], next = remaining[(i + 1) % m]
            let a = points[prev], b = points[cur], c = points[next]

            var isEar = cross(a, b, c) > 0
            if isEar {
                for j in remaining where j != prev && j != cur && j != next {
                    let p = points[j]
                    if p == a || p == b || p == c { continue }
                    if contains(p, a, b, c) {
                        isEar = false
                        break
                    }
                }
            }

            if isEar {
                result.append((prev, cur, next))
                remaining.remove(at: i % m)
                i = (i % m) % (m - 1)
                attempts = 0
            } else {
                i = (i + 1) % m
                attempts += 1
            }
        }
        result.append((remaining[0], remaining[1], remaining[2]))
        return result
    }

    // MARK: - Diagnostics

    struct EdgeStats {
        var openEdges = 0
        var nonManifoldEdges = 0
    }

    static func edgeStats(of mesh: TriangleMesh) -> EdgeStats {
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(mesh.triangles.count * 3 / 2)
        for t in mesh.triangles {
            counts[undirectedKey(t.x, t.y), default: 0] += 1
            counts[undirectedKey(t.y, t.z), default: 0] += 1
            counts[undirectedKey(t.z, t.x), default: 0] += 1
        }
        var stats = EdgeStats()
        for count in counts.values {
            if count == 1 { stats.openEdges += 1 }
            if count > 2 { stats.nonManifoldEdges += 1 }
        }
        return stats
    }
}
