import Foundation
import SceneKit

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case stl, threeMF, obj, usdz

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .stl: return "stl"
        case .threeMF: return "3mf"
        case .obj: return "obj"
        case .usdz: return "usdz"
        }
    }

    var title: String {
        switch self {
        case .stl: return "STL"
        case .threeMF: return "3MF"
        case .obj: return "OBJ"
        case .usdz: return "USDZ"
        }
    }

    var subtitle: String {
        switch self {
        case .stl: return "Universal — works with every slicer"
        case .threeMF: return "Modern, compact, stores millimeter units"
        case .obj: return "Widely supported mesh format"
        case .usdz: return "Apple AR — opens in Messages & Quick Look"
        }
    }

    var mimeType: String {
        switch self {
        case .stl: return "model/stl"
        case .threeMF: return "model/3mf"
        case .obj: return "model/obj"
        case .usdz: return "model/vnd.usdz+zip"
        }
    }
}

/// Writes print-space meshes (millimeters, Z up) to disk.
enum MeshExporter {

    static func write(_ mesh: TriangleMesh, format: ExportFormat, to url: URL, name: String = "Scan") throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .stl:
            try stlData(mesh, name: name).write(to: url, options: .atomic)
        case .threeMF:
            try threeMFData(mesh).write(to: url, options: .atomic)
        case .obj:
            try objData(mesh, name: name).write(to: url, options: .atomic)
        case .usdz:
            try writeUSDZ(mesh, to: url)
        }
    }

    // MARK: STL (binary)

    static func stlData(_ mesh: TriangleMesh, name: String) -> Data {
        var data = Data()
        data.reserveCapacity(84 + mesh.triangles.count * 50)

        var header = Data("PrintScan3D \(name)".utf8.prefix(80))
        header.append(Data(count: 80 - header.count))
        data.append(header)
        data.appendLE(UInt32(mesh.triangles.count))

        for t in mesh.triangles {
            let n = mesh.faceNormal(t)
            for v in [n, mesh.vertices[Int(t.x)], mesh.vertices[Int(t.y)], mesh.vertices[Int(t.z)]] {
                data.appendLE(v.x)
                data.appendLE(v.y)
                data.appendLE(v.z)
            }
            data.appendLE(UInt16(0))
        }
        return data
    }

    // MARK: OBJ

    static func objData(_ mesh: TriangleMesh, name: String) -> Data {
        var text = "# PrintScan3D export — units: millimeters, Z up\no \(name)\n"
        text.reserveCapacity(mesh.vertices.count * 32 + mesh.triangles.count * 24)
        for v in mesh.vertices {
            text += "v \(format(v.x)) \(format(v.y)) \(format(v.z))\n"
        }
        for t in mesh.triangles {
            text += "f \(t.x + 1) \(t.y + 1) \(t.z + 1)\n"
        }
        return Data(text.utf8)
    }

    // MARK: 3MF

    static func threeMFData(_ mesh: TriangleMesh) -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\
        </Types>
        """
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\
        </Relationships>
        """

        var model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <metadata name="Application">PrintScan3D</metadata>
        <resources>
        <object id="1" type="model">
        <mesh>
        <vertices>

        """
        model.reserveCapacity(mesh.vertices.count * 48 + mesh.triangles.count * 40)
        for v in mesh.vertices {
            model += "<vertex x=\"\(format(v.x))\" y=\"\(format(v.y))\" z=\"\(format(v.z))\"/>\n"
        }
        model += "</vertices>\n<triangles>\n"
        for t in mesh.triangles {
            model += "<triangle v1=\"\(t.x)\" v2=\"\(t.y)\" v3=\"\(t.z)\"/>\n"
        }
        model += """
        </triangles>
        </mesh>
        </object>
        </resources>
        <build>
        <item objectid="1"/>
        </build>
        </model>

        """

        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", data: Data(contentTypes.utf8))
        zip.add(path: "_rels/.rels", data: Data(relationships.utf8))
        zip.add(path: "3D/3dmodel.model", data: Data(model.utf8))
        return zip.finalize()
    }

    // MARK: USDZ

    /// USDZ is written in meters with Y up so it appears at real size in
    /// AR Quick Look and Messages.
    static func writeUSDZ(_ mesh: TriangleMesh, to url: URL) throws {
        let scene = SCNScene()
        let node = SCNNode(geometry: PrintSceneBuilder.geometry(for: mesh, color: PrintSceneBuilder.filamentColor))
        node.simdScale = SIMD3(repeating: 0.001)
        node.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(node)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4f", value)
    }
}
