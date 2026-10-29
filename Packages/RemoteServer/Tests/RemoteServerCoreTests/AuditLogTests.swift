import Foundation
import MCP
@testable import RemoteServerCore
import Testing

struct AuditLogTests {
    private func lines(_ fixture: ReplicaFixture) throws -> [[String: Any]] {
        let text = try String(contentsOf: fixture.auditURL, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func linesContainOnlyAllowlistedKeysAndNeverContent() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let log = AuditLog(url: fixture.auditURL)
        let watcher = try await fixture.readyWatcher(audit: log)
        let gate = ToolGateway(replica: watcher, audit: log)
        let hostile: [String: Value] = [
            "path": "Inbox.md", "query": "dean", "content": "SECRET BODY TEXT", "snippet": "SNIP",
            "title": "TITLE", "limit": 3,
        ]
        for tool in RemoteToolCatalog.toolNames.sorted() {
            _ = await gate.call(
                name: tool,
                arguments: hostile,
                caller: .init(clientID: "c1", tokenFamily: "f1", ip: "203.0.113.9")
            )
        }
        let all = try lines(fixture)
        #expect(all.count >= 7)
        let raw = try String(contentsOf: fixture.auditURL, encoding: .utf8)
        #expect(!raw.contains("SECRET BODY TEXT"))
        #expect(!raw.contains("SNIP"))
        #expect(!raw.contains("pharmacology")) // note text
        for line in all {
            #expect(Set(line.keys).isSubset(of: AuditLog.allowedKeys), "\(line.keys)")
            if let args = line["args"] as? [String: Any] {
                #expect(Set(args.keys).isSubset(of: AuditLog.allowedArgKeys))
                for key in ["content", "snippet", "title"] {
                    #expect(args[key] == nil)
                }
                for value in args.values {
                    #expect(String(describing: value).count < 256)
                }
            }
        }
        // One line per request (list_folder on a file path is a tool.error).
        let calls = all.filter { ["tool.call", "tool.error"].contains($0["event"] as? String ?? "") }
        #expect(calls.count == 7)
        #expect(calls.allSatisfy { $0["client_id"] as? String == "c1" && $0["token_family"] as? String == "f1" })
    }

    @Test func longValuesAreTruncatedBelow256() throws {
        let data = AuditLog.encode(
            AuditEvent(event: "tool.call", tool: "search", args: ["query": String(repeating: "q", count: 5000)]),
            at: Date(timeIntervalSince1970: 0)
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let args = try #require(object["args"] as? [String: String])
        #expect(args["query"]?.count == 255)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }

    @Test func eventsOutsideTheAllowlistAreDroppedByConstruction() {
        let data = AuditLog.encode(
            AuditEvent(event: "x", args: ["content": "BODY", "path": "a.md"]), at: Date(timeIntervalSince1970: 0)
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("BODY"))
        #expect(text.contains("a.md"))
    }

    @Test func logAppendsAcrossInstances() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        await AuditLog(url: fixture.auditURL).record(AuditEvent(event: "server.start"))
        await AuditLog(url: fixture.auditURL).record(AuditEvent(event: "kill"))
        #expect(try lines(fixture).map { $0["event"] as? String } == ["server.start", "kill"])
    }
}
