import Foundation
import MCP
@testable import RemoteServerCore
import Testing

/// Design §5 test 3: even if the Mac's exporter failed and shipped a locked
/// note and an `_index.md`, nothing from them reaches a tool response, and
/// `audit-replica` removes them.
struct DefenseInDepthTests {
    private func contaminated() throws -> (ReplicaFixture, [String: String]) {
        let fixture = try ReplicaFixture()
        let notes = ReplicaFixture.notes.merging(ReplicaFixture.contamination) { $1 }
        try fixture.push(notes: notes)
        return (fixture, notes)
    }

    @Test func lockedContentNeverReachesAnyToolResponse() async throws {
        let (fixture, _) = try contaminated()
        defer { fixture.cleanUp() }
        let watcher = try await fixture.readyWatcher()
        guard case .ready = await watcher.current().state else {
            Issue.record("contaminated replica should still be consistent")
            return
        }
        let gateway = ToolGateway(replica: watcher)
        var seen: [String] = []

        for path in ["Work/Locked.md", "Work/LockedCRLF.md"] {
            let read = await gateway.call(name: "read_note", arguments: ["path": .string(path)])
            #expect(read.structuredContent?["locked"]?.boolValue == true)
            #expect(read.structuredContent?["content"] == nil)
            seen.append(everything(in: read))
        }

        let search = await gateway.call(name: "search", arguments: ["query": .string("SENTINEL")])
        seen.append(everything(in: search))
        let hits = search.structuredContent?["results"]?.arrayValue ?? []
        for hit in hits {
            #expect(hit["snippet"]?.stringValue?.contains("SENTINEL") != true)
        }

        let folder = await gateway.call(name: "list_folder", arguments: ["path": .string("Work")])
        let entries = folder.structuredContent?["notes"]?.arrayValue ?? []
        for path in ["Work/Locked.md", "Work/LockedCRLF.md"] {
            let entry = entries.first { $0["path"]?.stringValue == path }
            #expect(entry?["locked"]?.boolValue == true, "\(path) must be flagged locked in list_folder")
        }
        seen.append(everything(in: folder))

        let tasks = await gateway.call(name: "tasks", arguments: ["include_completed": .bool(true)])
        let taskPaths = (tasks.structuredContent?["tasks"]?.arrayValue ?? [])
            .compactMap { $0["path"]?.stringValue ?? $0["note"]?.stringValue }
        #expect(!taskPaths.isEmpty, "the tasks tool should still return the legitimate tasks")
        #expect(!taskPaths.contains { $0.contains("Locked") })
        seen.append(everything(in: tasks))

        for tool in ["vault_overview", "calendar_agenda", "calendar_list"] {
            await seen.append(everything(in: gateway.call(name: tool, arguments: [:])))
        }
        for text in seen {
            #expect(!text.contains(lockedSentinel))
        }
    }

    @Test func auditReplicaDeletesTheContaminationAndExitsTwoThenZero() async throws {
        let (fixture, _) = try contaminated()
        defer { fixture.cleanUp() }
        let log = AuditLog(url: fixture.auditURL)
        let command = try AuditReplicaCommand(config: fixture.config(), audit: log)
        var output: [String] = []

        #expect(await command.run(report: { output.append($0) }) == 2)
        let vault = fixture.replica.appendingPathComponent("vault")
        for path in ["Work/Locked.md", "Work/LockedCRLF.md", "_index.md"] {
            #expect(
                !FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
                "\(path) should be gone"
            )
        }
        // Legitimate notes survive.
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Inbox.md").path))
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Work/Curriculum.md").path))

        #expect(await command.run(report: { output.append($0) }) == 0)
        let lines = try String(contentsOf: fixture.auditURL, encoding: .utf8)
        #expect(lines.contains("replica.contaminated"))
        #expect(!lines.contains(lockedSentinel))
    }

    @Test func auditReplicaRemovesStrayFilesAndSymlinks() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let vault = fixture.replica.appendingPathComponent("vault")
        try Data("x".utf8).write(to: vault.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("link.md"), withDestinationURL: fixture.state
        )
        let command = try AuditReplicaCommand(config: fixture.config())
        #expect(await command.run(report: { _ in }) == 2)
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("notes.txt").path))
        #expect((try? FileManager.default
                .destinationOfSymbolicLink(atPath: vault.appendingPathComponent("link.md").path)) == nil)
        #expect(await command.run(report: { _ in }) == 0)
    }

    @Test func watcherAuditsContaminationWhenItSeesIt() async throws {
        let (fixture, _) = try contaminated()
        defer { fixture.cleanUp() }
        let log = AuditLog(url: fixture.auditURL)
        _ = try await fixture.readyWatcher(audit: log)
        // The audit actor has finished its writes by the time `tick` returned.
        let text = try String(contentsOf: fixture.auditURL, encoding: .utf8)
        #expect(text.contains("replica.contaminated"))
        #expect(text.contains("replica.ready"))
    }
}
