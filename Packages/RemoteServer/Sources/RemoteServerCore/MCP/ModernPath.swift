import Foundation
import MCP
import MCPKit

// The MCP 2026-07-28 request shape, answered natively on `/mcp`.
//
// `RemoteMCPServer` puts a classifier in front of the swift-sdk 0.12.1 transport. A POST
// whose body carries 2026-era per-request `_meta`, or whose `MCP-Protocol-Version` header
// names a 2026 version, or whose method exists only in the 2026 era, is answered here:
// `server/discover`, `tools/list` and `tools/call` (through the one `ToolGateway`) plus the
// exact 2026 error shapes (-32022, -32020, -32602, 404 -32601). Everything else, including
// `initialize` with any header, goes to the SDK exactly as before. There is no state, no
// session and no streaming on this path.
//
// Legacy requests never enter this file.
//
// Contract: specs/mcp-2026/01-modern-path.md (research: specs/mcp-2026/00-research.md).

/// A complete HTTP reply with an explicit status. `MCP.HTTPResponse` cannot carry a JSON
/// body on a non-200 status (`.data` is always 200 and `.error` has no `data` member), so
/// the modern path and the `respond` bridge use this small value type instead.
struct ModernReply: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data?

    init(status: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Wraps an SDK response. Stateless mode never streams; a stream maps to a bare 500
    /// (as `MCPEndpoint.map` has always done) rather than hanging.
    init(_ response: MCP.HTTPResponse) {
        if case .stream = response {
            self.init(status: 500)
        } else {
            self.init(status: response.statusCode, headers: response.headers, body: response.bodyData)
        }
    }
}

struct ModernPath: Sendable {
    let gateway: ToolGateway

    /// Never merged with the SDK's `Version.supported`; those stay the legacy set used by
    /// `initialize`.
    static let supportedVersions = ["2026-07-28"]
    static let modernFloor = "2026-07-28"

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    static let ttlMs = 3_600_000
    static let cacheScope = "private"

    private static let sentinelPrefix = "=?base64?"
    private static let sentinelSuffix = "?="

    // MARK: classification

    /// Rule 2 of the spec's classification (rule 1, `initialize` is always legacy, lives in
    /// `RemoteMCPServer`). `method` is the body's `method`.
    static func isModern(method: String, message: [String: Any], request: HTTPRequest) -> Bool {
        if method == "server/discover" || method == "subscriptions/listen" {
            return true
        }
        // The key did not exist before 2026-07-28, so no legacy client sends it.
        if let params = message["params"] as? [String: Any],
           let meta = params["_meta"] as? [String: Any],
           meta[versionKey] != nil {
            return true
        }
        // ISO dates compare correctly as strings.
        if let header = request.header(HTTPHeaderName.protocolVersion) {
            return trim(header) >= modernFloor
        }
        return false
    }

    // MARK: handling

    func handle(_ request: HTTPRequest, message: [String: Any]) async -> ModernReply {
        let method = message["method"] as? String ?? ""

        // A notification (no `id` key) is accepted and discarded: nothing is validated,
        // yielded to the SDK or audited.
        guard let rawID = message["id"] else {
            return ModernReply(status: 202)
        }
        guard rawID is String || rawID is NSNumber else {
            return Self.failure(id: nil, status: 400, code: -32600,
                                message: "Invalid Request: id must be a string or number")
        }
        let id = rawID

        // 1. Accept / Content-Type: the SDK's own validators, so the eras cannot drift.
        let context = HTTPValidationContext(httpMethod: "POST")
        if let rejection = AcceptHeaderValidator(mode: .jsonOnly).validate(request, context: context)
            ?? ContentTypeValidator().validate(request, context: context) {
            return ModernReply(rejection)
        }

        // 2. Required per-request `_meta`.
        let params = message["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        guard let version = meta?[Self.versionKey] as? String else {
            return Self.failure(id: id, status: 400, code: -32602,
                                message: "Invalid params: _meta.\(Self.versionKey) is required")
        }
        guard meta?[Self.capabilitiesKey] is [String: Any] else {
            return Self.failure(id: id, status: 400, code: -32602,
                                message: "Invalid params: _meta.\(Self.capabilitiesKey) is required")
        }

        // 3-4. Header against body version. (Two field lines arrive joined with ", " via
        // `MCPEndpoint.flatten` and therefore mismatch; acceptable.)
        guard let rawHeaderVersion = request.header(HTTPHeaderName.protocolVersion) else {
            return Self.failure(id: id, status: 400, code: -32020,
                                message: "Header mismatch: MCP-Protocol-Version header is missing")
        }
        let headerVersion = Self.trim(rawHeaderVersion)
        guard headerVersion == version else {
            return Self.failure(
                id: id, status: 400, code: -32020,
                message: "Header mismatch: MCP-Protocol-Version header value '\(headerVersion)' does not match body value '\(version)'"
            )
        }

        // 5. Supported version.
        guard Self.supportedVersions.contains(version) else {
            return Self.failure(
                id: id, status: 400, code: -32022, message: "Unsupported protocol version",
                data: ["supported": Self.supportedVersions, "requested": version]
            )
        }

        // 6. Mcp-Method header against body method.
        guard let rawHeaderMethod = request.header("Mcp-Method") else {
            return Self.failure(id: id, status: 400, code: -32020,
                                message: "Header mismatch: Mcp-Method header is missing")
        }
        let headerMethod = Self.trim(rawHeaderMethod)
        guard headerMethod == method else {
            return Self.failure(
                id: id, status: 400, code: -32020,
                message: "Header mismatch: Mcp-Method header value '\(headerMethod)' does not match body value '\(method)'"
            )
        }

        // 7. Methods this server implements in the 2026 era.
        switch method {
        case "server/discover":
            return discover(id: id)
        case "tools/list":
            // 11. This server never mints a cursor.
            if params?["cursor"] != nil {
                return Self.failure(id: id, status: 400, code: -32602, message: "Invalid params: unknown cursor")
            }
            return listTools(id: id)
        case "tools/call":
            return await callTool(id: id, params: params ?? [:], request: request)
        default:
            return Self.failure(id: id, status: 404, code: -32601, message: "Method not found")
        }
    }

    // MARK: handlers

    private func discover(id: Any) -> ModernReply {
        var result: [String: Any] = [
            "supportedVersions": Self.supportedVersions,
            "capabilities": ["tools": ["listChanged": false]],
            "instructions": RemoteToolCatalog.instructions,
            "ttlMs": Self.ttlMs,
            "cacheScope": Self.cacheScope,
        ]
        Self.stamp(&result)
        return Self.success(id: id, result: result)
    }

    private func listTools(id: Any) -> ModernReply {
        guard let tools = Self.encoded(RemoteToolCatalog.tools()) else {
            return Self.failure(id: id, status: 500, code: -32603, message: "Internal error")
        }
        var result: [String: Any] = ["tools": tools, "ttlMs": Self.ttlMs, "cacheScope": Self.cacheScope]
        Self.stamp(&result)
        return Self.success(id: id, result: result)
    }

    private func callTool(id: Any, params: [String: Any], request: HTTPRequest) async -> ModernReply {
        // 8.
        guard let name = params["name"] as? String else {
            return Self.failure(id: id, status: 400, code: -32602, message: "Invalid params: name is required")
        }
        // 9. The name is deliberately never echoed: it is client-chosen and may be long or binary.
        guard let rawName = request.header("Mcp-Name") else {
            return Self.failure(id: id, status: 400, code: -32020,
                                message: "Header mismatch: Mcp-Name header is missing")
        }
        guard let headerName = Self.decodeName(rawName) else {
            return Self.failure(id: id, status: 400, code: -32020,
                                message: "Header mismatch: Mcp-Name header value contains invalid characters")
        }
        guard headerName == name else {
            return Self.failure(id: id, status: 400, code: -32020,
                                message: "Header mismatch: Mcp-Name header does not match params.name")
        }
        // 10.
        var arguments: [String: Value] = [:]
        if let raw = params["arguments"] {
            guard let object = raw as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
            else {
                return Self.failure(id: id, status: 400, code: -32602,
                                    message: "Invalid params: arguments must be an object")
            }
            arguments = decoded
        }

        // The same three stamped headers the SDK `CallTool` handler reads.
        let caller = ToolGateway.Caller(
            clientID: request.header(InternalHeaders.clientID),
            tokenFamily: request.header(InternalHeaders.tokenFamily),
            ip: request.header(InternalHeaders.clientIP)
        )
        let outcome = await gateway.call(name: name, arguments: arguments, caller: caller)
        guard var result = Self.encoded(outcome) as? [String: Any] else {
            return Self.failure(id: id, status: 500, code: -32603, message: "Internal error")
        }
        Self.stamp(&result)
        return Self.success(id: id, result: result)
    }

    // MARK: Mcp-Name decoding

    /// Decodes an `Mcp-Name` header value. `nil` means "invalid characters". A lowercase
    /// `=?base64?...?=` wrapper carries Base64 of the UTF-8 value; anything else must be
    /// printable ASCII. The decoded value is never decoded again.
    static func decodeName(_ raw: String) -> String? {
        let value = trim(raw)
        if value.hasPrefix(sentinelPrefix), value.hasSuffix(sentinelSuffix),
           value.count >= sentinelPrefix.count + sentinelSuffix.count {
            let middle = String(value.dropFirst(sentinelPrefix.count).dropLast(sentinelSuffix.count))
            guard let data = Data(base64Encoded: middle) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard value.unicodeScalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) }) else { return nil }
        return value
    }

    // MARK: helpers

    /// HTTP optional whitespace: leading/trailing space and tab only.
    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Every success result is stamped complete and carries the server identity.
    private static func stamp(_ result: inout [String: Any]) {
        result["resultType"] = "complete"
        result["_meta"] = [
            serverInfoKey: ["name": NotetakerMCPServer.serverName, "version": NotetakerMCPServer.version],
        ]
    }

    /// Encodes with the SDK's own settings and decodes back to a JSON object for splicing
    /// into the envelope.
    private static func encoded(_ value: some Encodable) -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func success(id: Any, result: [String: Any]) -> ModernReply {
        envelope(["jsonrpc": "2.0", "id": id, "result": result], status: 200)
    }

    private static func failure(
        id: Any?, status: Int, code: Int, message: String, data: [String: Any]? = nil
    ) -> ModernReply {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        return envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error], status: status)
    }

    private static func envelope(_ object: [String: Any], status: Int) -> ModernReply {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return ModernReply(status: 500)
        }
        return ModernReply(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
}
