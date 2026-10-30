import SwiftUI

struct ScanDetailView: View {
    @StateObject private var model: ScanDetailModel
    @State private var sheet: Sheet?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var mailUnavailable = false

    private enum Sheet: Identifiable {
        case share(URL)
        case mail(URL)
        case arPreview(URL)

        var id: String {
            switch self {
            case .share(let url): return "share-\(url.path)"
            case .mail(let url): return "mail-\(url.path)"
            case .arPreview(let url): return "ar-\(url.path)"
            }
        }
    }

    init(scan: Scan, store: ScanStore) {
        _model = StateObject(wrappedValue: ScanDetailModel(scan: scan, store: store))
    }

    var body: some View {
        Form {
            previewSection
            readinessSection
            sizeSection
            repairSection
            sourceSection
            exportSection
        }
        .navigationTitle(model.scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        renameText = model.scan.name
                        isRenaming = true
                    }
                    Button("View in AR", systemImage: "arkit") { showARPreview() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .share(let url):
                ActivityView(items: [url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            case .mail(let url):
                MailComposeView(subject: model.emailSubject, body: model.emailBody, attachmentURL: url,
                                mimeType: model.exportFormat.mimeType) { self.sheet = nil }
                    .ignoresSafeArea()
            case .arPreview(let url):
                ARQuickLookView(url: url)
                    .ignoresSafeArea()
            }
        }
        .alert("Rename Scan", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(to: renameText) }
        }
        .alert("Mail isn't set up", isPresented: $mailUnavailable) {
            Button("Use Share Sheet") { share() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add a mail account in Settings, or send the file with Gmail, Outlook or any other app from the share sheet.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var previewSection: some View {
        Section {
            ZStack(alignment: .bottomLeading) {
                PrintPreviewView(mesh: model.printable, meshID: model.previewID)
                    .frame(height: 340)

                if let report = model.report {
                    Text(dimensions(report.sizeMM))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }

                if model.isProcessing {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(10)
                }
            }
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var readinessSection: some View {
        if let report = model.report {
            Section("Print readiness") {
                Label {
                    Text(report.isWatertight ? "Watertight — ready to slice" : "Not fully closed")
                } icon: {
                    Image(systemName: report.isWatertight ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.isWatertight ? .green : .orange)
                }
                LabeledContent("Size", value: dimensions(report.sizeMM))
                LabeledContent("Volume", value: String(format: "%.1f cm³", report.volumeMM3 / 1000))
                LabeledContent("Triangles", value: report.triangleCount.formatted())
                if report.holesFilled > 0 {
                    LabeledContent("Holes filled", value: "\(report.holesFilled)")
                }
                if report.partsRemoved > 0 {
                    LabeledContent("Loose parts removed", value: "\(report.partsRemoved)")
                }
                if report.partCount > 1 {
                    LabeledContent("Separate parts", value: "\(report.partCount)")
                }
                if !report.isWatertight {
                    Text("\(report.openEdges) open and \(report.nonManifoldEdges) non-manifold edges remain. Most slicers will still repair this automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            Picker("Sizing", selection: $model.settings.sizing) {
                ForEach(PrintSettings.Sizing.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch model.settings.sizing {
            case .realSize:
                Stepper(value: $model.settings.scalePercent, in: 1...1000, step: 5) {
                    LabeledContent("Scale", value: "\(Int(model.settings.scalePercent))%")
                }
            case .fitLongestSide:
                VStack(alignment: .leading) {
                    LabeledContent("Longest side", value: "\(Int(model.settings.targetLongestSideMM)) mm")
                    Slider(value: $model.settings.targetLongestSideMM, in: 10...300, step: 1)
                }
            }
        }
    }

    private var repairSection: some View {
        Section {
            Toggle("Fill holes", isOn: $model.settings.fillHoles)
            Toggle("Remove loose fragments", isOn: $model.settings.removeFloaters)
            Toggle("Keep largest part only", isOn: $model.settings.keepLargestPartOnly)
            VStack(alignment: .leading) {
                LabeledContent("Flat base cut", value: String(format: "%.1f mm", model.settings.flatBaseCutMM))
                Slider(value: $model.settings.flatBaseCutMM, in: 0...20, step: 0.5)
            }
        } header: {
            Text("Make printable")
        } footer: {
            Text("A flat base cut slices off the bottom so the model sits flat on the print bed.")
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Units", selection: $model.settings.sourceUnit) {
                ForEach(LengthUnit.allCases) { Text($0.title).tag($0) }
            }
            Picker("Orientation", selection: $model.settings.sourceUpAxis) {
                ForEach(UpAxis.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("\(model.scan.method.title) · \(model.scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private var exportSection: some View {
        Section {
            Picker("Format", selection: $model.exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    VStack(alignment: .leading) {
                        Text(format.title)
                        Text(format.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(format)
                }
            }
            .pickerStyle(.navigationLink)

            Button {
                share()
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                email()
            } label: {
                Label("Email", systemImage: "envelope")
            }
            Button {
                showARPreview()
            } label: {
                Label("View in AR", systemImage: "arkit")
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Share sends the file to Messages, Messenger, WhatsApp, AirDrop, Files and more. Exports are in millimeters with Z up, centered and resting on the bed.")
        }
        .disabled(model.printable == nil || model.isExporting)
    }

    // MARK: Actions

    private func share() {
        Task {
            do {
                sheet = .share(try await model.exportFile())
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func email() {
        guard MailComposeView.canSendMail else {
            mailUnavailable = true
            return
        }
        Task {
            do {
                sheet = .mail(try await model.exportFile())
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func showARPreview() {
        Task {
            do {
                sheet = .arPreview(try await model.arPreviewURL())
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func dimensions(_ size: SIMD3<Float>) -> String {
        String(format: "%.1f × %.1f × %.1f mm", size.x, size.y, size.z)
    }
}
