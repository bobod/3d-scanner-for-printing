import XCTest
import simd
@testable import PrintScan3D

final class MeshPipelineTests: XCTestCase {

    /// Unit cube with outward-facing (counter-clockwise) triangles.
    private func cube(size: Float = 1) -> TriangleMesh {
        let v: [SIMD3<Float>] = [
            [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
            [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
        ].map { $0 * size }
        let t: [SIMD3<UInt32>] = [
            [0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
            [0, 1, 5], [0, 5, 4], [3, 7, 6], [3, 6, 2],
            [0, 4, 7], [0, 7, 3], [1, 2, 6], [1, 6, 5],
        ]
        return TriangleMesh(vertices: v, triangles: t)
    }

    func testCubeIsClosedWithPositiveVolume() {
        let mesh = cube()
        XCTAssertEqual(mesh.signedVolume, 1, accuracy: 1e-5)
        let stats = MeshRepair.edgeStats(of: mesh)
        XCTAssertEqual(stats.openEdges, 0)
        XCTAssertEqual(stats.nonManifoldEdges, 0)
    }

    func testFillHolesClosesOpenBottom() {
        var mesh = cube()
        mesh.triangles.removeFirst(2)
        XCTAssertEqual(MeshRepair.edgeStats(of: mesh).openEdges, 4)

        XCTAssertEqual(MeshRepair.fillHoles(&mesh), 1)
        XCTAssertEqual(MeshRepair.edgeStats(of: mesh).openEdges, 0)
        XCTAssertEqual(mesh.signedVolume, 1, accuracy: 1e-5)
    }

    func testCutBelowLeavesFlatClosedBase() {
        var mesh = cube()
        MeshRepair.cutBelow(&mesh, z: 0.3)
        MeshRepair.fillHoles(&mesh)
        XCTAssertEqual(MeshRepair.edgeStats(of: mesh).openEdges, 0)
        XCTAssertEqual(mesh.signedVolume, 0.7, accuracy: 1e-4)
        XCTAssertEqual(mesh.bounds.min.z, 0.3, accuracy: 1e-5)
    }

    func testWeldMergesSplitVertices() {
        // Triangle soup as produced by STL files: every triangle has its own vertices.
        let source = cube()
        var soup = TriangleMesh()
        for t in source.triangles {
            let base = UInt32(soup.vertices.count)
            soup.vertices += [source.vertices[Int(t.x)], source.vertices[Int(t.y)], source.vertices[Int(t.z)]]
            soup.triangles.append(SIMD3(base, base + 1, base + 2))
        }
        let welded = MeshRepair.weld(soup, tolerance: 0.001)
        XCTAssertEqual(welded.vertices.count, 8)
        XCTAssertEqual(MeshRepair.edgeStats(of: welded).openEdges, 0)
    }

    func testRemoveSmallParts() {
        var mesh = cube()
        var speck = cube(size: 0.01)
        speck.apply { $0 + SIMD3(5, 5, 5) }
        mesh.append(speck)
        XCTAssertEqual(MeshRepair.removeSmallParts(&mesh, keepLargestOnly: false), 1)
        XCTAssertEqual(mesh.triangles.count, 12)
    }

    func testPipelineConvertsMetersYUpToMillimetersZUp() {
        // 1 m × 2 m × 3 m box (Y is height), inside out to check auto-flip.
        var mesh = cube()
        mesh.apply { $0 * SIMD3(1, 2, 3) }
        mesh.flipWinding()

        var settings = PrintSettings()
        settings.sourceUnit = .meters
        settings.sourceUpAxis = .y
        let (printable, report) = PrintablePipeline.makePrintable(from: mesh, settings: settings)

        XCTAssertEqual(report.sizeMM.x, 1000, accuracy: 0.1)
        XCTAssertEqual(report.sizeMM.y, 3000, accuracy: 0.1)
        XCTAssertEqual(report.sizeMM.z, 2000, accuracy: 0.1)
        XCTAssertEqual(printable.bounds.min.z, 0, accuracy: 1e-3)
        XCTAssertEqual(printable.bounds.min.x, -500, accuracy: 0.1)
        XCTAssertTrue(report.flippedNormals)
        XCTAssertTrue(report.isWatertight)
        XCTAssertGreaterThan(printable.signedVolume, 0)
    }

    func testFitToSize() {
        var settings = PrintSettings()
        settings.sizing = .fitLongestSide
        settings.targetLongestSideMM = 50
        let (_, report) = PrintablePipeline.makePrintable(from: cube(size: 0.2), settings: settings)
        XCTAssertEqual(report.sizeMM.max(), 50, accuracy: 0.01)
    }

    func testBinarySTLRoundTrip() throws {
        let data = MeshExporter.stlData(cube(), name: "Test")
        XCTAssertEqual(data.count, 84 + 12 * 50)
        XCTAssertTrue(STLReader.isBinary(data))
        let read = STLReader.readBinary(data)
        XCTAssertEqual(read.triangles.count, 12)
        XCTAssertEqual(MeshRepair.weld(read, tolerance: 0.001).signedVolume, 1, accuracy: 1e-5)
    }

    func testASCIISTL() {
        let text = """
        solid t
        facet normal 0 0 1
          outer loop
            vertex 0 0 0
            vertex 1 0 0
            vertex 0 1 0
          endloop
        endfacet
        endsolid t
        """
        let mesh = STLReader.readASCII(text)
        XCTAssertEqual(mesh.triangles.count, 1)
        XCTAssertEqual(mesh.vertices[1], SIMD3(1, 0, 0))
    }

    func testThreeMFIsZipPackage() {
        let data = MeshExporter.threeMFData(cube())
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(data.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }

    func testEarClipConcavePolygon() {
        // L-shaped polygon, counter-clockwise.
        let points: [SIMD2<Float>] = [[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]]
        let triangles = MeshRepair.earClip(points)
        XCTAssertEqual(triangles?.count, 4)
    }
}
