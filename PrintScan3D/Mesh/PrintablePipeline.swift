import Foundation
import simd

/// Summary of a processed mesh shown to the user before printing.
struct MeshReport: Hashable {
    var vertexCount = 0
    var triangleCount = 0
    var sizeMM = SIMD3<Float>.zero
    var volumeMM3: Float = 0
    var openEdges = 0
    var nonManifoldEdges = 0
    var holesFilled = 0
    var partsRemoved = 0
    var partCount = 0
    var flippedNormals = false

    var isWatertight: Bool { openEdges == 0 && nonManifoldEdges == 0 && triangleCount > 0 }
}

/// Converts a raw scan into a print-ready solid: millimeters, Z up,
/// centered on the bed with its lowest point at z = 0.
enum PrintablePipeline {

    static func makePrintable(from source: TriangleMesh, settings: PrintSettings) -> (TriangleMesh, MeshReport) {
        var report = MeshReport()
        var mesh = toPrintSpace(source, unit: settings.sourceUnit, upAxis: settings.sourceUpAxis)

        // Topology clean-up at real-world scale (0.01 mm weld grid).
        mesh = MeshRepair.weld(mesh, tolerance: 0.01)
        MeshRepair.removeDegenerateAndDuplicateTriangles(&mesh)

        scale(&mesh, settings: settings)

        if settings.removeFloaters || settings.keepLargestPartOnly {
            report.partsRemoved = MeshRepair.removeSmallParts(&mesh, keepLargestOnly: settings.keepLargestPartOnly)
        }

        placeOnBed(&mesh)
        if settings.flatBaseCutMM > 0, !mesh.isEmpty {
            MeshRepair.cutBelow(&mesh, z: Float(settings.flatBaseCutMM))
        }

        if settings.fillHoles {
            report.holesFilled = MeshRepair.fillHoles(&mesh)
        }

        // Slicers expect outward-facing normals; a negative volume means the
        // scan came out inside-out.
        if mesh.signedVolume < 0 {
            mesh.flipWinding()
            report.flippedNormals = true
        }

        placeOnBed(&mesh)

        let edges = MeshRepair.edgeStats(of: mesh)
        report.vertexCount = mesh.vertices.count
        report.triangleCount = mesh.triangles.count
        report.sizeMM = mesh.size
        report.volumeMM3 = abs(mesh.signedVolume)
        report.openEdges = edges.openEdges
        report.nonManifoldEdges = edges.nonManifoldEdges
        report.partCount = mesh.isEmpty ? 0 : MeshRepair.components(of: mesh).count
        return (mesh, report)
    }

    /// Converts to millimeters with Z up and drops non-finite geometry.
    static func toPrintSpace(_ source: TriangleMesh, unit: LengthUnit, upAxis: UpAxis) -> TriangleMesh {
        let factor = unit.millimeters
        var mesh = source
        mesh.apply { v in
            let p = v * factor
            // Y-up -> Z-up is a proper rotation (+90° about X), so winding is preserved.
            return upAxis == .y ? SIMD3(p.x, -p.z, p.y) : p
        }
        let finite = mesh.vertices.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        if finite.contains(false) {
            mesh.triangles.removeAll { !finite[Int($0.x)] || !finite[Int($0.y)] || !finite[Int($0.z)] }
            mesh.removeUnusedVertices()
        }
        return mesh
    }

    static func scale(_ mesh: inout TriangleMesh, settings: PrintSettings) {
        let factor: Float
        switch settings.sizing {
        case .realSize:
            factor = Float(settings.scalePercent / 100)
        case .fitLongestSide:
            let longest = mesh.size.max()
            factor = longest > 0 ? Float(settings.targetLongestSideMM) / longest : 1
        }
        guard factor != 1, factor > 0 else { return }
        mesh.apply { $0 * factor }
    }

    /// Centers the part on X/Y and rests its lowest point on z = 0.
    static func placeOnBed(_ mesh: inout TriangleMesh) {
        guard !mesh.isEmpty else { return }
        let b = mesh.bounds
        let offset = SIMD3<Float>(-(b.min.x + b.max.x) / 2, -(b.min.y + b.max.y) / 2, -b.min.z)
        mesh.apply { $0 + offset }
    }
}
