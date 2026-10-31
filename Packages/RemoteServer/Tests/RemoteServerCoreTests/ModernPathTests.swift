import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import MCPKit
@testable import RemoteServerCore
import Testing

/// MCP 2026-07-28 on `/mcp` (spec mcp-2026/01). Row numbers in the comments are the
/// spec's §10 test table.
struct ModernPathTests {
    typealias Harness = HTTPHarness

    static let paths = ["Inbox.md", "Daily/2026-08-20.md", "Work/Curriculum.md", "CLAUDE.md"]
    static let toolOrder = [
        "vault_overview", "list_folder", "read_note", "search", "tasks", "calendar_agenda", "calendar_list",
    ]

    private static func field(_ name: String) -> HTTPField.Name {
        HTTPField.Name(name)!
    }

    private static func call(_ id: Any, name: String, arguments: String = "{}") -> ByteBuffer {
        Harness.modern(id, "tools/call", params: "{\"name\":\"\(name)\",\"arguments\":\(arguments)}")
    }

    private func discover(_ client: any TestClientProtocol, id: Any = "discover-1") async throws -> Harness.Reply {
        try await Harness.post(
            client, headers: Harness.modernHeaders(method: "server/discover"),
            body: Harness.modern(id, "server/discover")
        )
    }

    private func list(_ client: any TestClientProtocol, id: Any = 1) async throws -> Harness.Reply {
        try await Harness.post(
            client, headers: Harness.modernHeaders(method: "tools/list"), body: Harness.modern(id, "tools/list")
        )
    }

    private func readNote(
        _ client: any TestClientProtocol, path: String, id: Any = 1, name: String? = "read_note"
    ) async throws -> Harness.Reply {
        try await Harness.post(
            client, headers: Harness.modernHeaders(method: "tools/call", name: name),
            body: Self.call(id, name: "read_note", arguments: "{\"path\":\"\(path)\"}")
        )
    }

    private func auditLines(_ fixture: ReplicaFixture) -> [String] {
        ((try? String(contentsOf: fixture.auditURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: 1

    @Test func discoverAnswersStatelessly() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let ids: [Any] = ["discover-1", 7, "x"]
            for id in ids {
                let reply = try await discover(client, id: id)
                #expect(reply.status == 200)
                #expect(reply.headers[Self.field("Mcp-Session-Id")] == nil)
                if let string = id as? String {
                    #expect(reply.object["id"] as? String == string)
                } else {
                    #expect(reply.object["id"] as? Int == 7)
                }
                #expect(reply.object["jsonrpc"] as? String == "2.0")
                let expected: [String: Any] = [
                    "resultType": "complete",
                    "supportedVersions": ["2026-07-28"],
                    "capabilities": ["tools": ["listChanged": false]],
                    "instructions": RemoteToolCatalog.instructions,
                    "ttlMs": 3_600_000,
                    "cacheScope": "private",
                    "_meta": [
                        "io.modelcontextprotocol/serverInfo": [
                            "name": "notetaker", "version": NotetakerMCPServer.version,
                        ],
                    ],
                ]
                #expect(try (#require(reply.result) as NSDictionary).isEqual(to: expected))
                #expect((reply.result?["instructions"] as? String)?.contains("read-only replica") == true)
            }
        }
    }

    // MARK: 2

    @Test func modernToolsListIsTheSevenToolsInStableOrder() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            var modernTools: [[String: Any]] = []
            for round in 1 ... 2 {
                let reply = try await list(client, id: round)
                #expect(reply.status == 200)
                let result = try #require(reply.result)
                let tools = try #require(result["tools"] as? [[String: Any]])
                #expect(tools.compactMap { $0["name"] as? String } == Self.toolOrder)
                let search = try #require(tools.first { $0["name"] as? String == "search" })
                let properties = (search["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
                #expect(properties?["mode"] == nil)
                #expect(properties?["query"] != nil)
                for tool in tools {
                    #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
                }
                #expect(result["ttlMs"] as? Int == 3_600_000)
                #expect(result["cacheScope"] as? String == "private")
                #expect(result["resultType"] as? String == "complete")
                #expect(result["nextCursor"] == nil)
                modernTools = tools
            }
            // The legacy list, same process, same catalog.
            let initialize = Harness.rpc(
                1, "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            _ = try await Harness.post(client, headers: Harness.bearer(), body: initialize)
            let legacy = try await Harness.post(client, headers: Harness.bearer(), body: Harness.rpc(2, "tools/list"))
            let legacyTools = try #require(legacy.result?["tools"] as? [[String: Any]])
            #expect((modernTools as NSArray).isEqual(to: legacyTools))
        }
    }

    // MARK: 3

    @Test func modernToolsCallGoesThroughTheGateway() async throws {
        try await Harness.withFixtureApp(authenticator: AllowAllAuthenticator()) { client, fixture in
            let reply = try await readNote(client, path: "Inbox.md")
            #expect(reply.status == 200)
            let result = try #require(reply.result)
            #expect(result["resultType"] as? String == "complete")
            #expect(result["isError"] as? Bool != true)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["path"] as? String == "Inbox.md")
            #expect((structured["content"] as? String)?.contains("accreditation") == true)
            #expect(structured["replica_generated_at"] != nil)
            let content = try #require(result["content"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            #expect(text.hasPrefix(ToolGateway.preamble))
            #expect(text.contains("<untrusted_vault_data>"))
            #expect((result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] != nil)

            let calls = auditLines(fixture).filter { $0.contains("\"event\":\"tool.call\"") }
            #expect(calls.count == 1)
            #expect(calls.first?.contains("\"client_id\":\"test-client\"") == true)
        }
    }

    // MARK: 4

    @Test func modernErrorResultsStayInBand() async throws {
        try await Harness.withFixtureApp(authenticator: AllowAllAuthenticator()) { client, fixture in
            let unknown = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/call", name: "nope"),
                body: Self.call(1, name: "nope")
            )
            #expect(unknown.status == 200)
            #expect(unknown.result?["isError"] as? Bool == true)
            #expect(unknown.result?["resultType"] as? String == "complete")

            let longPath = String(repeating: "a", count: 2000)
            let clamped = try await readNote(client, path: longPath, id: 2)
            #expect(clamped.status == 200)
            #expect(clamped.result?["isError"] as? Bool == true)
            #expect(clamped.result?["resultType"] as? String == "complete")

            let errors = auditLines(fixture).filter { $0.contains("\"event\":\"tool.error\"") }
            #expect(errors.contains { $0.contains("\"tool\":\"(unknown)\"") })
            #expect(errors.count == 2)
        }
    }

    // MARK: 5

    @Test func unsupportedVersionIs32022() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            for requested in ["2026-12-01", "1900-01-01"] {
                for id: Any in ["a-1", 5] {
                    let reply = try await Harness.post(
                        client, headers: Harness.modernHeaders(method: "server/discover", version: requested),
                        body: Harness.modern(id, "server/discover", version: requested)
                    )
                    #expect(reply.status == 400)
                    let error = try #require(reply.error)
                    #expect(error["code"] as? Int == -32022)
                    #expect(error["message"] as? String == "Unsupported protocol version")
                    let data = try #require(error["data"] as? [String: Any])
                    #expect(data["supported"] as? [String] == ["2026-07-28"])
                    #expect(data["requested"] as? String == requested)
                    if let string = id as? String {
                        #expect(reply.object["id"] as? String == string)
                    } else {
                        #expect(reply.object["id"] as? Int == 5)
                    }
                }
            }
        }
    }

    // MARK: 6

    @Test func headerBodyVersionMismatchIs32020() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let reply = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/list", version: "2026-07-28"),
                body: Harness.modern(3, "tools/list", version: "2025-11-25")
            )
            #expect(reply.status == 400)
            #expect(reply.error?["code"] as? Int == -32020)
            #expect(reply.error?["message"] as? String ==
                "Header mismatch: MCP-Protocol-Version header value '2026-07-28' does not match body value '2025-11-25'")
            #expect(reply.object["id"] as? Int == 3)
        }
    }

    // MARK: 7

    @Test func missingOrWrongMcpMethodIs32020() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            var headers = Harness.modernHeaders(method: "tools/list")
            headers[Self.field("Mcp-Method")] = nil
            let missing = try await Harness.post(client, headers: headers, body: Harness.modern(1, "tools/list"))
            #expect(missing.status == 400)
            #expect(missing.error?["code"] as? Int == -32020)
            #expect(missing.error?["message"] as? String == "Header mismatch: Mcp-Method header is missing")

            let wrong = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/list", name: "read_note"),
                body: Self.call(2, name: "read_note", arguments: "{\"path\":\"Inbox.md\"}")
            )
            #expect(wrong.status == 400)
            #expect(wrong.error?["code"] as? Int == -32020)
            #expect(wrong.error?["message"] as? String ==
                "Header mismatch: Mcp-Method header value 'tools/list' does not match body value 'tools/call'")
        }
    }

    // MARK: 8

    @Test func mcpNameIsValidatedWithSentinelDecoding() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let cases: [(String?, Int, String?)] = [
                (nil, 400, "Header mismatch: Mcp-Name header is missing"),
                ("list_folder", 400, "Header mismatch: Mcp-Name header does not match params.name"),
                ("=?base64?cmVhZF9ub3Rl?=", 200, nil),
                ("=?base64?***?=", 400, "Header mismatch: Mcp-Name header value contains invalid characters"),
                ("caf\u{E9}", 400, "Header mismatch: Mcp-Name header value contains invalid characters"),
                ("  read_note ", 200, nil),
            ]
            for (name, status, message) in cases {
                let reply = try await readNote(client, path: "Inbox.md", name: name)
                #expect(reply.status == status, "\(name ?? "absent")")
                if let message {
                    #expect(reply.error?["code"] as? Int == -32020)
                    #expect(reply.error?["message"] as? String == message)
                    #expect(!reply.text.contains("read_note"))
                    #expect(!reply.text.contains("list_folder"))
                }
            }
        }
    }

    // MARK: 9

    @Test func decodeNameTable() {
        let table: [(String, String?)] = [
            ("read_note", "read_note"),
            ("=?base64?cmVhZF9ub3Rl?=", "read_note"),
            ("=?base64?SGVsbG8sIOS4lueVjA==?=", "Hello, 世界"),
            ("=?base64?IHBhZGRlZCA=?=", " padded "),
            ("=?base64?bGluZTEKbGluZTI=?=", "line1\nline2"),
            ("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", "=?base64?literal?="),
            ("=?base64?***?=", nil),
            ("=?BASE64?cmVhZF9ub3Rl?=", "=?BASE64?cmVhZF9ub3Rl?="),
            ("caf\u{E9}", nil),
            ("  read_note ", "read_note"),
            ("tab\tinside", nil),
            ("=?base64?/w==?=", nil), // 0xFF alone is not UTF-8
        ]
        for (raw, expected) in table {
            #expect(ModernPath.decodeName(raw) == expected, "\(raw)")
        }
    }

    // MARK: 10

    @Test func modernBodyWithoutVersionHeaderIs32020() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let absent = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/list", version: nil),
                body: Harness.modern(1, "tools/list")
            )
            #expect(absent.status == 400)
            #expect(absent.error?["code"] as? Int == -32020)
            #expect(absent.error?["message"] as? String == "Header mismatch: MCP-Protocol-Version header is missing")

            let legacyHeader = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/list", version: "2025-11-25"),
                body: Harness.modern(1, "tools/list")
            )
            #expect(legacyHeader.status == 400)
            #expect(legacyHeader.error?["code"] as? Int == -32020)
            #expect(legacyHeader.error?["message"] as? String ==
                "Header mismatch: MCP-Protocol-Version header value '2025-11-25' does not match body value '2026-07-28'")
        }
    }

    // MARK: 11

    @Test func missingRequiredMetaIs32602() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let capabilities = "io.modelcontextprotocol/clientCapabilities"
            let version = "io.modelcontextprotocol/protocolVersion"
            let cases: [(String, String)] = [
                ("{\"\(version)\":\"2026-07-28\"}", capabilities),
                ("{\"io.modelcontextprotocol/clientCapabilities\":{}}", version),
                ("{\"\(version)\":2026,\"\(capabilities)\":{}}", version),
                ("", version),
            ]
            for (meta, key) in cases {
                let reply = try await Harness.post(
                    client, headers: Harness.modernHeaders(method: "tools/list"),
                    body: Harness.modern(4, "tools/list", meta: meta)
                )
                #expect(reply.status == 400, "\(meta)")
                #expect(reply.error?["code"] as? Int == -32602)
                #expect(reply.error?["message"] as? String == "Invalid params: _meta.\(key) is required")
                #expect(reply.object["id"] as? Int == 4)
            }
        }
    }

    // MARK: 13

    @Test func unknownModernMethodIs404() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let methods = [
                "resources/list", "prompts/list", "ping", "logging/setLevel", "subscriptions/listen", "tasks/list",
            ]
            for (index, method) in methods.enumerated() {
                let reply = try await Harness.post(
                    client, headers: Harness.modernHeaders(method: method), body: Harness.modern(index + 10, method)
                )
                #expect(reply.status == 404, "\(method)")
                #expect(reply.error?["code"] as? Int == -32601)
                #expect(reply.error?["message"] as? String == "Method not found")
                #expect(reply.object["id"] as? Int == index + 10)
                #expect(reply.headers[.contentType] == "application/json")
            }
        }
    }

    // MARK: 14

    @Test func mixedEraConcurrentCallersDoNotCollide() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let initialize = Harness.rpc(
                1, "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            _ = try await Harness.post(client, headers: Harness.bearer(), body: initialize)
            for _ in 1 ... 2 {
                try await withThrowingTaskGroup(of: String.self) { group in
                    for path in Self.paths {
                        group.addTask {
                            let reply = try await Harness.post(
                                client,
                                headers: Harness.modernHeaders(method: "tools/call", name: "read_note"),
                                body: Self.call(7, name: "read_note", arguments: "{\"path\":\"\(path)\"}")
                            )
                            #expect(reply.status == 200)
                            #expect(reply.object["id"] as? Int == 7)
                            return (reply.result?["structuredContent"] as? [String: Any])?["path"] as? String ?? ""
                        }
                        group.addTask {
                            let reply = try await Harness.post(
                                client, headers: Harness.bearer(),
                                body: Harness.rpc(
                                    7, "tools/call", "{\"name\":\"read_note\",\"arguments\":{\"path\":\"\(path)\"}}"
                                )
                            )
                            #expect(reply.status == 200)
                            #expect(reply.object["id"] as? Int == 7)
                            return (reply.result?["structuredContent"] as? [String: Any])?["path"] as? String ?? ""
                        }
                    }
                    var seen: [String] = []
                    for try await path in group {
                        seen.append(path)
                    }
                    #expect(seen.sorted() == (Self.paths + Self.paths).sorted())
                }
            }
        }
    }

    // MARK: 15

    @Test func legacyRequestsNeverSeeModernValidation() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let initialize = Harness.rpc(
                1, "initialize",
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
            )
            _ = try await Harness.post(client, headers: Harness.bearer(), body: initialize)
            let tools = try await Harness.post(client, headers: Harness.bearer(), body: Harness.rpc(2, "tools/list"))
            #expect(tools.status == 200)
            #expect((tools.result?["tools"] as? [[String: Any]])?.count == 7)
            #expect(tools.result?["resultType"] == nil)
            let ping = try await Harness.post(client, headers: Harness.bearer(), body: Harness.rpc(3, "ping"))
            #expect(ping.status == 200)
            #expect((ping.result as NSDictionary?)?.count == 0)
        }
    }

    // MARK: 16

    @Test func sessionAndLastEventIdHeadersAreIgnored() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            var headers = Harness.modernHeaders(method: "server/discover")
            headers[Self.field("Mcp-Session-Id")] = "x"
            headers[Self.field("Last-Event-ID")] = "1"
            let reply = try await Harness.post(client, headers: headers, body: Harness.modern("d", "server/discover"))
            #expect(reply.status == 200)
            #expect(reply.headers[Self.field("Mcp-Session-Id")] == nil)
        }
    }

    // MARK: 17

    @Test func modernNotificationIs202() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let withMeta = ByteBuffer(string: """
            {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"_meta":\(Harness.defaultMeta)}}
            """)
            let bare = ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}")
            var noMethodHeader = Harness.modernHeaders(method: "notifications/cancelled")
            noMethodHeader[Self.field("Mcp-Method")] = nil
            let attempts: [(HTTPFields, ByteBuffer)] = [
                (Harness.modernHeaders(method: "notifications/cancelled"), withMeta),
                (Harness.modernHeaders(method: "notifications/cancelled"), bare),
                (noMethodHeader, withMeta),
            ]
            for (headers, body) in attempts {
                let reply = try await Harness.post(client, headers: headers, body: body)
                #expect(reply.status == 202)
                #expect(reply.body.isEmpty)
                #expect(reply.headers[.contentType] == nil)
            }
        }
    }

    // MARK: 18

    @Test func authRunsBeforeEraClassification() async throws {
        try await Harness.withFixtureApp { client, fixture in
            let body = Harness.modern("discover-1", "server/discover")
            var anonymous = Harness.modernHeaders(method: "server/discover")
            anonymous[.authorization] = nil
            let missing = try await Harness.post(client, headers: anonymous, body: body)
            #expect(missing.status == 401)
            #expect(missing.headers[.wwwAuthenticate] == "Bearer resource_metadata=\"\(Harness.metadataURL)\"")
            #expect(missing.text == "{\"error\":\"unauthorized\"}")

            let bogus = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "server/discover", bearerToken: "bogus-token"),
                body: body
            )
            #expect(bogus.status == 401)

            var foreign = Harness.modernHeaders(method: "server/discover")
            foreign[Self.field("Host")] = "evil.example"
            #expect(try await Harness.post(client, headers: foreign, body: body).status == 421)

            let padded = ByteBuffer(string: String(repeating: " ", count: 65 * 1024) + "{}")
            let big = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "server/discover"), body: padded
            )
            #expect(big.status == 413)

            let lines = auditLines(fixture)
            #expect(lines.contains { $0.contains("\"event\":\"auth.missing\"") })
            #expect(!lines.contains { $0.contains("\"event\":\"tool.") })
        }
    }

    // MARK: 20

    @Test func disabledReplicaStillDiscovers() async throws {
        try await Harness.withFixtureApp(authenticator: AllowAllAuthenticator(), disabled: true) { client, _ in
            #expect(try await discover(client).status == 200)
            let listed = try await list(client)
            #expect(listed.status == 200)
            #expect((listed.result?["tools"] as? [[String: Any]])?.count == 7)
            let overview = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/call", name: "vault_overview"),
                body: Self.call(3, name: "vault_overview")
            )
            #expect(overview.status == 200)
            let result = try #require(overview.result)
            #expect(result["resultType"] as? String == "complete")
            #expect(result["isError"] as? Bool != true)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["available"] as? Bool == false)
            #expect((structured["reason"] as? String)?.contains("disabled") == true)
        }
    }

    // MARK: 21

    @Test func modernGetAndDeleteAre405() async throws {
        try await Harness.withApp { client in
            var headers = Harness.modernHeaders(method: "server/discover")
            headers[.authorization] = nil
            for method in [HTTPRequest.Method.get, .delete] {
                try await client.execute(uri: "/mcp", method: method, headers: headers) { response in
                    #expect(response.status == .methodNotAllowed)
                    #expect(response.headers[.allow] == "POST")
                    #expect(response.body.readableBytes == 0)
                }
            }
        }
    }

    // MARK: 22

    @Test func modernErrorsAreNon200AndResultsAre200() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            var noMethod = Harness.modernHeaders(method: "tools/list")
            noMethod[Self.field("Mcp-Method")] = nil
            let attempts: [(HTTPFields, ByteBuffer)] = [
                (Harness.modernHeaders(method: "server/discover"), Harness.modern(1, "server/discover")),
                (Harness.modernHeaders(method: "tools/list"), Harness.modern(2, "tools/list")),
                (Harness.modernHeaders(method: "tools/call", name: "read_note"),
                 Self.call(3, name: "read_note", arguments: "{\"path\":\"Inbox.md\"}")),
                (Harness.modernHeaders(method: "tools/call", name: "nope"), Self.call(4, name: "nope")),
                (Harness.modernHeaders(method: "tools/list", version: nil), Harness.modern(5, "tools/list")),
                (Harness.modernHeaders(method: "tools/list", version: "2026-12-01"),
                 Harness.modern(6, "tools/list", version: "2026-12-01")),
                (noMethod, Harness.modern(7, "tools/list")),
                (Harness.modernHeaders(method: "ping"), Harness.modern(8, "ping")),
                (Harness.modernHeaders(method: "tools/list"), Harness.modern(9, "tools/list", meta: "{}")),
                (
                    Harness.modernHeaders(method: "tools/list"),
                    Harness.modern(10, "tools/list", params: "{\"cursor\":\"x\"}")
                ),
                (Harness.modernHeaders(method: "tools/call", name: "read_note"),
                 Harness.modern(11, "tools/call", params: "{\"name\":\"read_note\",\"arguments\":[]}")),
                (Harness.modernHeaders(method: "tools/call", name: "read_note"),
                 Harness.modern(12, "tools/call", params: "{}")),
            ]
            for (headers, body) in attempts {
                let reply = try await Harness.post(client, headers: headers, body: body)
                #expect(reply.headers[.contentType] == "application/json")
                if reply.error != nil {
                    #expect(reply.status != 200)
                    #expect(reply.result == nil)
                } else {
                    #expect(reply.status == 200)
                    #expect(reply.result != nil)
                }
            }
        }
    }

    // MARK: 23

    @Test func isModernTable() {
        func request(_ headerVersion: String?) -> MCP.HTTPRequest {
            var headers: [String: String] = [:]
            if let headerVersion {
                headers["mcp-protocol-version"] = headerVersion
            }
            return MCP.HTTPRequest(method: "POST", headers: headers)
        }
        let metaMessage: [String: Any] = [
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]],
        ]
        // initialize is excluded by the caller (RemoteMCPServer.respond); with no 2026
        // marker at all the classifier itself says legacy.
        #expect(!ModernPath.isModern(method: "initialize", message: [:], request: request("2025-11-25")))
        #expect(ModernPath.isModern(method: "subscriptions/listen", message: [:], request: request(nil)))
        #expect(ModernPath.isModern(method: "server/discover", message: [:], request: request(nil)))
        #expect(ModernPath.isModern(method: "tools/list", message: metaMessage, request: request(nil)))
        #expect(!ModernPath.isModern(method: "tools/list", message: [:], request: request("2025-11-25")))
        #expect(!ModernPath.isModern(method: "tools/list", message: [:], request: request(nil)))
        #expect(ModernPath.isModern(method: "tools/list", message: [:], request: request("2026-07-28")))
        #expect(ModernPath.isModern(method: "tools/list", message: [:], request: request("3000-01-01")))
        #expect(ModernPath.isModern(method: "tools/list", message: [:], request: request(" 2026-07-28\t")))
    }

    @Test func requestsWithoutAMethodAreNotClassified() async throws {
        // No `method` (a JSON-RPC response) keeps today's SDK path, whatever the headers say.
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let response = ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
            let reply = try await Harness.post(
                client, headers: Harness.modernHeaders(method: "tools/list"), body: response
            )
            #expect(reply.error?["code"] as? Int != -32020)
            #expect(reply.error?["code"] as? Int != -32602)
        }
    }

    // MARK: 24

    @Test func badIdIs32600() async throws {
        try await Harness.withApp(authenticator: AllowAllAuthenticator()) { client in
            let meta = Harness.defaultMeta
            for id in ["null", "{\"a\":1}", "[1]"] {
                let body = ByteBuffer(string:
                    "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/list\",\"params\":{\"_meta\":\(meta)}}")
                let reply = try await Harness.post(
                    client, headers: Harness.modernHeaders(method: "tools/list"), body: body
                )
                #expect(reply.status == 400, "\(id)")
                #expect(reply.error?["code"] as? Int == -32600)
                #expect(reply.error?["message"] as? String == "Invalid Request: id must be a string or number")
                #expect(reply.object["id"] is NSNull)
            }
        }
    }
}
