import Foundation
import Observation
import VaultKit

/// Backing model for the vault debug harness: resolves the real ubiquity
/// container, observes it live, and offers create/delete/resolve actions.
@MainActor
@Observable
final class VaultDebugModel {
    enum Status: Equatable {
        case idle
        case resolving
        case ready(URL)
        case unavailable(String)
    }

    var status: Status = .idle
    var items: [VaultItem] = []
    var lastAction = "—"

    private let store = VaultFileStore()
    private var observer: MetadataQueryObserver?
    private var observation: Task<Void, Never>?
    private var root: URL?

    func start() {
        guard status == .idle else { return }
        status = .resolving
        Task {
            do {
                let documents = try await UbiquityContainer.documentsURL()
                root = documents
                status = .ready(documents)
                items = VaultEnumerator.snapshot(of: documents)

                let observer = MetadataQueryObserver(root: documents)
                self.observer = observer
                observation = Task {
                    for await snapshot in observer.snapshots() {
                        self.items = snapshot
                    }
                }
            } catch {
                status = .unavailable("\(error)")
            }
        }
    }

    func stop() {
        observer?.stop()
        observation?.cancel()
    }

    func createTestNote() {
        guard let root else { return }
        Task {
            let name = "Debug/Test Note \(Int.random(in: 1000 ... 9999)).md"
            let url = root.appendingPathComponent(name)
            do {
                try await store.writeString("# Test\n\nCreated by the vault debug harness.\n\n- [ ] sync me", to: url)
                lastAction = "created \(name)"
            } catch {
                lastAction = "create failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteTestNotes() {
        guard let root else { return }
        Task {
            let debugFolder = root.appendingPathComponent("Debug", isDirectory: true)
            do {
                try await store.delete(at: debugFolder)
                lastAction = "deleted Debug/"
            } catch {
                lastAction = "delete failed: \(error.localizedDescription)"
            }
        }
    }

    func resolveConflicts(for item: VaultItem) {
        Task {
            do {
                let preserved = try await VaultConflictCenter().resolveKeepingBoth(at: item.url, store: store)
                lastAction = "kept both: \(preserved.count) version(s) preserved"
            } catch {
                lastAction = "resolve failed: \(error.localizedDescription)"
            }
        }
    }
}
