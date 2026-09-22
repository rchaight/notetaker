import AIKit
import ConversionKit
import EditorKit
import ProofKit
import SecurityKit
import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// Settings, organized into panes (M9.5 buildout): every persistent knob
/// in the app is discoverable here, grouped by surface.
struct SettingsView: View {
    /// General / Notes
    @AppStorage("noteSortOrder") private var noteSortOrder = "name"
    // Calendar
    @AppStorage("dailyNoteTemplate") private var dailyTemplate = NotesModel.defaultDailyTemplate
    @State private var calendarAccess = CalendarService.accessState()
    @State private var calendarList: [(id: String, title: String, account: String)] = []
    @State private var excludedIds: Set<String> = []
    // Editor — per-mode font design + size (spec 04); Live keeps the
    // legacy keys, Source/Reading get their own via EditorFontPreferences.
    @AppStorage(EditorFontPreferences.keys(for: .live).design) private var liveFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .live).size) private var liveFontSize = Double(EditorFontPreferences
        .defaultSize)
    @AppStorage(EditorFontPreferences.keys(for: .source).design) private var sourceFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .source).size) private var sourceFontSize = Double(EditorFontPreferences
        .defaultSize)
    @AppStorage(EditorFontPreferences.keys(for: .reading).design) private var readingFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .reading).size) private var readingFontSize =
        Double(EditorFontPreferences.defaultSize)
    @AppStorage("findHighlightColor") private var findHighlightColor = "yellow"
    @AppStorage("editorFocusMode") private var focusMode = false
    @AppStorage("editorMode") private var editorMode = EditorMode.live
    @AppStorage("headingScale") private var headingScalePercent = 100.0
    // Proofing (spec 01): system spell/grammar checking, token-aware.
    // Autocorrect is off by user decision — see the section's caption.
    @AppStorage("proofSpelling") private var proofSpelling = true
    @AppStorage("proofGrammar") private var proofGrammar = true
    @AppStorage("proofAutocorrect") private var proofAutocorrect = false
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
    @AppStorage("aiPreferOllama") private var aiPreferOllama = true
    @State private var ollamaModels: [String] = []
    @State private var ollamaProbe: String?
    /// LanguageTool (proofing) — same Keychain policy as `ollamaURL`.
    @State private var languageToolURL = KeychainStore.migrateFromDefaults(
        key: "languageToolURL", account: "languageToolURL"
    )
    @AppStorage("languageToolLanguage") private var languageToolLanguage = "auto"
    @State private var languageToolLanguages: [LanguageToolProvider.Language] = []
    @State private var languageToolProbe: String?
    // Claude / MCP integration. Key is shared with VaultIndexService, which
    // owns the actual _index.md / CLAUDE.md generation (M9.8 spec 01).
    @AppStorage("claudeIndexFiles") private var claudeIndexFiles = true
    #if os(macOS)
        @State private var mcpCopyFeedback: String?
    #endif

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
            Tab("Calendar", systemImage: "calendar") {
                calendarPane
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

    private var calendarPane: some View {
        Form {
            Section("Connection") {
                switch calendarAccess {
                case .granted:
                    Label("Connected — meetings populate new daily notes", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                case .denied:
                    Label("Access denied", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Text("Enable in System Settings › Privacy & Security › Calendars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notRequested:
                    Button("Connect Calendars…") {
                        Task {
                            _ = await CalendarService.requestAccess()
                            calendarAccess = CalendarService.accessState()
                            calendarList = CalendarService.availableCalendars()
                        }
                    }
                }
                Text(
                    "Works with Apple, Google, and Outlook calendars — any account added to the system Calendar app (System Settings › Internet Accounts). Events are read on-device only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if calendarAccess == .granted {
                Section("Included calendars") {
                    if calendarList.isEmpty {
                        Text("No calendars found.").foregroundStyle(.secondary)
                    }
                    ForEach(calendarList, id: \.id) { entry in
                        Toggle(
                            "\(entry.title) — \(entry.account)",
                            isOn: Binding(
                                get: { !excludedIds.contains(entry.id) },
                                set: { include in
                                    CalendarService.setExcluded(entry.id, excluded: !include)
                                    excludedIds = CalendarService.excludedCalendarIds()
                                }
                            )
                        )
                    }
                }
            }
            Section("Daily note template") {
                TextEditor(text: $dailyTemplate)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                HStack {
                    Text(
                        "Placeholders: {{date}} {{weekday}} {{time}} {{meetings}} {{weektodos}} {{continuous}} {{horizon}}"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        dailyTemplate = NotesModel.defaultDailyTemplate
                    }
                    .disabled(dailyTemplate == NotesModel.defaultDailyTemplate)
                }
                Text(
                    "Each meeting renders as a top-level # heading with blank lines after it — room for notes under every event."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            calendarAccess = CalendarService.accessState()
            calendarList = CalendarService.availableCalendars()
            excludedIds = CalendarService.excludedCalendarIds()
        }
    }

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
            Section("Fonts") {
                fontRow(
                    "Source", design: $sourceFontDesign, size: $sourceFontSize,
                    resetDesign: EditorFontPreferences.resetDesign(for: .source)
                )
                fontRow(
                    "Live Preview", design: $liveFontDesign, size: $liveFontSize,
                    resetDesign: EditorFontPreferences.resetDesign(for: .live)
                )
                fontRow(
                    "Reading", design: $readingFontDesign, size: $readingFontSize,
                    resetDesign: EditorFontPreferences.resetDesign(for: .reading)
                )
                HStack {
                    Stepper(
                        "Heading size: \(Int(headingScalePercent))%",
                        value: $headingScalePercent, in: 0 ... 120, step: 10
                    )
                    Button("Reset") { headingScalePercent = 100 }
                        .disabled(headingScalePercent == 100)
                }
                Text(
                    "Applies to body text. Heading size scales the headings in every mode — lower it to shrink them (0% = same as body). Code blocks stay monospaced. ⌘= and ⌘− resize the mode you're in; ⌘0 resets it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("View mode") {
                Picker("Default mode for notes", selection: $editorMode) {
                    ForEach(EditorMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("⌘E cycles Source → Live Preview → Reading. ⌘/ flips between Source and Live Preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Proofing") {
                Toggle("Check spelling while typing", isOn: $proofSpelling)
                #if os(macOS)
                    // macOS only: UIKit has no grammar checking.
                    Toggle("Check grammar", isOn: $proofGrammar)
                        .disabled(!proofSpelling)
                #endif
                Toggle("Correct spelling automatically", isOn: $proofAutocorrect)
                Text(
                    "Off keeps #tags, @handles and identifiers exactly as typed; misspellings get an underline and right-click suggestions instead. Markdown syntax, code, links and task tokens are never checked."
                )
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

    /// One row of the Fonts section: a design picker, a size stepper, and a
    /// reset that restores `resetDesign` (Monospaced for Source, System for
    /// Live/Reading — the same defaults `migrateIfNeeded` seeds) + the
    /// shared default size.
    private func fontRow(
        _ label: String, design: Binding<String>, size: Binding<Double>, resetDesign: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("\(label) font", selection: design) {
                Text("System").tag("system")
                Text("Serif").tag("serif")
                Text("Rounded").tag("rounded")
                Text("Monospaced").tag("mono")
            }
            HStack {
                Stepper(
                    "Size: \(Int(size.wrappedValue)) pt",
                    value: size,
                    in: Double(EditorFontPreferences.minSize) ... Double(EditorFontPreferences.maxSize),
                    step: 1
                )
                Button("Reset") {
                    design.wrappedValue = resetDesign
                    size.wrappedValue = Double(EditorFontPreferences.defaultSize)
                }
                .disabled(
                    design.wrappedValue == resetDesign
                        && size.wrappedValue == Double(EditorFontPreferences.defaultSize)
                )
            }
        }
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
                Toggle("Prefer Ollama for summaries and action items", isOn: $aiPreferOllama)
                Text(
                    aiPreferOllama
                        ? "Your Ollama server runs first; Apple Intelligence takes over only if it can't be reached."
                        : "Apple Intelligence runs first; Ollama handles what exceeds it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Section("LanguageTool") {
                Text(
                    "Self-hosted grammar checking. Run the erikvl87/languagetool container on your homelab; nothing leaves your network."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField(
                    "LanguageTool server URL", text: $languageToolURL, prompt: Text("http://homelab:8010")
                )
                .onChange(of: languageToolURL) {
                    KeychainStore.save(languageToolURL, account: "languageToolURL")
                }
                .autocorrectionDisabled()
                HStack {
                    Button("Test Connection") {
                        languageToolProbe = "testing…"
                        Task {
                            guard let url = ServerURL.normalize(languageToolURL) else {
                                languageToolProbe = "enter a URL like http://localhost:8010"
                                return
                            }
                            do {
                                let languages = try await LanguageToolProvider(baseURL: url).listLanguages()
                                languageToolLanguages = languages
                                languageToolProbe = "✓ \(languages.count) language(s) available"
                            } catch {
                                languageToolProbe = "✗ not reachable"
                            }
                        }
                    }
                    if let languageToolProbe {
                        Text(languageToolProbe)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !languageToolLanguages.isEmpty {
                    Picker("Preferred language", selection: $languageToolLanguage) {
                        Text("Auto").tag("auto")
                        ForEach(languageToolLanguages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
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
            Section("Claude integration") {
                Toggle(
                    "Maintain _index.md tables of contents and a CLAUDE.md guide in the vault for AI assistants",
                    isOn: $claudeIndexFiles
                )
                if !claudeIndexFiles {
                    Text("Existing files are left in place but no longer updated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #if os(macOS)
                    mcpServerBlock
                #else
                    Text("The bundled MCP server is macOS-only; on iOS only the vault context files above apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
    }

    #if os(macOS)
        /// Resolved path to the MCP server bundled as a sibling executable
        /// (`Contents/MacOS/notetaker-mcp`, embedded by spec 02's copy-files
        /// build phase — not a framework, so `Bundle.main` alone won't find it).
        private var mcpBinaryURL: URL {
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notetaker-mcp")
        }

        private var mcpInstallCommand: String {
            "claude mcp add notetaker -- \"\(mcpBinaryURL.path)\""
        }

        @ViewBuilder
        private var mcpServerBlock: some View {
            let binaryExists = FileManager.default.fileExists(atPath: mcpBinaryURL.path)
            LabeledContent("Bundled server binary") {
                if binaryExists {
                    Text(mcpBinaryURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Label("Not found in this build", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if binaryExists {
                HStack {
                    Text(mcpInstallCommand)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(mcpInstallCommand, forType: .string)
                        mcpCopyFeedback = "Copied to clipboard"
                    }
                    .controlSize(.small)
                }
                if let mcpCopyFeedback {
                    Text(mcpCopyFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Rebuild the app with the notetaker-mcp target embedded to enable this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "Using Claude Desktop instead of Claude Code? Add the path above as a new server in its MCP settings (Settings › Developer)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "Read-only access to your vault; works even while Notetaker is closed. Locked notes are never exposed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    #endif
}

#Preview {
    SettingsView()
}
