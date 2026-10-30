import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 tests 9 (rate limits), 10 (audit hygiene), 12 (store) and the
/// config / crypto helpers.
struct OAuthHardeningTests {
    // MARK: rate limits (test 9)

    private func forwarded(_ ip: String) -> HTTPFields {
        [HTTPField.Name("X-Forwarded-For")!: ip]
    }

    @Test func eleventhTokenRequestFromOneIPIs429() async throws {
        try await OAuthHarness.run(env: ["NR_TRUST_FORWARDED_FOR": "1"], authPerMinute: 10) { harness, client in
            for attempt in 1 ... 10 {
                let response = try await harness.post(
                    client, "/token", [("grant_type", "refresh_token")], headers: forwarded("203.0.113.7")
                )
                #expect(response.status != .tooManyRequests, "attempt \(attempt)")
            }
            for _ in 0 ..< 3 {
                let limited = try await harness.post(
                    client, "/token", [("grant_type", "refresh_token")], headers: forwarded("203.0.113.7")
                )
                #expect(limited.status == .tooManyRequests)
                #expect(limited.headers[.retryAfter] != nil)
            }
            // Another client IP is unaffected; another endpoint has its own bucket.
            #expect(try await harness.post(
                client, "/token", [("grant_type", "refresh_token")], headers: forwarded("198.51.100.9")
            ).status != .tooManyRequests)
            #expect(try await client.execute(
                uri: "/authorize", method: .get, headers: forwarded("203.0.113.7")
            ).status != .tooManyRequests)
            // A flood is one audit line, not one per request.
            let lines = harness.events("auth.ratelimited")
            #expect(lines.count == 1)
            #expect(lines.first?["ip"] as? String == "203.0.113.7")
            #expect(lines.first?["reason"] as? String == "token")
            // The bucket refills.
            harness.clock.advance(7)
            #expect(try await harness.post(
                client, "/token", [("grant_type", "refresh_token")], headers: forwarded("203.0.113.7")
            ).status != .tooManyRequests)
        }
    }

    @Test func withoutTrustedForwardingTheLimitIsGlobal() async throws {
        try await OAuthHarness.run(authPerMinute: 10) { harness, client in
            for index in 1 ... 10 {
                _ = try await harness.post(client, "/revoke", [("token", "x")], headers: forwarded("192.0.2.\(index)"))
            }
            let response = try await harness.post(client, "/revoke", [("token", "x")], headers: forwarded("192.0.2.99"))
            #expect(response.status == .tooManyRequests)
            #expect(harness.events("auth.ratelimited").first?["ip"] == nil)
        }
    }

    @Test func everyAuthEndpointIsLimited() async throws {
        try await OAuthHarness.run(authPerMinute: 2) { harness, client in
            for (method, path) in [
                (HTTPRequest.Method.get, "/authorize"), (.get, "/auth/google/callback"), (.post, "/consent"),
                (.post, "/token"), (.post, "/revoke"),
            ] {
                var last = HTTPResponse.Status.ok
                for _ in 0 ..< 3 {
                    last = try await client.execute(uri: path, method: method).status
                }
                #expect(last == .tooManyRequests, "\(path)")
            }
            // Metadata is not an auth step and is never limited.
            for _ in 0 ..< 5 {
                #expect(try await client.execute(uri: "/.well-known/oauth-authorization-server", method: .get)
                    .status == .ok)
            }
            _ = harness
        }
    }

    // MARK: audit hygiene (test 10)

    @Test func noSecretEverReachesTheAuditLog() async throws {
        try await OAuthHarness.run(env: ["NR_ALLOW_LOOPBACK": "1"]) { harness, client in
            var secrets: [String] = [FakeGoogle.clientSecret]

            // Happy path, rotation, reuse, revoke.
            var request = OAuthHarness.ClientRequest()
            let page = try await harness.login(client, request)
            let consentToken = try #require(OAuthHarness.consentToken(in: page))
            let allow = try await harness.consent(client, token: consentToken)
            let code = try #require(OAuthHarness.query(allow.headers[.location] ?? "")["code"])
            let first = try await OAuthHarness.json(harness.exchange(client, code: code, verifier: request.verifier))
            let access = try #require(first["access_token"] as? String)
            let refresh = try #require(first["refresh_token"] as? String)
            #expect(try await harness.mcpStatus(client, access).status == .ok)
            let second = try await OAuthHarness.json(harness.refresh(client, refresh))
            secrets += [request.verifier, request.state, consentToken, code, access, refresh]
            try secrets.append(#require(second["access_token"] as? String))
            try secrets.append(#require(second["refresh_token"] as? String))
            _ = try await harness.refresh(client, refresh) // reuse
            _ = try await harness.exchange(client, code: code, verifier: request.verifier) // code reuse
            _ = try await harness.post(client, "/revoke", [("token", access)])

            // Failures: foreign account, wrong verifier, garbage bearer, bad redirect.
            harness.google.configure { $0.email = "intruder.person@example.org" }
            request = OAuthHarness.ClientRequest()
            request.redirectURI = "http://127.0.0.1:8765/cb"
            _ = try await harness.login(client, request)
            secrets += [request.verifier, request.state, "intruder.person@example.org", "intruder.person"]
            harness.google.configure { $0 = FakeGoogle.Behaviour() }
            request = OAuthHarness.ClientRequest()
            let code2 = try await harness.code(client, request)
            _ = try await harness.exchange(client, code: code2, verifier: OAuthCrypto.token())
            secrets += [code2, request.verifier, request.state]
            _ = try await harness.mcpStatus(client, "Zm9vYmFyYmF6cXV4cXV1eGZvb2JhcmJhenF1eHF1dXg")
            var bad = OAuthHarness.ClientRequest()
            bad.redirectURI = "https://evil.example/steal"
            _ = try await harness.authorize(client, bad)
            secrets += ["evil.example/steal"]

            // Everything Google saw: our state, nonce, PKCE verifier, its codes.
            for record in harness.google.counters.authorize {
                secrets += [record.code, record.query["state"] ?? "", record.query["nonce"] ?? ""]
                secrets.append(record.query["code_challenge"] ?? "")
            }
            for form in harness.google.counters.tokenForms {
                secrets += [form["code_verifier"] ?? "", form["code"] ?? ""]
            }

            let log = harness.auditText
            #expect(!log.isEmpty)
            for secret in secrets where !secret.isEmpty {
                #expect(!log.contains(secret), "audit log contains a secret (\(secret.count) chars)")
            }
            #expect(!log.lowercased().contains("bearer"))
            for event in ["login.ok", "login.denied", "code.issued", "token.issued", "refresh.rotated", "refresh.reuse",
                          "code.reuse", "revoke", "authorize.rejected", "auth.denied"] {
                #expect(log.contains("\"event\":\"\(event)\""), "\(event)")
            }
            // Every line uses only the allowlisted keys.
            for line in harness.auditLines {
                #expect(Set(line.keys).isSubset(of: AuditLog.allowedKeys))
            }
        }
    }

    // MARK: store (test 12)

    /// `posixPermissions` is an `Int` on Linux and an `NSNumber` on Darwin.
    static func mode(_ attributes: [FileAttributeKey: Any]) -> Int? {
        let value = attributes[.posixPermissions]
        return (value as? Int) ?? (value as? NSNumber)?.intValue
    }

    @Test func storeFilesAreOwnerOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state/tokens.sqlite")
        let store = try TokenStore(url: url)
        try await store.insertCode(
            hash: "h", record: .init(clientID: "c", redirectURI: "r", codeChallenge: "x", resource: "res", sub: "s"),
            expiresAt: Date()
        )
        for path in [url.path, url.path + "-wal"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect(Self.mode(attributes) == 0o600, "\(path)")
        }
        let parent = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect(Self.mode(parent) == 0o700)
        // Re-opening a file someone loosened tightens it again.
        chmod(url.path, 0o644)
        _ = try TokenStore(url: url)
        let reopened = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(Self.mode(reopened) == 0o600)
    }

    @Test func housekeepingRemovesRowsExpiredMoreThanADayAgo() async throws {
        try await OAuthHarness.run { harness, client in
            let old = try await harness.tokens(client)
            harness.clock.advance(31 * 86400 + 1) // family absolute + 1 day passed
            let fresh = try await harness.tokens(client)
            let removed = try await harness.store.housekeep(now: harness.clock.now)
            #expect(removed >= 3) // the old code, both old tokens, the old family
            let counts = try await harness.store.withDatabase { db in
                try [
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM family") ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token") ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM auth_code") ?? -1,
                ]
            }
            #expect(counts == [1, 2, 1])
            #expect(try await harness.mcpStatus(client, fresh.access).status == .ok)
            #expect(try await harness.mcpStatus(client, old.access).status == .unauthorized)
        }
    }

    @Test func killPlanDeletesTheTokenStoreAndItsSidecars() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let actions = RecordingActions(euid: 0)
        _ = try await KillCommand(config: fixture.config(), actions: actions).run(report: { _ in })
        for file in ["rm tokens.sqlite", "rm tokens.sqlite-wal", "rm tokens.sqlite-shm"] {
            #expect(actions.steps.contains(file))
        }
        // Cut exposure first, wipe tokens before anything else.
        #expect(try #require(actions.steps.firstIndex(of: "rm tokens.sqlite")) > actions.steps
            .firstIndex(of: "systemctl stop notetaker-remote")!)
    }

    // MARK: config

    private func config(_ extra: [String: String]) throws -> RemoteConfig {
        try RemoteConfig(environment: [
            "NR_PUBLIC_URL": "https://node.tail.ts.net",
            "NR_ALLOWED_EMAIL": "rchaight@gmail.com",
            "NR_OAUTH_CLIENT_ID": "nr-0123456789abcdefghijklmnopqrstuv",
            "NR_GOOGLE_CLIENT_ID": "g.apps.googleusercontent.com",
            "NR_GOOGLE_CLIENT_SECRET": "GOCSPX-very-secret",
        ].merging(extra) { _, new in new })
    }

    @Test func settingsDefaultsAndRequiredKeys() throws {
        let settings = try OAuthSettings(config: config([:]))
        #expect(settings.redirectURIs == ["https://claude.ai/api/mcp/auth_callback"])
        #expect(settings.allowLoopback == false)
        #expect(settings.google.issuer == "https://accounts.google.com")
        #expect(settings.google.redirectURI == "https://node.tail.ts.net/auth/google/callback")
        #expect(settings.timings.accessTTL == 900)
        #expect(settings.timings.refreshIdle == 14 * 86400)
        #expect(settings.timings.refreshAbsolute == 30 * 86400)
        #expect(settings.timings.codeTTL == 60)
        #expect(settings.clientSecretDigest == nil)
        for key in ["NR_ALLOWED_EMAIL", "NR_OAUTH_CLIENT_ID", "NR_GOOGLE_CLIENT_ID", "NR_GOOGLE_CLIENT_SECRET"] {
            #expect(throws: RemoteConfig.ConfigError.missing(key)) { try OAuthSettings(config: config([key: ""])) }
        }
    }

    @Test func settingsRejectUnsafeValues() throws {
        for (key, value) in [
            ("NR_OAUTH_CLIENT_ID", "short"), ("NR_OAUTH_CLIENT_ID", "has space in the client id!!"),
            ("NR_ALLOWED_EMAIL", "rchaight@gmail.com,evil@example.com"), ("NR_ALLOWED_EMAIL", "rchaight"),
            ("NR_ALLOWED_EMAIL", "\u{212A}ate@example.com"), ("NR_ALLOWED_EMAIL", "a@b@c"),
            ("NR_OAUTH_REDIRECT_URIS", "http://claude.ai/cb"), ("NR_OAUTH_REDIRECT_URIS", "https://claude.ai/cb#x"),
            ("NR_OAUTH_REDIRECT_URIS", "https://claude.ai/cb?x=1"), ("NR_GOOGLE_ISSUER", "http://accounts.google.com"),
            ("NR_GOOGLE_ISSUER", "https://user:pw@accounts.google.com"), ("NR_OAUTH_CLIENT_SECRET_SHA256", "abc"),
        ] {
            #expect(throws: RemoteConfig.ConfigError.self, "\(key)=\(value)") {
                try OAuthSettings(config: config([key: value]))
            }
        }
        #expect(throws: RemoteConfig.ConfigError.self) { try config(["NR_ACCESS_TTL_SEC": "0"]) }
        #expect(throws: RemoteConfig.ConfigError.self) { try config(["NR_CODE_TTL_SEC": "soon"]) }
        let mixed = try OAuthSettings(config: config(["NR_ALLOWED_EMAIL": "RChaight@Gmail.com"]))
        #expect(mixed.allowedEmail == "rchaight@gmail.com")
    }

    @Test func theGoogleSecretCannotBePrintedByAccident() throws {
        let config = try config([:])
        let rendered = [
            "\(config)", String(describing: config), String(reflecting: config), "\(config.oauth)",
            String(describing: config.oauth.googleClientSecret as Any), config.describe().joined(separator: "\n"),
        ]
        var dumped = ""
        dump(config, to: &dumped)
        for text in rendered + [dumped] {
            #expect(!text.contains("GOCSPX-very-secret"))
        }
        #expect(config.describe().contains { $0.contains("google_client_secret: set (18 chars, masked)") })
        let settings = try OAuthSettings(config: config)
        var dumpedSettings = ""
        dump(settings, to: &dumpedSettings)
        #expect(!dumpedSettings.contains("GOCSPX-very-secret"))
        #expect(!"\(settings)".contains("GOCSPX-very-secret"))
    }

    // MARK: crypto helpers

    @Test func constantTimeEqualityAndPKCEVectors() {
        #expect(OAuthCrypto.constantTimeEquals("abc", "abc"))
        #expect(!OAuthCrypto.constantTimeEquals("abc", "abd"))
        #expect(!OAuthCrypto.constantTimeEquals("abc", "abcd"))
        #expect(!OAuthCrypto.constantTimeEquals("", "a"))
        #expect(OAuthCrypto.constantTimeEquals("", ""))
        #expect(!OAuthCrypto.constantTimeEquals([1, 2], [1, 2, 3]))
        // RFC 7636 Appendix B.
        #expect(OAuthCrypto.pkceChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let tokens = Set((0 ..< 200).map { _ in OAuthCrypto.token() })
        #expect(tokens.count == 200)
        #expect(tokens.allSatisfy { $0.count == 43 && OAuthText.isOurTokenShape($0) })
        #expect(Base64URL.decode("a+b") == nil)
        #expect(Base64URL.decode("YQ==") == nil)
        #expect(Base64URL.decode("YQ") == Data("a".utf8))
    }

    @Test func jwksParsingDropsAmbiguousWeakAndForeignKeys() throws {
        func document(_ keys: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["keys": keys])
        }
        let k1 = TestKeys.jwk(TestKeys.primary, kid: "k1")
        var encryption = TestKeys.jwk(TestKeys.secondary, kid: "enc")
        encryption["use"] = "enc"
        var otherAlg = TestKeys.jwk(TestKeys.secondary, kid: "ps")
        otherAlg["alg"] = "PS256"
        var weak = TestKeys.jwk(TestKeys.secondary, kid: "weak")
        weak["n"] = Base64URL.encode([UInt8](repeating: 0xC3, count: 128)) // 1024-bit modulus
        let ec: [String: Any] = ["kty": "EC", "kid": "ec", "crv": "P-256", "x": "AA", "y": "AA"]
        let set = try #require(JWKSet.parse(document([
            k1, encryption, otherAlg, weak, ec,
            TestKeys.jwk(TestKeys.primary, kid: "dup"), TestKeys.jwk(TestKeys.secondary, kid: "dup"),
        ])))
        #expect(Set(set.keys.keys) == ["k1"])
        #expect(JWKSet.parse(Data("not json".utf8)) == nil)
        #expect(JWKSCache.maxAge(from: "public, max-age=19000, must-revalidate") == 19000)
        #expect(JWKSCache.maxAge(from: "max-age=5") == 300)
        #expect(JWKSCache.maxAge(from: "max-age=9999999") == 86400)
        #expect(JWKSCache.maxAge(from: nil) == 300)
    }

    @Test func formParsingFollowsRFC6749() throws {
        let form = try #require(FormData.parse("a=1&b=&c=x+y&d=%2F&a2=%E2%9C%93"))
        #expect(form.value("a") == .one("1"))
        #expect(form.value("b") == .absent) // empty == omitted
        #expect(form.value("c") == .one("x y"))
        #expect(form.value("d") == .one("/"))
        #expect(form.value("a2") == .one("✓"))
        #expect(try #require(FormData.parse("a=1&a=2")).value("a") == .duplicate)
        #expect(FormData.parse("a=%zz") == nil)
        #expect(FormData.parse("=1") == nil)
        #expect(FormData.parse((0 ..< 65).map { "k\($0)=v" }.joined(separator: "&")) == nil)
    }
}
