import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
@testable import RemoteServerCore
import Testing

/// Shared scaffolding for the HTTP-level tests (`HTTPTests`, `ModernPathTests`).
enum HTTPHarness {
    static let metadataURL = "https://nr-test.ts.net/.well-known/oauth-protected-resource/mcp"
    static let json: HTTPFields = [.contentType: "application/json", .accept: "application/json"]

    /// A decoded reply, for tests that need the status and headers as well as the body.
    struct Reply {
        let status: Int
        let headers: HTTPFields
        let body: Data

        var object: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        }

        var error: [String: Any]? {
            object["error"] as? [String: Any]
        }

        var result: [String: Any]? {
            object["result"] as? [String: Any]
        }

        var text: String {
            String(decoding: body, as: UTF8.self)
        }
    }

    /// Builds the app over a ready fixture replica. `authenticator` defaults to the
    /// shipped deny-all; tests that need a session pass `AllowAllAuthenticator`.
    static func withApp(
        authenticator: any BearerAuthenticator = DenyAllAuthenticator(),
        extra: [String: String] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        _ body: @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        try await withFixtureApp(authenticator: authenticator, extra: extra, now: now) { client, _ in
            try await body(client)
        }
    }

    /// Same, also handing the test the fixture (audit file, replica) and optionally
    /// pushing a DISABLED replica.
    static func withFixtureApp(
        authenticator: any BearerAuthenticator = DenyAllAuthenticator(),
        extra: [String: String] = [:],
        disabled: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        _ body: @Sendable (any TestClientProtocol, ReplicaFixture) async throws -> Void
    ) async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push(disabled: disabled)
        let config = try fixture.config(extra: extra)
        let audit = AuditLog(url: fixture.auditURL)
        let watcher = ReplicaWatcher(config: config, audit: audit)
        await watcher.tick()
        let mcp = try await RemoteMCPServer(gateway: ToolGateway(replica: watcher, audit: audit))
        let app = RemoteApp.build(
            config: config,
            authenticator: authenticator,
            mcp: mcp,
            limiter: RateLimiter(now: now),
            audit: audit
        )
        try await app.test(.router) { client in
            try await body(client, fixture)
        }
        await mcp.stop()
    }

    static func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> ByteBuffer {
        ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}")
    }

    static func bearer(_ token: String = "t") -> HTTPFields {
        var headers = json
        headers[.authorization] = "Bearer \(token)"
        return headers
    }

    static func jsonBody(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
    }

    // MARK: MCP 2026-07-28 helpers

    static let defaultMeta = """
    {"io.modelcontextprotocol/protocolVersion":"2026-07-28",\
    "io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"},\
    "io.modelcontextprotocol/clientCapabilities":{}}
    """

    /// A 2026 request body. `id` is a String or an Int (or any JSON-encodable value);
    /// `params` is a JSON object string. The standard `_meta` is injected unless `meta`
    /// replaces the whole object (pass `""` to omit the key).
    static func modern(
        _ id: Any,
        _ method: String,
        params: String = "{}",
        version: String = "2026-07-28",
        meta: String? = nil
    ) -> ByteBuffer {
        var paramsObject = (try? JSONSerialization.jsonObject(with: Data(params.utf8))) as? [String: Any] ?? [:]
        let metaText = meta ?? defaultMeta.replacingOccurrences(of: "\"2026-07-28\"", with: "\"\(version)\"")
        if !metaText.isEmpty {
            paramsObject["_meta"] = try? JSONSerialization.jsonObject(
                with: Data(metaText.utf8),
                options: [.fragmentsAllowed]
            )
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": paramsObject]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return ByteBuffer(bytes: data)
    }

    /// Bearer + JSON + the 2026 headers. `version: nil` omits `MCP-Protocol-Version`.
    static func modernHeaders(
        method: String,
        name: String? = nil,
        version: String? = "2026-07-28",
        bearerToken: String = "t"
    ) -> HTTPFields {
        var headers = bearer(bearerToken)
        headers[.accept] = "application/json, text/event-stream"
        if let version {
            headers[HTTPField.Name("MCP-Protocol-Version")!] = version
        }
        headers[HTTPField.Name("Mcp-Method")!] = method
        if let name {
            headers[HTTPField.Name("Mcp-Name")!] = name
        }
        return headers
    }

    static func post(
        _ client: any TestClientProtocol, headers: HTTPFields, body: ByteBuffer
    ) async throws -> Reply {
        try await client.execute(uri: "/mcp", method: .post, headers: headers, body: body) { response in
            Reply(status: Int(response.status.code), headers: response.headers, body: Data(buffer: response.body))
        }
    }
}
