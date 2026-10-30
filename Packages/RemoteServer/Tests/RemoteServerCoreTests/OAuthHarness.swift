import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// The server under test (router mode) wired to a live fake Google, a fixture
/// replica, a fresh token store and a shared settable clock.
struct OAuthHarness: Sendable {
    static let clientID = "nr-test-client-0123456789abcdef"
    static let publicURL = "https://nr-test.ts.net"
    static let resource = "https://nr-test.ts.net/mcp"
    static let claudeRedirect = "https://claude.ai/api/mcp/auth_callback"

    let fixture: ReplicaFixture
    let google: FakeGoogle
    let clock: TestClock
    let config: RemoteConfig
    let settings: OAuthSettings
    let store: TokenStore
    let server: OAuthServer
    let mcp: RemoteMCPServer
    let limiter: RateLimiter
    let audit: AuditLog

    var auditText: String {
        (try? String(contentsOf: fixture.auditURL, encoding: .utf8)) ?? ""
    }

    var auditLines: [[String: Any]] {
        auditText.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func events(_ name: String) -> [[String: Any]] {
        auditLines.filter { $0["event"] as? String == name }
    }

    /// Builds everything, runs `body` with a router-mode client, tears down.
    static func run(
        env extra: [String: String] = [:],
        authPerMinute: Int = 1000,
        configure: @Sendable (FakeGoogle) -> Void = { _ in },
        _ body: @Sendable (OAuthHarness, any TestClientProtocol) async throws -> Void
    ) async throws {
        let clock = TestClock()
        let google = FakeGoogle(clock: clock)
        configure(google)
        try await google.run { google in
            let harness = try await OAuthHarness.make(
                google: google,
                clock: clock,
                env: extra,
                authPerMinute: authPerMinute
            )
            defer { harness.fixture.cleanUp() }
            try await harness.app().test(.router) { client in
                try await body(harness, client)
            }
            await harness.mcp.stop()
        }
    }

    static func make(
        google: FakeGoogle, clock: TestClock, env extra: [String: String], authPerMinute: Int,
        fixture existing: ReplicaFixture? = nil
    ) async throws -> OAuthHarness {
        let fixture = try existing ?? ReplicaFixture()
        if existing == nil {
            try fixture.push()
        }
        var env = [
            "NR_ALLOWED_EMAIL": "rchaight@gmail.com",
            "NR_OAUTH_CLIENT_ID": clientID,
            "NR_GOOGLE_CLIENT_ID": FakeGoogle.clientID,
            "NR_GOOGLE_CLIENT_SECRET": FakeGoogle.clientSecret,
            "NR_GOOGLE_ISSUER": google.issuer,
        ]
        env.merge(extra) { _, new in new }
        let config = try fixture.config(extra: env)
        let settings = try OAuthSettings(config: config)
        let audit = AuditLog(url: fixture.auditURL, now: clock.clock)
        var limits = RateLimiter.Settings()
        limits.authPerMinute = authPerMinute
        let limiter = RateLimiter(settings: limits, now: clock.clock)
        let store = try TokenStore(url: config.tokensURL)
        let server = OAuthServer(
            config: config, settings: settings, store: store, limiter: limiter, audit: audit,
            httpClient: URLSessionOIDCClient(), now: clock.clock
        )
        let watcher = ReplicaWatcher(config: config, audit: audit)
        await watcher.tick()
        let mcp = try await RemoteMCPServer(gateway: ToolGateway(replica: watcher, audit: audit))
        return OAuthHarness(
            fixture: fixture, google: google, clock: clock, config: config, settings: settings, store: store,
            server: server, mcp: mcp, limiter: limiter, audit: audit
        )
    }

    func app() -> some ApplicationProtocol {
        let server = server
        return RemoteApp.build(
            config: config, authenticator: server.authenticator, mcp: mcp, limiter: limiter,
            audit: audit,
            extraRoutes: { router in server.register(on: router) }
        )
    }

    // MARK: - Flow steps

    struct ClientRequest: Sendable {
        var clientID = OAuthHarness.clientID
        var redirectURI = OAuthHarness.claudeRedirect
        var verifier = OAuthCrypto.token()
        var state = "client-state-" + OAuthCrypto.token(bytes: 8)
        var resource: String? = OAuthHarness.resource
        var method: String? = "S256"
        var challenge: String?
        var scope: String? = "vault:read"
        var extra: [(String, String)] = []

        var query: String {
            var pairs: [(String, String)] = [
                ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"), ("state", state),
            ]
            pairs.append(("code_challenge", challenge ?? OAuthCrypto.pkceChallenge(for: verifier)))
            if let method {
                pairs.append(("code_challenge_method", method))
            }
            if let resource {
                pairs.append(("resource", resource))
            }
            if let scope {
                pairs.append(("scope", scope))
            }
            return OAuthText.formEncode(pairs + extra)
        }
    }

    func authorize(_ client: any TestClientProtocol, _ request: ClientRequest) async throws -> TestResponse {
        try await client.execute(uri: "/authorize?" + request.query, method: .get)
    }

    /// GET the fake's authorize URL (no redirect following) → our callback query.
    func googleApprove(_ location: String) async throws -> String {
        let result = try await URLSessionOIDCClient().get(#require(URL(string: location)))
        #expect(result.status == 302)
        let callback = try #require(result.headers["location"])
        #expect(callback.hasPrefix(Self.publicURL + "/auth/google/callback?"))
        return String(callback.dropFirst(Self.publicURL.count))
    }

    /// authorize → Google → callback. Returns the callback response (consent page on success).
    func login(_ client: any TestClientProtocol,
               _ request: ClientRequest = ClientRequest()) async throws -> TestResponse {
        let authorize = try await authorize(client, request)
        #expect(authorize.status == .found)
        let location = try #require(authorize.headers[.location])
        let callback = try await googleApprove(location)
        return try await client.execute(uri: callback, method: .get)
    }

    static func consentToken(in page: TestResponse) -> String? {
        let html = String(buffer: page.body)
        guard let range = html.range(of: "name=\"consent_token\" value=\"") else { return nil }
        return String(html[range.upperBound...].prefix { $0 != "\"" })
    }

    func consent(
        _ client: any TestClientProtocol, token: String, action: String = "allow", headers extra: HTTPFields = [:]
    ) async throws -> TestResponse {
        var headers: HTTPFields = [.contentType: "application/x-www-form-urlencoded"]
        headers.append(contentsOf: extra)
        return try await client.execute(
            uri: "/consent", method: .post, headers: headers,
            body: ByteBuffer(string: OAuthText.formEncode([("consent_token", token), ("action", action)]))
        )
    }

    /// Full browser leg: returns the `code` from the final redirect.
    func code(_ client: any TestClientProtocol, _ request: ClientRequest = ClientRequest()) async throws -> String {
        let page = try await login(client, request)
        #expect(page.status == .ok)
        let token = try #require(Self.consentToken(in: page))
        let response = try await consent(client, token: token)
        #expect(response.status == .found)
        let location = try #require(response.headers[.location])
        return try #require(Self.query(location)["code"])
    }

    func post(
        _ client: any TestClientProtocol, _ path: String, _ pairs: [(String, String)], headers extra: HTTPFields = [:]
    ) async throws -> TestResponse {
        var headers: HTTPFields = [.contentType: "application/x-www-form-urlencoded"]
        headers.append(contentsOf: extra)
        return try await client.execute(
            uri: path, method: .post, headers: headers, body: ByteBuffer(string: OAuthText.formEncode(pairs))
        )
    }

    func exchange(
        _ client: any TestClientProtocol, code: String, verifier: String,
        redirectURI: String = OAuthHarness.claudeRedirect, clientID: String = OAuthHarness.clientID,
        extra: [(String, String)] = [], headers: HTTPFields = [:]
    ) async throws -> TestResponse {
        try await post(client, "/token", [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("code_verifier", verifier), ("client_id", clientID),
        ] + extra, headers: headers)
    }

    func refresh(
        _ client: any TestClientProtocol, _ token: String, clientID: String = OAuthHarness.clientID,
        extra: [(String, String)] = []
    ) async throws -> TestResponse {
        try await post(client, "/token", [
            ("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID),
        ] + extra)
    }

    struct Tokens: Sendable {
        var access: String
        var refresh: String
    }

    /// The whole happy path → a token pair.
    func tokens(_ client: any TestClientProtocol) async throws -> Tokens {
        var request = ClientRequest()
        request.verifier = OAuthCrypto.token()
        let code = try await code(client, request)
        let response = try await exchange(client, code: code, verifier: request.verifier)
        #expect(response.status == .ok)
        let json = try Self.json(response)
        let access = try #require(json["access_token"] as? String)
        let refresh = try #require(json["refresh_token"] as? String)
        return Tokens(access: access, refresh: refresh)
    }

    func mcpStatus(_ client: any TestClientProtocol, _ access: String?) async throws -> TestResponse {
        var headers: HTTPFields = [.contentType: "application/json", .accept: "application/json"]
        if let access {
            headers[.authorization] = "Bearer \(access)"
        }
        return try await client.execute(
            uri: "/mcp", method: .post, headers: headers,
            body: ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}")
        )
    }

    static func json(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
    }

    static func query(_ location: String) -> [String: String] {
        guard let mark = location.firstIndex(of: "?") else { return [:] }
        return FakeGoogle.parse(String(location[location.index(after: mark)...]))
    }
}
