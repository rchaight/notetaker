import AIKit
import Foundation
import IndexKit
import MarkdownKit
import MCPKit

/// Polls the replica directory, and on every COMPLETE push (manifest present,
/// every listed file hash-verified, no stray `.md`, digest recomputed) builds a
/// fresh GRDB index from the files and swaps in a new `VaultService`.
/// A fresh database each time keeps "derived from the files" literally true
/// on the container (design §4.1).
public actor ReplicaWatcher: ReplicaProviding {
    private struct Signature: Equatable {
        let modified: Date?
        let size: Int
    }

    private let config: RemoteConfig
    private let audit: AuditLog?
    private let pollInterval: Duration

    private var state: ReplicaState = .empty
    private var service: VaultService?
    private var servedGeneratedAt: Date?
    private var lastSignature: Signature?
    private var auditedInconsistentFor: Signature?
    private var inconsistentSince: Date?

    public init(config: RemoteConfig, audit: AuditLog? = nil, pollInterval: Duration = .seconds(10)) {
        self.config = config
        self.audit = audit
        self.pollInterval = pollInterval
    }

    public func current() -> ReplicaSnapshot {
        ReplicaSnapshot(state: state, service: service, servedGeneratedAt: servedGeneratedAt)
    }

    /// Runs until cancelled.
    public func run() async {
        removeStaleTemporaryIndexes()
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// One evaluation. A ready or disabled replica whose manifest is unchanged
    /// costs a single `stat`; anything else (inconsistent, failed) retries.
    public func tick() async {
        let signature = Self.signature(of: config.manifestURL)
        let markerPresent = FileManager.default.fileExists(atPath: config.disabledMarkerURL.path)
        if !markerPresent, signature == nil {
            await apply(.empty)
            lastSignature = nil
            return
        }
        if !markerPresent, signature == lastSignature {
            switch state {
            case .ready, .disabled: return
            case .empty, .inconsistent: break
            }
        }
        await evaluate(signature: signature)
    }

    /// Force a rebuild now (the `reindex` subcommand and tests).
    @discardableResult
    public func reindex() async -> ReplicaState {
        lastSignature = nil
        await evaluate(signature: Self.signature(of: config.manifestURL))
        return state
    }

    // MARK: - Evaluation

    private func evaluate(signature: Signature?) async {
        let outcome = ReplicaVerifier(config: config).verify()
        lastSignature = signature
        switch outcome {
        case .empty:
            await apply(.empty)
        case .disabled:
            await apply(.disabled)
        case let .inconsistent(reason):
            await markInconsistent(reason: reason, signature: signature)
        case let .ok(verified):
            await rebuild(verified, signature: signature)
        }
    }

    private func apply(_ target: ReplicaState) async {
        let previous = state
        switch target {
        case .empty:
            dropService()
            state = .empty
        case .disabled:
            dropService()
            try? FileManager.default.removeItem(at: config.indexURL)
            state = .disabled
            if previous != .disabled {
                await audit?.record(AuditEvent(event: "replica.disabled"))
            }
        default:
            state = target
        }
        if case .inconsistent = target {} else {
            inconsistentSince = nil
        }
    }

    private func dropService() {
        service = nil
        servedGeneratedAt = nil
    }

    private func markInconsistent(reason: String, signature: Signature?) async {
        let since = inconsistentSince ?? Date()
        inconsistentSince = since
        state = .inconsistent(since: since)
        // Once per manifest signature, not once per 10 s retry.
        if auditedInconsistentFor != signature || signature == nil {
            auditedInconsistentFor = signature
            await audit?.record(AuditEvent(event: "replica.inconsistent", reason: reason))
        }
    }

    private func rebuild(_ verified: ReplicaVerifier.Verified, signature: Signature?) async {
        let fileManager = FileManager.default
        let temporary = config.stateDir.appendingPathComponent("index.tmp-\(UUID().uuidString).sqlite")
        do {
            try fileManager.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
            try Self.buildIndex(at: temporary, notes: verified.notes)
            // Atomic replace: readers holding the old file keep the old inode.
            guard rename(temporary.path, config.indexURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            await markInconsistent(reason: "index rebuild failed", signature: signature)
            return
        }

        let location = VaultLocation(
            root: config.vaultDir, indexPath: config.indexURL.path, origin: .argument,
            calendarSnapshotPath: config.calendarURL.path
        )
        service = VaultService(location: location, embeddings: NoEmbeddingProvider())
        servedGeneratedAt = verified.manifest.generatedAt
        state = .ready(generatedAt: verified.manifest.generatedAt, manifest: verified.manifest)
        inconsistentSince = nil
        auditedInconsistentFor = nil

        let manifest = verified.manifest
        await audit?.record(AuditEvent(
            event: "replica.ready", resultCount: manifest.noteCount,
            reason: "locked_excluded_count=\(manifest.lockedExcludedCount)"
        ))
        await auditContamination(verified.notes)
    }

    /// Defense in depth: the exporter should never ship these, so seeing one
    /// is an incident worth a line. The files stay served-as-redacted by
    /// MCPKit; `audit-replica` removes them.
    private func auditContamination(_ notes: [ReplicaVerifier.Note]) async {
        let policy = ExportPolicy()
        var reasons: [String: Int] = [:]
        for note in notes {
            if case let .excluded(reason) = policy.decide(relativePath: note.id, contents: note.contents) {
                reasons[reason.rawValue, default: 0] += 1
            }
        }
        guard !reasons.isEmpty else { return }
        let summary = reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        await audit?.record(AuditEvent(
            event: "replica.contaminated", resultCount: reasons.values.reduce(0, +), reason: summary
        ))
    }

    // MARK: - Helpers

    /// Builds in a scope of its own so the database handle is released
    /// (and the file closed) before the caller renames it.
    private static func buildIndex(at url: URL, notes: [ReplicaVerifier.Note]) throws {
        let (database, _) = try IndexDatabase.open(path: url.path)
        try NoteIndexer(database: database).rescan(
            notes: notes.map { (id: $0.id, contents: $0.contents, modifiedAt: $0.modifiedAt) }
        )
    }

    private static func signature(of url: URL) -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Signature(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1
        )
    }

    private func removeStaleTemporaryIndexes() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: config.stateDir.path) else { return }
        for name in names where name.hasPrefix("index.tmp-") {
            try? fileManager.removeItem(at: config.stateDir.appendingPathComponent(name))
        }
    }
}
