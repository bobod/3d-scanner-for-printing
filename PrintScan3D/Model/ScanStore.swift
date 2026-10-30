import Foundation
import UIKit

/// Persists scans as folders under Documents/Scans/<id>/:
///   scan.json        metadata and print settings
///   source.<ext>     raw model (USDZ from Object Capture, STL from LiDAR)
///   thumbnail.jpg    library preview
///   Exports/         files generated for sharing
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [Scan] = []
    /// Bumped whenever a thumbnail changes so views reload the image.
    @Published private(set) var thumbnailRevision = 0

    let root: URL
    private let fileManager = FileManager.default

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Scans", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scans = folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("scan.json")) else { return nil }
                return try? decoder.decode(Scan.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func scan(withID id: UUID) -> Scan? {
        scans.first { $0.id == id }
    }

    // MARK: Paths

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func sourceURL(for scan: Scan) -> URL {
        directory(for: scan.id).appendingPathComponent(scan.sourceFileName)
    }

    func thumbnailURL(for scan: Scan) -> URL {
        directory(for: scan.id).appendingPathComponent("thumbnail.jpg")
    }

    func exportsDirectory(for scan: Scan) -> URL {
        let url = directory(for: scan.id).appendingPathComponent("Exports", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates an empty folder for a scan that is about to be captured.
    func makeWorkspace() -> (id: UUID, directory: URL) {
        let id = UUID()
        let url = directory(for: id)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }

    func discardWorkspace(id: UUID) {
        try? fileManager.removeItem(at: directory(for: id))
    }

    // MARK: Mutations

    /// Registers a scan whose source file already exists in its workspace.
    @discardableResult
    func register(id: UUID, method: ScanMethod, sourceFileName: String, name: String? = nil,
                  settings: PrintSettings? = nil) throws -> Scan {
        let scan = Scan(
            id: id,
            name: name ?? Self.defaultName(for: method),
            createdAt: Date(),
            method: method,
            sourceFileName: sourceFileName,
            printSettings: settings ?? .defaults(for: method))
        try save(scan)
        scans.insert(scan, at: 0)
        return scan
    }

    /// Saves a LiDAR mesh (meters, Y up) as a new scan.
    func addLiDARScan(_ mesh: TriangleMesh) throws -> Scan {
        let workspace = makeWorkspace()
        let fileName = "source.stl"
        do {
            try MeshExporter.stlData(mesh, name: "LiDAR").write(to: workspace.directory.appendingPathComponent(fileName))
            return try register(id: workspace.id, method: .lidar, sourceFileName: fileName)
        } catch {
            discardWorkspace(id: workspace.id)
            throw error
        }
    }

    /// Copies a model file picked from Files into the library.
    func importModel(from url: URL) throws -> Scan {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let workspace = makeWorkspace()
        let fileName = "source.\(ext)"
        do {
            try fileManager.copyItem(at: url, to: workspace.directory.appendingPathComponent(fileName))
            var settings = PrintSettings.defaults(for: .imported)
            if ext == "stl" || ext == "obj" || ext == "ply" {
                // Files made for printing are almost always millimeters, Z up.
                settings.sourceUnit = .millimeters
                settings.sourceUpAxis = ext == "stl" ? .z : .y
            }
            return try register(id: workspace.id, method: .imported, sourceFileName: fileName,
                                name: url.deletingPathExtension().lastPathComponent, settings: settings)
        } catch {
            discardWorkspace(id: workspace.id)
            throw error
        }
    }

    func update(_ scan: Scan) {
        try? save(scan)
        if let index = scans.firstIndex(where: { $0.id == scan.id }) {
            scans[index] = scan
        }
    }

    func delete(_ scan: Scan) {
        try? fileManager.removeItem(at: directory(for: scan.id))
        scans.removeAll { $0.id == scan.id }
    }

    func saveThumbnail(_ image: UIImage, for scan: Scan) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: thumbnailURL(for: scan), options: .atomic)
        thumbnailRevision += 1
    }

    func thumbnail(for scan: Scan) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(for: scan).path)
    }

    private func save(_ scan: Scan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(scan)
        try data.write(to: directory(for: scan.id).appendingPathComponent("scan.json"), options: .atomic)
    }

    private static func defaultName(for method: ScanMethod) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(method == .lidar ? "LiDAR" : "Scan") \(formatter.string(from: Date()))"
    }
}
