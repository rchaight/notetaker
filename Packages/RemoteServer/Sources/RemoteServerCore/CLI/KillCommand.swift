import Foundation

/// `notetaker-remote kill` (root only). Exposure is cut first (Funnel off,
/// service stopped), then tokens, index and replica are wiped. Each step is best-effort and reported;
/// exit 0 only if every step succeeded. The service may already be gone, so a
/// failing `systemctl`/`tailscale` is reported, not fatal to the other steps.
public struct KillCommand: Sendable {
    public static let notRoot: Int32 = 64

    public let config: RemoteConfig
    public let actions: any SystemActions
    public let audit: AuditLog?

    public init(config: RemoteConfig, actions: any SystemActions, audit: AuditLog? = nil) {
        self.config = config
        self.actions = actions
        self.audit = audit
    }

    public func run(report: (String) -> Void) async -> Int32 {
        guard actions.effectiveUserID() == 0 else {
            report("kill: must run as root (euid 0); nothing was changed")
            return Self.notRoot
        }
        var allOK = true
        func step(_ name: String, _ body: () -> Bool) {
            let ok = body()
            allOK = allOK && ok
            report("kill: \(name): \(ok ? "ok" : "FAILED")")
        }
        // Cut exposure first: the public URL goes dark before anything is wiped.
        step("tailscale funnel off") { actions.run("tailscale", arguments: ["funnel", "--https=443", "off"]) }
        step("systemctl stop notetaker-remote") { actions.run("systemctl", arguments: ["stop", "notetaker-remote"]) }
        step("delete tokens.sqlite") { actions.removeFile(at: config.tokensURL) }
        // WAL mode: recent token rows can live only in the -wal sidecar.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: config.tokensURL.path + suffix)
            step("delete tokens.sqlite\(suffix)") { actions.removeFile(at: sidecar) }
        }
        step("delete index.sqlite") { actions.removeFile(at: config.indexURL) }
        // A rebuild in flight leaves `index.tmp-*.sqlite` (+ journal) holding note text; the service only sweeps
        // those on its next start, so a kill must not leave them behind.
        step("delete index leftovers") { actions.removeFiles(in: config.stateDir, withPrefix: "index") }
        step("remove replica contents") { actions.removeContents(of: config.replicaDir) }
        step("write DISABLED marker") { actions.writeMarker(at: config.disabledMarkerURL) }
        await audit?.record(AuditEvent(event: "kill", status: allOK ? "ok" : "partial"))
        return allOK ? 0 : 1
    }
}
