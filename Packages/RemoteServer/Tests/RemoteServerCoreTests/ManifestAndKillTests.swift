import Foundation
@testable import RemoteServerCore
import Testing

struct ManifestParityTests {
    /// Shape of VaultKit.ReplicaManifest's JSON as spec 03 pins it
    /// (`.sortedKeys, .iso8601`). If the exporter's key set changes, this and
    /// `ReplicaManifest` change together.
    static let exporterJSON = """
    {
      "appVersion" : "1.2.3",
      "calendarIncluded" : true,
      "disabled" : false,
      "files" : [
        { "bytes" : 5, "path" : "A.md", "sha256" : "aa" },
        { "bytes" : 7, "path" : "B/C.md", "sha256" : "bb" }
      ],
      "filesDigest" : "dd",
      "generatedAt" : "2026-10-29T12:00:00Z",
      "indexExcludedCount" : 2,
      "lockedExcludedCount" : 3,
      "noteCount" : 2,
      "notDownloadedCount" : 1,
      "otherExcludedCount" : 4,
      "policyVersion" : 1,
      "schemaVersion" : 1
    }
    """

    @Test func decodesTheExportersJSON() throws {
        let manifest = try ReplicaManifest.decode(Data(Self.exporterJSON.utf8))
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.noteCount == 2)
        #expect(manifest.lockedExcludedCount == 3)
        #expect(manifest.files.map(\.path) == ["A.md", "B/C.md"])
        #expect(manifest.generatedAt == Date(timeIntervalSince1970: 1_793_275_200))
        #expect(manifest.appVersion == "1.2.3")
    }

    @Test func keySetIsPinned() throws {
        let expected: Set = [
            "schemaVersion", "generatedAt", "policyVersion", "disabled", "noteCount", "lockedExcludedCount",
            "indexExcludedCount", "otherExcludedCount", "notDownloadedCount", "calendarIncluded", "files",
            "filesDigest", "appVersion",
        ]
        let decoded = try #require(try JSONSerialization
            .jsonObject(with: Data(Self.exporterJSON.utf8)) as? [String: Any])
        #expect(Set(decoded.keys) == expected)
        let manifest = ReplicaManifest(
            generatedAt: Date(),
            files: [.init(path: "a.md", sha256: "x", bytes: 1)],
            appVersion: "t"
        )
        let encoded = try #require(try JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
        #expect(Set(encoded.keys) == expected)
        let entry = try #require((encoded["files"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["path", "sha256", "bytes"])
    }

    @Test func fractionalSecondsAreTolerated() throws {
        let json = Self.exporterJSON.replacingOccurrences(of: "2026-10-29T12:00:00Z", with: "2026-10-29T12:00:00.250Z")
        #expect(try ReplicaManifest.decode(Data(json.utf8)).generatedAt.timeIntervalSince1970 > 1_793_275_200)
    }

    @Test func digestMatchesTheSpecFormula() {
        let files: [ReplicaManifest.Entry] = [
            .init(path: "a.md", sha256: "11", bytes: 1),
            .init(path: "b.md", sha256: "22", bytes: 1),
        ]
        #expect(ReplicaManifest.digest(of: files) == Hashing.sha256Hex(Data("a.md\n11\nb.md\n22\n".utf8)))
        // Known SHA-256 vector.
        #expect(Hashing
            .sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class RecordingActions: SystemActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []
    var euid: UInt32
    var failing: Set<String> = []

    init(euid: UInt32) {
        self.euid = euid
    }

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _steps
    }

    private func note(_ step: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _steps.append(step)
        return !failing.contains(step)
    }

    func effectiveUserID() -> UInt32 {
        euid
    }

    func removeFile(at url: URL) -> Bool {
        note("rm \(url.lastPathComponent)")
    }

    func removeContents(of directory: URL) -> Bool {
        note("wipe \(directory.lastPathComponent)")
    }

    func writeMarker(at url: URL) -> Bool {
        note("write \(url.lastPathComponent)")
    }

    func run(_ executable: String, arguments: [String]) -> Bool {
        note(([executable] + arguments).joined(separator: " "))
    }
}

struct KillCommandTests {
    @Test func nonRootExitsSixtyFourAndTouchesNothing() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let actions = RecordingActions(euid: 501)
        var output: [String] = []
        let code = try await KillCommand(config: fixture.config(), actions: actions).run(report: { output.append($0) })
        #expect(code == 64)
        #expect(actions.steps.isEmpty)
        #expect(output.first?.contains("root") == true)
    }

    @Test func rootRunsTheOrderedPlan() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let actions = RecordingActions(euid: 0)
        let code = try await KillCommand(config: fixture.config(), actions: actions).run(report: { _ in })
        #expect(code == 0)
        #expect(actions.steps == [
            "tailscale funnel --https=443 off", "systemctl stop notetaker-remote",
            "rm tokens.sqlite", "rm tokens.sqlite-wal", "rm tokens.sqlite-shm",
            "rm index.sqlite", "wipe replica", "write DISABLED",
        ])
    }

    @Test func aFailingStepIsReportedButTheRestStillRun() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let actions = RecordingActions(euid: 0)
        actions.failing = ["systemctl stop notetaker-remote"]
        var output: [String] = []
        let code = try await KillCommand(config: fixture.config(), actions: actions).run(report: { output.append($0) })
        #expect(code == 1)
        #expect(actions.steps.last == "write DISABLED")
        #expect(output.contains { $0.contains("systemctl stop notetaker-remote: FAILED") })
    }

    @Test func liveActionsWipeAReplicaDirectory() throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let live = LiveSystemActions()
        #expect(live.removeContents(of: fixture.replica))
        #expect(live.writeMarker(at: fixture.replica.appendingPathComponent("DISABLED")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.replica.path) == ["DISABLED"])
    }
}
