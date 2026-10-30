import SwiftUI
import UniformTypeIdentifiers

struct ScanLibraryView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var path: [UUID] = []
    @State private var capture: CaptureSession?
    @State private var isImporting = false
    @State private var errorMessage: String?

    private enum CaptureSession: Identifiable {
        case objectCapture(id: UUID, workspace: URL)
        case lidar

        var id: String {
            switch self {
            case .objectCapture(let id, _): return id.uuidString
            case .lidar: return "lidar"
            }
        }
    }

    private static let importTypes: [UTType] =
        [.usdz, .threeDContent] + MeshImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("PrintScan 3D")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { newScanMenu }
            }
            .navigationDestination(for: UUID.self) { id in
                if let scan = store.scan(withID: id) {
                    ScanDetailView(scan: scan, store: store)
                }
            }
        }
        .fullScreenCover(item: $capture) { session in
            switch session {
            case .objectCapture(let id, let workspace):
                ObjectCaptureFlowView(scanID: id, workspace: workspace) {
                    finishObjectCapture(id: id)
                } onCancel: {
                    store.discardWorkspace(id: id)
                    capture = nil
                }
            case .lidar:
                LiDARScanView { mesh in
                    capture = nil
                    do {
                        let scan = try store.addLiDARScan(mesh)
                        path = [scan.id]
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } onCancel: {
                    capture = nil
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes) { result in
            do {
                let scan = try store.importModel(from: result.get())
                path = [scan.id]
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Subviews

    private var newScanMenu: some View {
        Menu {
            Button {
                startObjectCapture()
            } label: {
                Label("Object Capture", systemImage: "camera.viewfinder")
                Text("LiDAR + photogrammetry, highest detail")
            }
            .disabled(!ObjectCaptureController.isSupported)

            Button {
                capture = .lidar
            } label: {
                Label("LiDAR Quick Scan", systemImage: "sensor.fill")
                Text("Instant, low detail. Objects 15 cm and up")
            }
            .disabled(!LiDARScanner.isSupported)

            Divider()

            Button {
                isImporting = true
            } label: {
                Label("Import Model File", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "cube.transparent")
        } description: {
            Text(supportDescription)
        } actions: {
            Button {
                startObjectCapture()
            } label: {
                Label("Scan an Object", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ObjectCaptureController.isSupported)

            Button("LiDAR Quick Scan") { capture = .lidar }
                .disabled(!LiDARScanner.isSupported)
            Button("Import a Model File") { isImporting = true }
        }
    }

    private var supportDescription: String {
        if ObjectCaptureController.isSupported {
            return "Scan an object with LiDAR and photogrammetry, then export a print-ready STL or 3MF."
        }
        if LiDARScanner.isSupported {
            return "Object Capture isn't available on this device, but LiDAR Quick Scan is."
        }
        return "Scanning needs an iPhone or iPad with a LiDAR sensor. You can still import and convert model files."
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                ForEach(store.scans) { scan in
                    NavigationLink(value: scan.id) {
                        ScanCard(scan: scan, thumbnail: store.thumbnail(for: scan), revision: store.thumbnailRevision)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.delete(scan)
                        }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: Actions

    private func startObjectCapture() {
        let workspace = store.makeWorkspace()
        capture = .objectCapture(id: workspace.id, workspace: workspace.directory)
    }

    private func finishObjectCapture(id: UUID) {
        capture = nil
        do {
            let scan = try store.register(id: id, method: .objectCapture, sourceFileName: "source.usdz")
            path = [scan.id]
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ScanCard: View {
    let scan: Scan
    let thumbnail: UIImage?
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(white: 0.12)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .id(revision)

            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Label(scan.method.title, systemImage: scan.method.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
