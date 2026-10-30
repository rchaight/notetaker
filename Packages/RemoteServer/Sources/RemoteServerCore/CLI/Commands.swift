import AIKit
import Foundation
import MCP
import MCPKit

/// Argument dispatch for `notetaker-remote`. `main.swift` only forwards here.
public enum Commands {
    public static let usage = "usage: notetaker-remote [serve | status | reindex | audit-replica | kill]"

    public static func run(
        arguments: [String],
        environment: [String: String],
        authenticator: (any BearerAuthenticator)? = nil,
        actions: any SystemActions = LiveSystemActions()
    ) async -> Int32 {
        let command = arguments.first ?? "serve"
        let config: RemoteConfig
        do {
            config = try RemoteConfig(environment: environment)
        } catch {
            printErr("notetaker-remote: configuration error: \(error)")
            return 78
        }
        let audit = AuditLog(url: config.auditLog)
        switch command {
        case "serve":
            return await serve(config: config, authenticator: authenticator, audit: audit)
        case "status":
            return await status(config: config)
        case "reindex":
            let watcher = ReplicaWatcher(config: config, audit: audit)
            let state = await watcher.reindex()
            print("reindex: replica \(state.label)")
            if case .ready = state {
                return 0
            }
            return 1
        case "audit-replica":
            return await AuditReplicaCommand(config: config, audit: audit).run(report: { print($0) })
        case "kill":
            return await KillCommand(config: config, actions: actions, audit: audit).run(report: { print($0) })
        default:
            printErr(usage)
            return 64
        }
    }

    // MARK: - serve

    /// `authenticator == nil` (the shipped path): the spec 07 OAuth server over
    /// `tokens.sqlite`, whose `TokenAuthenticator` guards `/mcp`. Its settings are
    /// required here — `serve` refuses to start (exit 78) without them.
    static func serve(config: RemoteConfig, authenticator: (any BearerAuthenticator)?, audit: AuditLog) async -> Int32 {
        do {
            let limiter = RateLimiter()
            let oauth: OAuthServer?
            if authenticator == nil {
                let settings: OAuthSettings
                do {
                    settings = try OAuthSettings(config: config)
                } catch {
                    printErr("notetaker-remote: configuration error: \(error)")
                    return 78
                }
                oauth = try OAuthServer(
                    config: config, settings: settings, store: TokenStore(url: config.tokensURL),
                    limiter: limiter, audit: audit
                )
            } else {
                oauth = nil
            }
            guard let guardian = authenticator ?? oauth?.authenticator else { return 78 }
            let watcher = ReplicaWatcher(config: config, audit: audit)
            await watcher.tick()
            var limits = ToolGateway.Limits()
            limits.staleAfterHours = config.staleAfterHours
            let gateway = ToolGateway(replica: watcher, limits: limits, audit: audit)
            let mcp = try await RemoteMCPServer(gateway: gateway)
            let app = RemoteApp.build(
                config: config, authenticator: guardian, mcp: mcp, limiter: limiter, audit: audit,
                extraRoutes: { router in oauth?.register(on: router) }
            )
            await audit.record(AuditEvent(event: "server.start", reason: "bind=\(config.bindHost):\(config.bindPort)"))
            let polling = Task { await watcher.run() }
            let housekeeping = Task { await oauth?.housekeepingLoop() }
            let forwarded = Task { await reportUnparseableForwardedFor(audit: audit) }
            defer {
                polling.cancel()
                housekeeping.cancel()
                forwarded.cancel()
            }
            try await app.runService() // SIGTERM/SIGINT → graceful stop
            return 0
        } catch {
            printErr("notetaker-remote: \(error)")
            return 1
        }
    }

    /// Once a minute: how many requests carried an X-Forwarded-For whose last
    /// hop was not an address (one audit line, only when non-zero).
    static func reportUnparseableForwardedFor(audit: AuditLog, every interval: Duration = .seconds(60)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            let count = ForwardedFor.drainUnparseable()
            if count > 0 {
                await audit.record(AuditEvent(event: "xff.unparseable", resultCount: count))
            }
        }
    }

    // MARK: - status

    static func status(config: RemoteConfig) async -> Int32 {
        // A read-only look: verify the replica without building or replacing anything.
        let outcome = ReplicaVerifier(config: config).verify()
        switch outcome {
        case .empty: print("replica: empty")
        case .disabled: print("replica: disabled")
        case let .inconsistent(reason): print("replica: inconsistent (\(reason))")
        case let .ok(verified):
            print(
                "replica: ready (generated \(DateParsing.string(verified.manifest.generatedAt)), \(verified.manifest.noteCount) notes)"
            )
        }
        if FileManager.default.fileExists(atPath: config.indexURL.path) {
            let overview = VaultService(location: VaultLocation(
                root: config.vaultDir, indexPath: config.indexURL.path, origin: .argument,
                calendarSnapshotPath: config.calendarURL.path
            ), embeddings: NoEmbeddingProvider()).vaultOverview()
            if overview.objectValue?["source"]?.stringValue == "index",
               let count = overview.objectValue?["note_count"]?.intValue {
                print("index notes: \(count)")
            } else {
                print("index notes: unreadable")
            }
        } else {
            print("index notes: (no index)")
        }
        for line in config.describe() {
            print(line)
        }
        let unparseable = ForwardedFor.unparseableInAudit(at: config.auditLog)
        if config.trustForwardedFor || unparseable > 0 {
            print("x_forwarded_for: \(unparseable) request(s) had an unparseable X-Forwarded-For (audit log)")
        }
        do {
            let settings = try OAuthSettings(config: config)
            print(
                "oauth: configured (client \(settings.clientID.prefix(6))..., \(settings.redirectURIs.count) redirect URI(s))"
            )
        } catch {
            print("oauth: NOT configured — serve will refuse to start (\(error))")
        }
        return 0
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
