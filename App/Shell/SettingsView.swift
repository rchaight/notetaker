import AIKit
import ConversionKit
import SecurityKit
import SwiftUI

/// Settings, organized into panes (M9.5 buildout): every persistent knob
/// in the app is discoverable here, grouped by surface.
struct SettingsView: View {
    /// General / Notes
    @AppStorage("noteSortOrder") private var noteSortOrder = "name"
    // Editor
    @AppStorage("editorFontSize") private var editorFontSize = 16.0
    @AppStorage("editorFontDesign") private var editorFontDesign = "system"
    @AppStorage("findHighlightColor") private var findHighlightColor = "yellow"
    @AppStorage("editorFocusMode") private var focusMode = false
    // To-Do
    @AppStorage("todoDensity") private var todoDensity = "comfortable"
    @AppStorage("showStreaks") private var showStreaks = false
    // Security
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appLockGrace") private var appLockGrace = 60.0
    // Vault
    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId
    @State private var showingVaultChooser = false
    // Conversion + AI
    @AppStorage("doclingServeURL") private var doclingServeURL = ""
    @State private var probeResult: String?
    @AppStorage("fileParserEngineDir") private var engineDirOverride = ""
    @AppStorage("fileParserOCR") private var engineOCR = true
    @AppStorage("fileParserTables") private var engineTables = true
    /// Keychain-backed (ThisDeviceOnly): endpoint config is homelab
    /// topology — it shouldn't sync or sit in plaintext defaults.
    @State private var ollamaURL = KeychainStore.migrateFromDefaults(
        key: "ollamaURL", account: "ollamaURL"
    )
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaProbe: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalPane
            }
            Tab("Editor", systemImage: "square.and.pencil") {
                editorPane
            }
            Tab("To-Do", systemImage: "checklist") {
                todoPane
            }
            Tab("Security", systemImage: "lock") {
                securityPane
            }
            Tab("Vault", systemImage: "externaldrive") {
                vaultPane
            }
            Tab("AI & Import", systemImage: "sparkles") {
                aiPane
            }
            #if DEBUG
                Tab("Debug", systemImage: "wrench.and.screwdriver") {
                    VaultDebugView()
                }
            #endif
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    // MARK: - Panes

    private var generalPane: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: "0.1.0 (pre-alpha)")
            }
            Section("Notes list") {
                Picker("Sort notes by", selection: $noteSortOrder) {
                    Text("Name").tag("name")
                    Text("Recently modified").tag("modified")
                }
            }
            Section("Shortcuts") {
                shortcutRow("⌘K", "Command palette")
                shortcutRow("⌘N", "New note")
                shortcutRow("⇧⌘N", "Quick Add task")
                shortcutRow("⇧⌘D", "Today's daily note")
                shortcutRow("⌘F", "Find in note")
                shortcutRow("⌘/", "Toggle markdown source")
                shortcutRow("⌃⌥⌘N", "Quick capture from anywhere")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) {
            Text(keys)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var editorPane: some View {
        Form {
            Section("Typography") {
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
            Section("Behavior") {
                Toggle("Focus mode (dim other paragraphs)", isOn: $focusMode)
                Picker("Find highlight (⌘F)", selection: $findHighlightColor) {
                    Text("Yellow").tag("yellow")
                    Text("Orange").tag("orange")
                    Text("Pink").tag("pink")
                    Text("Green").tag("green")
                    Text("Blue").tag("blue")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var todoPane: some View {
        Form {
            Section("Appearance") {
                Picker("Row density", selection: $todoDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Relaxed").tag("relaxed")
                }
                Toggle("Show streak chip", isOn: $showStreaks)
            }
            Section("How tasks work") {
                Text(
                    "Every to-do is a markdown line in a note: - [ ] text >due !p1 #label @person &every 7 days. Completing writes ✅date into the line; descriptions and links sync via your private iCloud database."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var securityPane: some View {
        Form {
            Section("App lock") {
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
            Section("iCloud encryption") {
                // ADP status has no public query API — nudge only.
                Text(
                    "Your vault syncs through iCloud Drive. For end-to-end encryption of iCloud data, enable Advanced Data Protection in System Settings › Apple Account › iCloud. Individually locked notes are end-to-end encrypted by Notetaker regardless."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Locked notes") {
                Text(
                    "Lock any note from the editor toolbar. Contents encrypt with your passphrase (PBKDF2 + AES-GCM); only ciphertext ever syncs. There is no recovery for a forgotten passphrase."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var vaultPane: some View {
        Form {
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
            Section("Registered folder vaults") {
                if VaultRegistry.entries.isEmpty {
                    Text("None — Choose Folder… above to add one (an Obsidian vault works).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(VaultRegistry.entries) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            if activeVault == entry.id {
                                Text("active").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Remove", role: .destructive) {
                                VaultRegistry.remove(id: entry.id)
                                if activeVault == entry.id {
                                    activeVault = VaultRegistry.iCloudId
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aiPane: some View {
        Form {
            Section("AI — Ollama (homelab)") {
                Text(
                    "AI runs on-device (Apple Intelligence) when available; Ollama is your own hardware. Every AI-generated block in a note is stamped with the provider that produced it. Nothing is sent to third-party clouds."
                )
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
                                let models = try await OllamaProvider(
                                    baseURL: url, model: "probe"
                                ).listModels()
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
                TextField(
                    "Docling server URL", text: $doclingServeURL,
                    prompt: Text("http://homelab:5001")
                )
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
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
