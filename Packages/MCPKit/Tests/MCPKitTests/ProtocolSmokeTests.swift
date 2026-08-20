import Foundation
import MCP
@testable import MCPKit
import Testing

/// End-to-end over a real transport: initialize → tools/list → tools/call,
/// the exact handshake Claude Code performs when it spawns the binary.
struct ProtocolSmokeTests {
    @Test func initializeListAndCallOverATransport() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await NotetakerMCPServer.make(service: fixture.service(withIndex: true))
        try await server.start(transport: serverTransport)
        defer { Task { await server.stop() } }

        let client = Client(name: "MCPKitTests", version: "1.0.0")
        let initialization = try await client.connect(transport: clientTransport)
        #expect(initialization.serverInfo.name == "notetaker")
        #expect(initialization.capabilities.tools != nil)
        #expect(initialization.instructions?.contains("vault_overview") == true)

        let listed = try await client.listTools()
        #expect(listed.tools.map(\.name).sorted() == [
            "list_folder", "read_note", "search", "tasks", "vault_overview",
        ])
        // Every tool must advertise itself as read-only, and say what it's for.
        for tool in listed.tools {
            #expect(tool.annotations.readOnlyHint == true)
            #expect((tool.description?.count ?? 0) > 80)
        }

        let call: (content: [Tool.Content], isError: Bool?) =
            try await client.callTool(name: "vault_overview")
        #expect(call.isError != true)
        guard case let .text(text, _, _) = call.content.first else {
            Issue.record("expected text content")
            return
        }
        let decoded = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(decoded["source"]?.stringValue == "index")
        #expect(decoded["note_count"]?.intValue == 5)

        await client.disconnect()
    }

    @Test func unknownToolIsAnErrorResult() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        let result = await NotetakerMCPServer.call(
            name: "delete_everything", arguments: [:], service: fixture.service(withIndex: false)
        )
        #expect(result.isError == true)
    }

    @Test func callToolValidatesRequiredArguments() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        let result = await NotetakerMCPServer.call(
            name: "read_note", arguments: [:], service: fixture.service(withIndex: false)
        )
        #expect(result.isError == true)
    }

    @Test func callToolRoutesArgumentsIntoTheTaskFilters() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let result = await NotetakerMCPServer.call(
            name: "tasks", arguments: ["kind": .string("discuss")],
            service: fixture.service(withIndex: true)
        )
        #expect(result.isError == false)
        #expect(result.structuredContent?["count"]?.intValue == 1)
    }

    @Test func helpExitsCleanly() async {
        #expect(await NotetakerMCPLauncher.run(arguments: ["--help"]) == 0)
        #expect(await NotetakerMCPLauncher.run(arguments: ["--version"]) == 0)
    }

    @Test func launcherReportsAnUnresolvableVault() async {
        #expect(await NotetakerMCPLauncher.run(arguments: ["--vault", "/nowhere/at/all"]) == 1)
    }
}
