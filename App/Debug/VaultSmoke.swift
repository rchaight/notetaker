import Foundation
import VaultKit

/// Headless smoke test against the REAL ubiquity container, for CLI-driven
/// verification: `NOTETAKER_VAULT_SMOKE=1 Notetaker.app/Contents/MacOS/Notetaker`
/// prints one line and exits 0/1.
enum VaultSmoke {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NOTETAKER_VAULT_SMOKE"] == "1" else { return }
        Task.detached {
            do {
                let documents = try await UbiquityContainer.documentsURL()
                let store = VaultFileStore()
                let probe = documents.appendingPathComponent("Debug/smoke-probe.md")

                try await store.writeString("# Smoke\n\n- [ ] round trip", to: probe)
                let contents = try await store.readString(at: probe)
                let items = VaultEnumerator.snapshot(of: documents)
                try await store.delete(at: probe)

                print("VAULT SMOKE OK container=\(documents.path) items=\(items.count) roundtrip=\(contents.count)b")
                exit(0)
            } catch {
                print("VAULT SMOKE FAILED: \(error)")
                exit(1)
            }
        }
    }
}
