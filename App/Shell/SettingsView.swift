import AIKit
import ConversionKit
import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId
    @State private var showingVaultChooser = false
    @AppStorage("doclingServeURL") private var doclingServeURL = ""
    @State private var probeResult: String?
    @AppStorage("fileParserEngineDir") private var engineDirOverride = ""
    @AppStorage("fileParserOCR") private var engineOCR = true
    @AppStorage("fileParserTables") private var engineTables = true
    @AppStorage("ollamaURL") private var ollamaURL = ""
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaProbe: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("General") {
                        LabeledContent("Version", value: "0.1.0 (pre-alpha)")
                    }
                    Section("Vault location") {
                        LabeledContent(
                            "Active vault",
                            value: VaultRegistry.activeCustomRoot()?.path
                                ?? "iCloud Drive › Notetaker"
                        )
                        HStack {
                            Button("Use iCloud Vault") {
                                activeVault = VaultRegistry.iCloudId
                            }
                            .disabled(activeVault == VaultRegistry.iCloudId)
                            Button("Choose Folder…") {
                                showingVaultChooser = true
                            }
                            .fileImporter(
                                isPresented: $showingVaultChooser,
                                allowedContentTypes: [.folder]
                            ) { outcome in
                                guard case let .success(url) = outcome,
                                      let entry = VaultRegistry.add(url: url) else { return }
                                activeVault = entry.id
                            }
                        }
                        Text("Switching vaults reloads the app shell. Folder vaults don't sync via iCloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Document conversion") {
                        #if os(macOS)
                            LabeledContent("Local engine") {
                                if let engine = PythonEngineConverter.resolveEngineDirectory() {
                                    Text(engine.path.replacingOccurrences(
                                        of: NSHomeDirectory(), with: "~"
                                    ))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("not found — install File-Parser or set a folder below")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            TextField(
                                "Engine folder override",
                                text: $engineDirOverride,
                                prompt: Text("~/Library/Application Support/File-Parser/engine")
                            )
                            .autocorrectionDisabled()
                            Toggle("OCR scanned pages (Docling)", isOn: $engineOCR)
                            Toggle("Table-structure detection (Docling)", isOn: $engineTables)
                        #endif
                        TextField("Docling server URL", text: $doclingServeURL, prompt: Text("http://homelab:5001"))
                            .autocorrectionDisabled()
                        HStack {
                            Button("Test Connection") {
                                probeResult = "testing…"
                                Task {
                                    guard let url = ServerURL.normalize(doclingServeURL) else {
                                        probeResult = "enter a URL like http://homelab:5001"
                                        return
                                    }
                                    let reachable = await DoclingServeConverter(baseURL: url).isReachable()
                                    probeResult = reachable
                                        ? "✓ docling-serve reachable"
                                        : "✗ not reachable — check the URL and that the container is running"
                                }
                            }
                            if let probeResult {
                                Text(probeResult)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(
                            "Converts DOCX, PPTX, XLSX and complex PDFs with full layout analysis. Run docling-serve on your homelab: docker run -p 5001:5001 quay.io/docling-project/docling-serve"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Section("AI — Ollama (homelab)") {
                        TextField("Ollama server URL", text: $ollamaURL, prompt: Text("http://homelab:11434"))
                            .autocorrectionDisabled()
                        HStack {
                            Button("Test Connection") {
                                ollamaProbe = "testing…"
                                Task {
                                    guard let url = ServerURL.normalize(ollamaURL) else {
                                        ollamaProbe = "enter a URL like http://localhost:11434"
                                        return
                                    }
                                    do {
                                        let models = try await OllamaProvider(baseURL: url, model: "probe").listModels()
                                        ollamaModels = models
                                        if ollamaModel.isEmpty, let first = models.first {
                                            ollamaModel = first
                                        }
                                        ollamaProbe = "✓ \(models.count) model(s) available"
                                    } catch {
                                        ollamaProbe = "✗ not reachable"
                                    }
                                }
                            }
                            if let ollamaProbe {
                                Text(ollamaProbe)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !ollamaModels.isEmpty {
                            Picker("Model", selection: $ollamaModel) {
                                ForEach(ollamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        } else if !ollamaModel.isEmpty {
                            LabeledContent("Model", value: ollamaModel)
                        }
                        Text(
                            "Long notes beyond the on-device model's window route here; content only ever goes to your own server."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Vault", systemImage: "icloud") {
                VaultDebugView()
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

#Preview {
    SettingsView()
}
