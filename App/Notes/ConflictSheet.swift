import SwiftUI
import VaultKit

/// Resolves an iCloud sync conflict on one note: keep this device's copy, keep another
/// device's copy, or keep both as separate notes. The sheet never touches `NSFileVersion`
/// or the file itself — `VaultConflictCenter` does the work through `VaultFileStore`
/// (spec ux-phase1/05). It shows device names and dates only, never note bodies, so a locked
/// note's ciphertext is not displayed.
struct ConflictSheet: View {
    let note: VaultItem
    let model: NotesModel
    /// Runs after a resolution lands (the app rescans the index).
    var onResolved: () async -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [ConflictVersion] = []
    @State private var loaded = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Resolve Sync Conflict", systemImage: "exclamationmark.icloud")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "“\(NotesModel.noteTitle(ofPath: note.relativePath))” was edited on more than one device and iCloud could not merge the changes. Choose which copy to keep."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    copies
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if working {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .sheetFrame(minWidth: 440, idealWidth: 480, minHeight: 320)
        .task { await loadVersions() }
    }

    @ViewBuilder private var copies: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if versions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No conflicting copies are left — iCloud has already settled this note.")
                    .font(.callout)
                Button("Done") {
                    Task {
                        await onResolved()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                copyRow(
                    title: "This device",
                    detail: note.modificationDate.map(Self.describe) ?? "Modified date unknown",
                    button: "Keep This Device's Copy",
                    prominent: true
                ) { resolve(.keepCurrent) }
                ForEach(versions) { version in
                    let device = version.deviceName ?? "Other device"
                    copyRow(
                        title: device,
                        detail: version.modificationDate.map(Self.describe) ?? "Modified date unknown",
                        button: "Keep Copy from \(device)",
                        prominent: false
                    ) { resolve(.keepVersion(version)) }
                }
                Divider()
                Text(
                    "Keep both saves each other-device copy as its own note next to this one, named with the device and time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Keep Both as Separate Notes") { resolve(.keepBoth) }
                    .disabled(working)
            }
        }
    }

    private func copyRow(
        title: String, detail: String, button: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if prominent {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            } else {
                Button(button, action: action)
                    .disabled(working)
            }
        }
    }

    private static func describe(_ date: Date) -> String {
        "Edited " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Actions

    private func loadVersions() async {
        let url = note.url
        versions = await Task.detached(priority: .userInitiated) {
            VaultConflictCenter().unresolvedVersions(for: url)
        }.value
        loaded = true
    }

    private func resolve(_ resolution: ConflictResolution) {
        working = true
        errorMessage = nil
        Task {
            // Pending keystrokes first, or the 800 ms autosave could overwrite the version we
            // are about to choose. No title-sync rename: it would move the file out from under
            // the URL being resolved.
            await model.flushSave(allowRename: false)
            let target = model.notesById[note.id] ?? note
            do {
                _ = try await VaultConflictCenter().resolve(resolution, at: target.url, store: VaultFileStore())
                model.reloadIfDisplayed(noteId: target.id)
                await model.refresh()
                await onResolved()
                dismiss()
            } catch {
                errorMessage = "Couldn't resolve the conflict: \(error.localizedDescription)"
            }
            working = false
        }
    }
}
