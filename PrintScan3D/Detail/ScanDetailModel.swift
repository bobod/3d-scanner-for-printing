import Foundation
import UIKit

@MainActor
final class ScanDetailModel: ObservableObject {
    @Published private(set) var scan: Scan
    @Published var settings: PrintSettings {
        didSet {
            guard settings != oldValue else { return }
            scan.printSettings = settings
            store.update(scan)
            scheduleProcessing()
        }
    }
    @Published var exportFormat: ExportFormat = .stl
    @Published private(set) var printable: TriangleMesh?
    @Published private(set) var previewID = UUID()
    @Published private(set) var report: MeshReport?
    @Published private(set) var isProcessing = false
    @Published private(set) var isExporting = false
    @Published var errorMessage: String?

    private let store: ScanStore
    private var source: TriangleMesh?
    private var processingTask: Task<Void, Never>?

    init(scan: Scan, store: ScanStore) {
        self.scan = scan
        self.settings = scan.printSettings
        self.store = store
    }

    var sourceURL: URL { store.sourceURL(for: scan) }
    var hasTexturedModel: Bool { sourceURL.pathExtension.lowercased() == "usdz" }

    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scan.name = trimmed
        store.update(scan)
    }

    func load() async {
        guard source == nil else { return }
        isProcessing = true
        let url = sourceURL
        do {
            source = try await Task.detached(priority: .userInitiated) {
                try MeshImporter.load(url: url)
            }.value
            await process()
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleProcessing() {
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            // Debounce slider drags.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.process()
        }
    }

    private func process() async {
        guard let source else { return }
        isProcessing = true
        let settings = self.settings
        let (mesh, report) = await Task.detached(priority: .userInitiated) {
            PrintablePipeline.makePrintable(from: source, settings: settings)
        }.value

        // A newer run superseded this one.
        guard settings == self.settings else { return }

        printable = mesh
        self.report = report
        previewID = UUID()
        isProcessing = false

        if let thumbnail = ThumbnailRenderer.render(mesh) {
            store.saveThumbnail(thumbnail, for: scan)
        }
    }

    /// Writes the printable mesh in the selected format and returns the file.
    func exportFile() async throws -> URL {
        guard let printable else { throw CocoaError(.fileNoSuchFile) }
        isExporting = true
        defer { isExporting = false }

        let format = exportFormat
        let name = fileSafeName
        let url = store.exportsDirectory(for: scan).appendingPathComponent("\(name).\(format.fileExtension)")
        if format == .usdz {
            // SceneKit export stays on the main thread.
            try MeshExporter.write(printable, format: format, to: url, name: name)
        } else {
            try await Task.detached(priority: .userInitiated) {
                try MeshExporter.write(printable, format: format, to: url, name: name)
            }.value
        }
        return url
    }

    /// The model to show in AR Quick Look: the textured capture if there is
    /// one, otherwise a USDZ of the printable mesh.
    func arPreviewURL() async throws -> URL {
        if hasTexturedModel { return sourceURL }
        guard let printable else { throw CocoaError(.fileNoSuchFile) }
        let url = store.exportsDirectory(for: scan).appendingPathComponent("\(fileSafeName)-preview.usdz")
        try MeshExporter.write(printable, format: .usdz, to: url)
        return url
    }

    var emailSubject: String { "3D scan: \(scan.name)" }

    var emailBody: String {
        var lines = ["Here is a 3D-printable model scanned with PrintScan3D.", ""]
        if let report {
            let s = report.sizeMM
            lines.append(String(format: "Size: %.1f × %.1f × %.1f mm", s.x, s.y, s.z))
            lines.append("Triangles: \(report.triangleCount)")
            lines.append("Watertight: \(report.isWatertight ? "yes" : "no")")
        }
        lines.append("Format: \(exportFormat.title) (units: millimeters)")
        return lines.joined(separator: "\n")
    }

    private var fileSafeName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(scan.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Scan" : cleaned
    }
}
