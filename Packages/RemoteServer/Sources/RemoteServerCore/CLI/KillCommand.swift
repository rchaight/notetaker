import Foundation

/// `notetaker-remote kill` (root only). Each step is best-effort and reported;
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
        step("delete tokens.sqlite") { actions.removeFile(at: config.tokensURL) }
        step("delete index.sqlite") { actions.removeFile(at: config.indexURL) }
        step("remove replica contents") { actions.removeContents(of: config.replicaDir) }
        step("write DISABLED marker") { actions.writeMarker(at: config.disabledMarkerURL) }
        step("systemctl stop notetaker-remote") { actions.run("systemctl", arguments: ["stop", "notetaker-remote"]) }
        step("tailscale funnel off") { actions.run("tailscale", arguments: ["funnel", "--https=443", "off"]) }
        await audit?.record(AuditEvent(event: "kill", status: allOK ? "ok" : "partial"))
        return allOK ? 0 : 1
    }
}
