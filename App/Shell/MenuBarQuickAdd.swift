#if os(macOS)
    import SwiftUI
    import TaskEngine
    import VaultKit

    /// Menu-bar capture: jot a task from any app; it lands in the vault's
    /// Inbox.md through the same grammar as Quick Add. Writes directly via
    /// the coordinated file layer — the running app's observers reindex.
    struct MenuBarQuickAddView: View {
        @State private var text = ""
        @State private var status: String?
        @FocusState private var focused: Bool
        private let store = VaultFileStore()

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to Inbox")
                    .font(.headline)
                TextField("email dean tomorrow p1 #admin", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .focused($focused)
                    .onSubmit { submit() }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.hasPrefix("Added") ? .green : .red)
                }
            }
            .padding(12)
            .onAppear { focused = true }
        }

        private func submit() {
            let input = text.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { return }
            guard let root = Self.vaultRoot() else {
                status = "Vault unavailable"
                return
            }
            guard let line = QuickAddParser.parse(input)?.markdownLine else {
                status = "Couldn't parse task"
                return
            }
            Task {
                let inbox = root.appendingPathComponent("Inbox.md")
                let existing = await (try? store.readString(at: inbox)) ?? "# Inbox\n"
                let updated = (existing.hasSuffix("\n") ? existing : existing + "\n") + line + "\n"
                do {
                    try await store.writeString(updated, to: inbox)
                    status = "Added ✓"
                    text = ""
                    try? await Task.sleep(for: .seconds(1))
                    status = nil
                } catch {
                    status = "Write failed"
                }
            }
        }

        /// Same resolution order as the app: custom folder vault, then the
        /// iCloud container's deterministic path.
        static func vaultRoot() -> URL? {
            VaultRegistry.activeCustomRoot()
                ?? UbiquityContainer.wellKnownDocumentsURL(
                    containerIdentifier: "iCloud.com.rchaight.notetaker"
                )
        }
    }
#endif
