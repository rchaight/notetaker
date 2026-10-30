import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
@testable import RemoteServerCore
import Testing

/// Critique follow-up: internet junk must not lock the owner out, must not cause
/// unbounded expensive work, and must not evade per-IP limits via X-Forwarded-For.
struct OAuthAvailabilityTests {
    private func forwarded(_ value: String) -> HTTPFields {
        [HTTPField.Name("X-Forwarded-For")!: value]
    }

    /// Global mode (no trusted client IP — the production assumption until stage 2).
    @Test func junkTrafficCannotBlockValidRequests() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 20) { harness, client in
            let tokens = try await harness.tokens(client)

            // 300 junk token requests: unknown refresh tokens, empty bodies, wrong client.
            var limited = 0
            for index in 0 ..< 300 {
                let response: TestResponse = switch index % 3 {
                case 0: try await harness.refresh(client, OAuthCrypto.token())
                case 1: try await harness.post(client, "/token", [])
                default: try await harness.refresh(client, OAuthCrypto.token(), clientID: "nr-junk-client-0123456789")
                }
                #expect(response.status != .ok)
                if response.status == .tooManyRequests {
                    limited += 1
                }
            }
            #expect(limited >= 290) // junk is tarpitted after the 10-failure budget...
            // ...but a request carrying a valid refresh token still goes through, twice.
            let rotated = try await harness.refresh(client, tokens.refresh)
            #expect(rotated.status == .ok)
            let next = try #require(try OAuthHarness.json(rotated)["refresh_token"] as? String)
            #expect(try await harness.refresh(client, next).status == .ok)

            // Junk on every other endpoint, then a complete valid login + exchange.
            for _ in 0 ..< 100 {
                _ = try await client.execute(uri: "/authorize?client_id=nope", method: .get)
                _ = try await client.execute(uri: "/auth/google/callback?state=nope&code=x", method: .get)
                _ = try await harness.consent(client, token: OAuthCrypto.token())
                _ = try await harness.post(client, "/revoke", [("token", OAuthCrypto.token())])
            }
            let fresh = try await harness.tokens(client)
            #expect(try await harness.mcpStatus(client, fresh.access).status == .ok)
            #expect(try await harness.post(client, "/revoke", [("token", fresh.refresh)]).status == .ok)
            #expect(try await harness.mcpStatus(client, fresh.access).status == .unauthorized)

            // Audit volume stays bounded: ≤ 10 failure lines per endpoint, and one
            // `auth.ratelimited` line per refusal streak.
            #expect(harness.events("token.rejected").count <= 10)
            #expect(harness.events("authorize.rejected").count <= 10)
            #expect(harness.events("callback.rejected").count <= 10)
            #expect(harness.events("consent.rejected").count <= 10)
            #expect(harness.events("revoke").filter { $0["reason"] as? String == "unknown" }.count <= 10)
            let streaks = harness.events("auth.ratelimited").compactMap { $0["reason"] as? String }
            #expect(streaks.filter { $0 == "token" }.count == 1)
            #expect(Set(streaks).isSubset(of: ["token", "authorize", "callback", "consent", "revoke"]))
        }
    }

    @Test func junkCannotCauseUnboundedGoogleWork() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 20) { harness, client in
            // Anyone can mint a pending request (public parameters) and present a junk
            // Google code; each pair would cost an outbound Google call.
            for _ in 0 ..< 60 {
                let authorize = try await harness.authorize(client, .init())
                guard authorize.status == .found, let location = authorize.headers[.location],
                      let gstate = OAuthHarness.query(location)["state"] else { continue }
                _ = try await client.execute(uri: "/auth/google/callback?state=\(gstate)&code=junk", method: .get)
            }
            #expect(harness.google.counters.token <= 20)
            #expect(harness.google.counters.authorize.isEmpty) // never followed to Google by us
            #expect(await harness.server.pending.pendingCount <= 20)
            #expect(harness.events("login.denied").count <= 20)
            // The interactive login is delayed at worst one window, then works.
            harness.clock.advance(61)
            let page = try await harness.login(client)
            #expect(page.status == .ok)
            #expect(OAuthHarness.consentToken(in: page) != nil)
        }
    }

    @Test func rotatingTheFirstForwardedHopDoesNotEvadePerIPLimits() async throws {
        try await OAuthHarness.run(env: ["NR_TRUST_FORWARDED_FOR": "1"], authPerMinute: 10) { harness, client in
            var limited = 0
            for index in 0 ..< 40 {
                let response = try await harness.post(
                    client, "/token", [("grant_type", "refresh_token")],
                    headers: forwarded("198.51.100.\(index), 203.0.113.7")
                )
                if response.status == .tooManyRequests {
                    limited += 1
                }
            }
            #expect(limited == 30)
            #expect(harness.events("auth.ratelimited").first?["ip"] as? String == "203.0.113.7")
        }
    }

    @Test func clientIPIsTheLastForwardedHop() {
        func ip(_ fields: [(String, String)], trusted: Bool = true) -> String? {
            var headers = HTTPFields()
            for (name, value) in fields {
                headers.append(HTTPField(name: HTTPField.Name(name)!, value: value))
            }
            let request = Request(
                head: HTTPRequest(
                    method: .get,
                    scheme: "http",
                    authority: "localhost",
                    path: "/",
                    headerFields: headers
                ),
                body: RequestBody(buffer: ByteBuffer())
            )
            return MCPEndpoint.clientIP(of: request, trustForwardedFor: trusted)
        }
        #expect(ip([("X-Forwarded-For", "1.1.1.1, 2.2.2.2")]) == "2.2.2.2")
        #expect(ip([("X-Forwarded-For", "1.1.1.1"), ("X-Forwarded-For", "3.3.3.3")]) == "3.3.3.3")
        #expect(ip([("X-Forwarded-For", "2001:db8::1")]) == "2001:db8::1")
        #expect(ip([("X-Forwarded-For", "1.1.1.1, evil")]) == nil)
        #expect(ip([("X-Forwarded-For", "1.1.1.1,")]) == nil)
        #expect(ip([("X-Forwarded-For", "2.2.2.2")], trusted: false) == nil)
        #expect(ip([]) == nil)
    }

    @Test func tarpitKeyspaceIsBounded() async {
        var settings = RateLimiter.Settings()
        settings.maxTrackedKeys = 100
        settings.failuresPerWindow = 1
        let limiter = RateLimiter(settings: settings, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        for index in 0 ..< 1000 {
            await limiter.recordAuthFailure(key: "10.0.\(index / 256).\(index % 256)")
        }
        let tracked = await limiter.trackedFailureKeys
        #expect(tracked.failures <= 100)
        #expect(tracked.blocked <= 100)
        // The most recent offender is still tarpitted.
        #expect(await limiter.isTarpitted(key: "10.0.3.231") != .allowed)
    }

    @Test func statusWarnsAboutIneffectiveIPSettings() throws {
        let base = ["NR_PUBLIC_URL": "https://node.tail.ts.net"]
        let allowlistOnly = try RemoteConfig(environment: base.merging(["NR_ANTHROPIC_IP_ALLOWLIST": "1"]) { $1 })
        #expect(allowlistOnly.describe()
            .contains { $0.hasPrefix("WARNING: NR_ANTHROPIC_IP_ALLOWLIST=1 has no effect") })
        let both = try RemoteConfig(environment: base.merging([
            "NR_ANTHROPIC_IP_ALLOWLIST": "1", "NR_TRUST_FORWARDED_FOR": "1", "NR_ALLOW_LOOPBACK": "1",
        ]) { $1 })
        let lines = both.describe()
        #expect(!lines.contains { $0.contains("NR_ANTHROPIC_IP_ALLOWLIST=1 has no effect") })
        #expect(lines.contains { $0.contains("LAST X-Forwarded-For hop") && $0.contains("stage 2") })
        #expect(lines.contains { $0.hasPrefix("WARNING: NR_ALLOW_LOOPBACK=1") }) // existing warning kept
    }

    @Test(.enabled(if: OAuthProbeScriptTests.which("bash") != nil, "bash is not installed"))
    func idleConnectionsAreClosed() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let config = try fixture.config()
        let watcher = ReplicaWatcher(config: config, audit: nil)
        await watcher.tick()
        let mcp = try await RemoteMCPServer(gateway: ToolGateway(replica: watcher, audit: nil))
        #expect(RemoteApp.idleTimeoutSeconds == 30)
        let app = RemoteApp.build(
            config: config, authenticator: DenyAllAuthenticator(), mcp: mcp, limiter: RateLimiter(), audit: nil,
            idleTimeoutSeconds: 1
        )
        try await app.test(.live) { client in
            let port = try #require(client.port)
            // Open a socket, send nothing (then a request head that never ends):
            // the server must close it, so `cat` sees EOF.
            for script in [
                "exec 3<>/dev/tcp/localhost/\(port) || exit 2; cat <&3 > /dev/null; echo closed",
                "exec 3<>/dev/tcp/localhost/\(port) || exit 2; printf 'GET /healthz HTTP/1.1\\r\\nHost: localhost\\r\\nX-Slow: ' >&3; cat <&3 > /dev/null; echo closed",
            ] {
                let process = Process()
                process.executableURL = try URL(fileURLWithPath: #require(OAuthProbeScriptTests.which("bash")))
                process.arguments = ["-c", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                let started = ContinuousClock.now
                while process.isRunning, ContinuousClock.now - started < .seconds(15) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if process.isRunning {
                    process.terminate()
                    Issue.record("an idle connection was still open after 15 s")
                }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(output.contains("closed"))
                #expect(ContinuousClock.now - started < .seconds(10))
            }
        }
        await mcp.stop()
    }
}
