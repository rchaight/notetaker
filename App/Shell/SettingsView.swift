import AIKit
import ConversionKit
import SecurityKit
import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId
    @State private var showingVaultChooser = false
    @AppStorage("editorFontSize") private var editorFontSize = 16.0
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appLockGrace") private var appLockGrace = 60.0
    @AppStorage("editorFontDesign") private var editorFontDesign = "system"
    @AppStorage("doclingServeURL") private var doclingServeURL = ""
    @State private var probeResult: String?
    @AppStorage("fileParserEngineDir") private var engineDirOverride = ""
    @AppStorage("fileParserOCR") private var engineOCR = true
    @AppStorage("fileParserTables") private var engineTables = true
    // Keychain-backed (ThisDeviceOnly): endpoint config is homelab
    // topology — it shouldn't sync or sit in plaintext defaults.
    @State private var ollamaURL = KeychainStore.migrateFromDefaults(
        key: "ollamaURL", account: "ollamaURL"
    )
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
                    Section("Security") {
                        // ADP status has no public query API — nudge only.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud encryption")
                            Text("Your vault syncs through iCloud Drive. For end-to-end encryption of iCloud data, enable Advanced Data Protection in System Settings › Apple Account › iCloud. Individually locked notes are end-to-end encrypted by Notetaker regardless.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        Toggle("Require unlock (Touch ID / password)", isOn: $appLockEnabled)
                        if appLockEnabled {
                            Picker("Require again after", selection: $appLockGrace) {
                                Text("Immediately").tag(0.0)
                                Text("1 minute").tag(60.0)
                                Text("5 minutes").tag(300.0)
                                Text("1 hour").tag(3600.0)
                            }
                            Text("Locks on launch and when returning to the app outside the grace window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Editor") {
                        Picker("Font", selection: $editorFontDesign) {
                            Text("System").tag("system")
                            Text("Serif").tag("serif")
                            Text("Rounded").tag("rounded")
                            Text("Monospaced").tag("mono")
                        }
                        HStack {
                            Stepper(
                                "Text size: \(Int(editorFontSize)) pt",
                                value: $editorFontSize, in: 11 ... 28, step: 1
                            )
                            Button("Reset") { editorFontSize = 16 }
                                .disabled(editorFontSize == 16)
                        }
                        Text("Applies to body text; headings scale proportionally. Code blocks stay monospaced.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        Text("AI runs on-device (Apple Intelligence) when available; Ollama is your own hardware. Every AI-generated block in a note is stamped with the provider that produced it. Nothing is sent to third-party clouds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Ollama server URL", text: $ollamaURL, prompt: Text("http://homelab:11434"))
                            .onChange(of: ollamaURL) {
                                KeychainStore.save(ollamaURL, account: "ollamaURL")
                            }
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
