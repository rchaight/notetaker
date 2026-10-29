import Foundation
@testable import RemoteServerCore
import Testing

struct ConfigTests {
    private func load(_ extra: [String: String]) throws -> RemoteConfig {
        try RemoteConfig(environment: ["NR_PUBLIC_URL": "https://node.tail.ts.net"].merging(extra) { _, new in new })
    }

    @Test func missingPublicURLIsAnError() {
        #expect(throws: RemoteConfig.ConfigError.missing("NR_PUBLIC_URL")) {
            try RemoteConfig(environment: [:])
        }
    }

    @Test func httpPublicURLIsRejected() {
        #expect(throws: RemoteConfig.ConfigError.self) {
            try RemoteConfig(environment: ["NR_PUBLIC_URL": "http://node.tail.ts.net"])
        }
        #expect(throws: RemoteConfig.ConfigError.self) {
            try RemoteConfig(environment: ["NR_PUBLIC_URL": "https://node.tail.ts.net/mcp"])
        }
    }

    @Test func trailingSlashIsStripped() throws {
        let config = try load(["NR_PUBLIC_URL": "https://node.tail.ts.net/"])
        #expect(config.publicURL == "https://node.tail.ts.net")
        #expect(config.resourceURL == "https://node.tail.ts.net/mcp")
        #expect(config.metadataURL == "https://node.tail.ts.net/.well-known/oauth-protected-resource/mcp")
    }

    @Test func nonLoopbackBindIsRejectedUnlessExplicitlyAllowed() throws {
        #expect(throws: RemoteConfig.ConfigError.self) { try load(["NR_BIND": "0.0.0.0:8787"]) }
        #expect(throws: RemoteConfig.ConfigError.self) { try load(["NR_BIND": "192.168.5.20:8787"]) }
        #expect(throws: RemoteConfig.ConfigError.self) { try load(["NR_BIND": "nonsense"]) }
        let allowed = try load(["NR_BIND": "0.0.0.0:8787", "NR_ALLOW_NONLOOPBACK_BIND": "1"])
        #expect(allowed.bindHost == "0.0.0.0")
        #expect(try load(["NR_BIND": "[::1]:9000"]).bindPort == 9000)
    }

    @Test func defaults() throws {
        let config = try load([:])
        #expect(config.bindHost == "127.0.0.1")
        #expect(config.bindPort == 8787)
        #expect(config.replicaDir.path == "/srv/replica/inbox")
        #expect(config.stateDir.path == "/var/lib/notetaker-remote")
        #expect(config.auditLog.path == "/var/log/notetaker-remote/audit.jsonl")
        #expect(config.allowedHosts == ["node.tail.ts.net", "127.0.0.1:*", "localhost:*"])
        #expect(config.trustForwardedFor == false)
        #expect(config.anthropicIPAllowlist == false)
        #expect(config.staleAfterHours == 24)
        #expect(config.oauth.allowLoopback == false)
    }

    @Test func statusMasksSecretsAndWarnsAboutLoopback() throws {
        let config = try load([
            "NR_GOOGLE_CLIENT_SECRET": "super-secret-value", "NR_ALLOW_LOOPBACK": "1",
            "NR_ALLOWED_EMAIL": "me@example.com",
        ])
        let text = config.describe().joined(separator: "\n")
        #expect(!text.contains("super-secret-value"))
        #expect(text.contains("masked"))
        #expect(text.contains("WARNING"))
        #expect(text.contains("me@example.com"))
    }

    @Test func hostPatternsMatch() {
        let allowed = ["node.tail.ts.net", "127.0.0.1:*", "localhost:*"]
        #expect(HostAllowlistMiddleware.matches("node.tail.ts.net", allowed: allowed))
        #expect(HostAllowlistMiddleware.matches("NODE.tail.ts.net", allowed: allowed))
        #expect(HostAllowlistMiddleware.matches("127.0.0.1:8787", allowed: allowed))
        #expect(HostAllowlistMiddleware.matches("localhost", allowed: allowed))
        #expect(!HostAllowlistMiddleware.matches("evil.example", allowed: allowed))
        #expect(!HostAllowlistMiddleware.matches("127.0.0.1.evil.example", allowed: allowed))
        #expect(!HostAllowlistMiddleware.matches("localhost:abc", allowed: allowed))
    }
}
