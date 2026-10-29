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
        authenticator: any BearerAuthenticator = DenyAllAuthenticator(),
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

    static func serve(config: RemoteConfig, authenticator: any BearerAuthenticator, audit: AuditLog) async -> Int32 {
        do {
            let watcher = ReplicaWatcher(config: config, audit: audit)
            await watcher.tick()
            var limits = ToolGateway.Limits()
            limits.staleAfterHours = config.staleAfterHours
            let gateway = ToolGateway(replica: watcher, limits: limits, audit: audit)
            let mcp = try await RemoteMCPServer(gateway: gateway)
            let app = RemoteApp.build(
                config: config, authenticator: authenticator, mcp: mcp, limiter: RateLimiter(), audit: audit
            )
            await audit.record(AuditEvent(event: "server.start", reason: "bind=\(config.bindHost):\(config.bindPort)"))
            let polling = Task { await watcher.run() }
            defer { polling.cancel() }
            try await app.runService() // SIGTERM/SIGINT → graceful stop
            return 0
        } catch {
            printErr("notetaker-remote: \(error)")
            return 1
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
        return 0
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
