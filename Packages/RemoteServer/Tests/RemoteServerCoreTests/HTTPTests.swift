import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
@testable import RemoteServerCore
import Testing

struct HTTPTests {
    static let metadataURL = "https://nr-test.ts.net/.well-known/oauth-protected-resource/mcp"
    static let json: HTTPFields = [.contentType: "application/json", .accept: "application/json"]

    /// Builds the app over a ready fixture replica. `authenticator` defaults to the
    /// shipped deny-all; tests that need a session pass `AllowAllAuthenticator`.
    private func withApp(
        authenticator: any BearerAuthenticator = DenyAllAuthenticator(),
        extra: [String: String] = [:],
        _ body: @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let config = try fixture.config(extra: extra)
        let audit = AuditLog(url: fixture.auditURL)
        let watcher = ReplicaWatcher(config: config, audit: audit)
        await watcher.tick()
        let mcp = try await RemoteMCPServer(gateway: ToolGateway(replica: watcher, audit: audit))
        let app = RemoteApp.build(
            config: config,
            authenticator: authenticator,
            mcp: mcp,
            limiter: RateLimiter(),
            audit: audit
        )
        try await app.test(.router, body)
        await mcp.stop()
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> ByteBuffer {
        ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}")
    }

    private func bearer(_ token: String = "t") -> HTTPFields {
        var headers = Self.json
        headers[.authorization] = "Bearer \(token)"
        return headers
    }

    private func jsonBody(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
    }

    // MARK: 401 behaviour (default authenticator denies all)

    @Test func missingTokenGets401WithTheExactChallenge() async throws {
        try await withApp { client in
            try await client
                .execute(uri: "/mcp", method: .post, headers: Self.json, body: ByteBuffer(string: "{}")) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.headers[.wwwAuthenticate] == "Bearer resource_metadata=\"\(Self.metadataURL)\"")
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(String(buffer: response.body) == "{\"error\":\"unauthorized\"}")
                }
        }
    }

    @Test func garbageTokenGetsInvalidToken() async throws {
        try await withApp { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: bearer("garbage-token-value"),
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .unauthorized)
                let challenge = response.headers[.wwwAuthenticate] ?? ""
                #expect(challenge
                    .hasPrefix("Bearer resource_metadata=\"\(Self.metadataURL)\", error=\"invalid_token\""))
                #expect(!challenge.contains("garbage-token-value"))
                #expect(!String(buffer: response.body).contains("garbage-token-value"))
            }
        }
    }

    @Test func denyAllNeverAuthenticatesEvenAWellFormedBearer() async {
        let denied = await DenyAllAuthenticator().authenticate(authorizationHeader: "Bearer anything")
        #expect(denied == .denied(description: "The access token is invalid"))
        #expect(await DenyAllAuthenticator().authenticate(authorizationHeader: nil) == .missing)
        #expect(await DenyAllAuthenticator()
            .authenticate(authorizationHeader: "Basic abc") != .authenticated(AuthenticatedPrincipal()))
    }

    @Test func twentyFirstUnauthenticatedRequestIsRateLimited() async throws {
        try await withApp { client in
            for attempt in 1 ... 20 {
                try await client.execute(
                    uri: "/mcp",
                    method: .post,
                    headers: Self.json,
                    body: ByteBuffer(string: "{}")
                ) { response in
                    #expect(response.status == .unauthorized, "request \(attempt)")
                }
            }
            try await client
                .execute(uri: "/mcp", method: .post, headers: Self.json, body: ByteBuffer(string: "{}")) { response in
                    #expect(response.status == .tooManyRequests)
                    #expect(response.headers[.retryAfter] != nil)
                }
        }
    }

    // MARK: routing

    @Test func getAndDeleteOnMcpAre405() async throws {
        try await withApp { client in
            for method in [HTTPRequest.Method.get, .delete] {
                try await client.execute(uri: "/mcp", method: method) { response in
                    #expect(response.status == .methodNotAllowed)
                    #expect(response.headers[.allow] == "POST")
                }
            }
        }
    }

    @Test func protectedResourceMetadataIsServedAtBothPaths() async throws {
        try await withApp { client in
            for path in ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "max-age=3600")
                    let document = try jsonBody(response)
                    #expect(document["resource"] as? String == "https://nr-test.ts.net/mcp")
                    #expect(document["authorization_servers"] as? [String] == ["https://nr-test.ts.net"])
                    #expect(document["scopes_supported"] as? [String] == ["vault:read"])
                }
            }
        }
    }

    @Test func registerAndUnknownPathsAre404WithEmptyBodies() async throws {
        try await withApp { client in
            for path in ["/register", "/anything/else", "/authorize"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .notFound)
                    #expect(response.body.readableBytes == 0)
                    #expect(response.headers[.server] == nil)
                }
            }
            try await client.execute(
                uri: "/register",
                method: .post,
                headers: Self.json,
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/healthz", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "{\"ok\":true}")
            }
        }
    }

    @Test func oversizedBodiesAre413() async throws {
        try await withApp { client in
            let big = ByteBuffer(string: String(repeating: "a", count: 65 * 1024))
            try await client.execute(uri: "/mcp", method: .post, headers: Self.json, body: big) { response in
                #expect(response.status == .contentTooLarge)
            }
            let exact = ByteBuffer(string: String(repeating: " ", count: 64 * 1024))
            try await client.execute(uri: "/mcp", method: .post, headers: Self.json, body: exact) { response in
                #expect(response.status == .unauthorized) // under the limit: reaches auth
            }
        }
    }

    @Test func foreignHostIs421() async throws {
        try await withApp { client in
            var headers = Self.json
            headers[HTTPField.Name("Host")!] = "evil.example"
            try await client
                .execute(uri: "/mcp", method: .post, headers: headers, body: ByteBuffer(string: "{}")) { response in
                    #expect(response.status == .misdirectedRequest)
                }
            try await client
                .execute(uri: "/healthz", method: .get,
                         headers: [HTTPField.Name("Host")!: "evil.example"]) { response in
                    #expect(response.status == .misdirectedRequest)
                }
        }
    }

    // MARK: authenticated flow (test-only AllowAllAuthenticator)

    @Test func fullMCPRoundTrip() async throws {
        try await withApp(authenticator: AllowAllAuthenticator()) { client in
            let initialize = rpc(
                1,
                "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: initialize) { response in
                #expect(response.status == .ok)
                let reply = try jsonBody(response)
                #expect(reply["id"] as? Int == 1) // the caller's own id is restored
                let result = try #require(reply["result"] as? [String: Any])
                #expect((result["instructions"] as? String)?.contains("read-only replica") == true)
            }
            try await client.execute(
                uri: "/mcp", method: .post, headers: bearer(),
                body: ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
            ) { response in
                #expect(response.status == .accepted)
            }

            try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: rpc(
                2,
                "tools/list"
            )) { response in
                let result = try #require(try jsonBody(response)["result"] as? [String: Any])
                let tools = try #require(result["tools"] as? [[String: Any]])
                #expect(tools.count == 7)
                let search = try #require(tools.first { $0["name"] as? String == "search" })
                let properties = (search["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
                #expect(properties?["mode"] == nil)
                #expect(properties?["query"] != nil)
            }

            try await client.execute(
                uri: "/mcp", method: .post, headers: bearer(),
                body: rpc(3, "tools/call", "{\"name\":\"read_note\",\"arguments\":{\"path\":\"Inbox.md\"}}")
            ) { response in
                #expect(response.status == .ok)
                let result = try #require(try jsonBody(response)["result"] as? [String: Any])
                #expect(result["isError"] as? Bool != true)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                #expect(structured["path"] as? String == "Inbox.md")
                #expect((structured["content"] as? String)?.contains("accreditation") == true)
                #expect(structured["replica_generated_at"] != nil)
                let content = try #require(result["content"] as? [[String: Any]])
                #expect((content.first?["text"] as? String)?.contains("<untrusted_vault_data>") == true)
            }

            // Nothing beyond the seven tools is advertised.
            for method in ["resources/list", "prompts/list"] {
                try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: rpc(
                    4,
                    method
                )) { response in
                    let reply = try jsonBody(response)
                    #expect(reply["result"] == nil, "\(method)")
                    #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601, "\(method)")
                }
            }
        }
    }

    @Test func concurrentCallersWithTheSameRequestIDDoNotCollide() async throws {
        try await withApp(authenticator: AllowAllAuthenticator()) { client in
            let initialize = rpc(
                1,
                "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: initialize) { _ in }
            try await withThrowingTaskGroup(of: String.self) { group in
                for path in ["Inbox.md", "Daily/2026-08-20.md", "Work/Curriculum.md", "CLAUDE.md"] {
                    group.addTask {
                        try await client.execute(
                            uri: "/mcp", method: .post, headers: bearer(),
                            body: rpc(7, "tools/call", "{\"name\":\"read_note\",\"arguments\":{\"path\":\"\(path)\"}}")
                        ) { response in
                            let result = try #require(try jsonBody(response)["result"] as? [String: Any])
                            #expect(try jsonBody(response)["id"] as? Int == 7)
                            return ((result["structuredContent"] as? [String: Any])?["path"] as? String) ?? ""
                        }
                    }
                }
                var paths: [String] = []
                for try await path in group {
                    paths.append(path)
                }
                #expect(paths.sorted() == ["CLAUDE.md", "Daily/2026-08-20.md", "Inbox.md", "Work/Curriculum.md"])
            }
        }
    }

    @Test func sixtyFirstToolCallInAMinuteIs429() async throws {
        try await withApp(authenticator: AllowAllAuthenticator()) { client in
            for attempt in 1 ... 60 {
                try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: rpc(
                    attempt,
                    "ping"
                )) { response in
                    #expect(response.status != .tooManyRequests, "request \(attempt)")
                }
            }
            try await client.execute(uri: "/mcp", method: .post, headers: bearer(), body: rpc(61, "ping")) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers[.retryAfter] != nil)
            }
        }
    }

    @Test func htmlAcceptIs406() async throws {
        try await withApp(authenticator: AllowAllAuthenticator()) { client in
            var headers = bearer()
            headers[.accept] = "text/html"
            try await client.execute(uri: "/mcp", method: .post, headers: headers, body: rpc(
                1,
                "tools/list"
            )) { response in
                #expect(response.status == .notAcceptable)
            }
        }
    }

    @Test func clientSuppliedInternalHeadersAreIgnored() async throws {
        try await withApp(authenticator: AllowAllAuthenticator()) { client in
            var headers = bearer()
            headers[HTTPField.Name("X-NR-Client-Id")!] = "spoofed-admin"
            let initialize = rpc(
                1,
                "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            try await client.execute(uri: "/mcp", method: .post, headers: headers, body: initialize) { _ in }
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers,
                body: rpc(2, "tools/call", "{\"name\":\"calendar_list\",\"arguments\":{}}")
            ) { _ in }
        }
        // (The audit-side assertion lives in `auditNeverContainsSpoofedOrSecretValues`.)
    }

    @Test func auditNeverContainsSpoofedOrSecretValues() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let config = try fixture.config()
        let audit = AuditLog(url: fixture.auditURL)
        let watcher = ReplicaWatcher(config: config, audit: audit)
        await watcher.tick()
        let mcp = try await RemoteMCPServer(gateway: ToolGateway(replica: watcher, audit: audit))

        // Denied traffic with a secret-looking token, then an allowed call with a spoofed header.
        let denied = RemoteApp.build(
            config: config,
            authenticator: DenyAllAuthenticator(),
            mcp: mcp,
            limiter: RateLimiter(),
            audit: audit
        )
        try await denied.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: bearer("tok-SECRET-123"),
                body: ByteBuffer(string: "{}")
            ) { _ in }
        }
        let allowed = RemoteApp.build(
            config: config,
            authenticator: AllowAllAuthenticator(),
            mcp: mcp,
            limiter: RateLimiter(),
            audit: audit
        )
        try await allowed.test(.router) { client in
            var headers = bearer("tok-SECRET-456")
            headers[HTTPField.Name("X-NR-Client-Id")!] = "spoofed-admin"
            let initialize = rpc(
                1,
                "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            try await client.execute(uri: "/mcp", method: .post, headers: headers, body: initialize) { _ in }
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: headers,
                body: rpc(2, "tools/call", "{\"name\":\"calendar_list\",\"arguments\":{}}")
            ) { _ in }
        }
        await mcp.stop()
        let log = try String(contentsOf: fixture.auditURL, encoding: .utf8)
        #expect(log.contains("auth.denied"))
        #expect(log.contains("\"client_id\":\"test-client\""))
        #expect(!log.contains("spoofed-admin"))
        #expect(!log.contains("SECRET"))
        #expect(!log.lowercased().contains("bearer"))
    }
}
