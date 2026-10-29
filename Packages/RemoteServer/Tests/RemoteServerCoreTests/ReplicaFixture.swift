import Foundation
import MCP
@testable import RemoteServerCore

let lockedSentinel = "SENTINEL-LOCKED-9f3a"

/// A replica directory built in code, the way the Mac's exporter + rsync would
/// leave it: `vault/*.md`, optional `calendar-remote.json`, and a consistent
/// `manifest.json` (hashes and digest computed here).
struct ReplicaFixture {
    let root: URL
    let replica: URL
    let state: URL
    let auditURL: URL

    /// The MCPKit `VaultFixture` notes the exporter would ship (no `_index.md`, no locked).
    static let notes: [String: String] = [
        "CLAUDE.md": "# Notetaker vault\nRead the notes before guessing.\n",
        "Inbox.md": """
        # Inbox
        - [ ] book the accreditation site visit >2026-08-25 !p1 #accreditation @dana
        """,
        "Work/Curriculum.md": """
        ---
        area: Curriculum
        ---
        # Curriculum redesign

        The pharmacology thread needs a spiral structure so students revisit
        drug mechanisms in every year of the program.

        - [ ] draft the spiral map >2026-08-22 !p2 #curriculum @dana ?discuss
        - [x] collect the old syllabi ✅2026-08-01 #curriculum
        """,
        "Daily/2026-08-20.md": """
        # 2026-08-20

        - [ ] email the dean about budget >2026-09-30 @dean ?waiting
        """,
    ]

    /// What a failed exporter would leak: LF and CRLF locked notes (with a task
    /// line, so a leaking task scanner would show it) plus an `_index.md`.
    static let contamination: [String: String] = [
        "Work/Locked.md": "---\nlocked: true\n---\n\(lockedSentinel) U2FsdGVkX1+cipher\n- [ ] \(lockedSentinel) secret task >2026-08-30\n",
        "Work/LockedCRLF.md": "---\r\nlocked: true\r\n---\r\n\(lockedSentinel) U2FsdGVkX1+cipher\r\n- [ ] \(lockedSentinel) crlf task >2026-08-30\r\n",
        "_index.md": "# Vault\n- generated table of contents\n",
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-server-\(UUID().uuidString)", isDirectory: true)
        replica = root.appendingPathComponent("replica", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        auditURL = root.appendingPathComponent("audit.jsonl")
        try FileManager.default.createDirectory(at: replica, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var environment: [String: String] {
        [
            "NR_PUBLIC_URL": "https://nr-test.ts.net",
            "NR_REPLICA_DIR": replica.path,
            "NR_STATE_DIR": state.path,
            "NR_AUDIT_LOG": auditURL.path,
            "NR_BIND": "127.0.0.1:0",
        ]
    }

    func config(extra: [String: String] = [:]) throws -> RemoteConfig {
        try RemoteConfig(environment: environment.merging(extra) { _, new in new })
    }

    /// Replaces the whole replica image. `tamper` rewrites a file AFTER the
    /// manifest recorded its hash (a half-finished push).
    @discardableResult
    func push(
        notes: [String: String] = ReplicaFixture.notes,
        generatedAt: Date = Date(timeIntervalSince1970: 1_787_000_000),
        disabled: Bool = false,
        tamper: [String: String] = [:],
        stray: [String: String] = [:],
        calendar: Data? = nil
    ) throws -> ReplicaManifest {
        let fileManager = FileManager.default
        for name in try fileManager.contentsOfDirectory(atPath: replica.path) {
            try fileManager.removeItem(at: replica.appendingPathComponent(name))
        }
        let vault = replica.appendingPathComponent("vault", isDirectory: true)
        var entries: [ReplicaManifest.Entry] = []
        if !disabled {
            for (path, contents) in notes.sorted(by: { $0.key < $1.key }) {
                let url = vault.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(contents.utf8)
                try data.write(to: url)
                entries.append(.init(path: path, sha256: Hashing.sha256Hex(data), bytes: data.count))
            }
        }
        for (path, contents) in tamper.merging(stray, uniquingKeysWith: { $1 }) {
            let url = vault.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        if let calendar {
            try calendar.write(to: replica.appendingPathComponent("calendar-remote.json"))
        }
        let manifest = ReplicaManifest(
            generatedAt: generatedAt, disabled: disabled,
            calendarIncluded: calendar != nil, files: entries, appVersion: "test"
        )
        try manifest.encoded().write(to: replica.appendingPathComponent("manifest.json"))
        return manifest
    }

    /// A watcher that has already evaluated the current replica.
    func readyWatcher(audit: AuditLog? = nil) async throws -> ReplicaWatcher {
        let watcher = try ReplicaWatcher(config: config(), audit: audit)
        await watcher.tick()
        return watcher
    }
}

/// A fixed snapshot for gateway tests that do not need a real replica.
struct StubReplica: ReplicaProviding {
    let snapshot: ReplicaSnapshot

    func current() async -> ReplicaSnapshot {
        snapshot
    }
}

/// Test-only: authenticates everybody. Must never exist in the library target.
struct AllowAllAuthenticator: BearerAuthenticator {
    func authenticate(authorizationHeader _: String?) async -> AuthResult {
        .authenticated(AuthenticatedPrincipal(clientID: "test-client", tokenFamily: "test-family"))
    }
}

/// Every text and structured string in a tool result, for "does X appear anywhere" checks.
func everything(in result: CallTool.Result) -> String {
    var parts: [String] = []
    for item in result.content {
        if case let .text(text, _, _) = item {
            parts.append(text)
        }
    }
    if let structured = result.structuredContent {
        parts.append(ToolGateway.compactJSON(structured))
    }
    return parts.joined(separator: "\n")
}

extension Value {
    subscript(key: String) -> Value? {
        objectValue?[key]
    }
}
