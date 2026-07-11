import SwiftUI
import VaultKit

/// M1 test harness: live view of the real iCloud vault with create/delete
/// actions and conflict resolution. Reached from Settings.
struct VaultDebugView: View {
    @State private var model = VaultDebugModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            List(model.items) { item in
                HStack {
                    Image(systemName: item.isDirectory ? "folder" : "doc.text")
                    Text(item.relativePath)
                    Spacer()
                    if item.hasUnresolvedConflicts {
                        Button("Keep Both") {
                            model.resolveConflicts(for: item)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    downloadBadge(for: item)
                }
            }

            HStack {
                Button("Create Test Note") { model.createTestNote() }
                Button("Delete Debug Folder", role: .destructive) { model.deleteTestNotes() }
                Spacer()
                Text(model.lastAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var statusHeader: some View {
        switch model.status {
        case .idle, .resolving:
            Label("Resolving iCloud container…", systemImage: "icloud")
        case let .ready(url):
            Label(url.path, systemImage: "icloud.fill")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        case let .unavailable(message):
            Label("iCloud unavailable: \(message)", systemImage: "icloud.slash")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private func downloadBadge(for item: VaultItem) -> some View {
        switch item.downloadState {
        case .current:
            Image(systemName: "checkmark.icloud").foregroundStyle(.green)
        case .downloaded:
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.yellow)
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
        }
    }
}
