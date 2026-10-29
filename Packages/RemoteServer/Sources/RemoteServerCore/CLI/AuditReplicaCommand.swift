import Foundation
import MarkdownKit

/// `notetaker-remote audit-replica`: re-apply the Mac's export policy to every
/// file under `vault/`. Anything the policy would have kept home is deleted
/// (as is any `_index.md`, non-`.md` file, or symlink) and the run exits 2.
public struct AuditReplicaCommand: Sendable {
    public static let contaminated: Int32 = 2

    public let config: RemoteConfig
    public let audit: AuditLog?

    public init(config: RemoteConfig, audit: AuditLog? = nil) {
        self.config = config
        self.audit = audit
    }

    public struct Finding: Sendable, Equatable {
        public let path: String
        public let reason: String
    }

    public func run(report: (String) -> Void) async -> Int32 {
        let findings = scanAndDelete()
        guard !findings.isEmpty else {
            report("audit-replica: clean")
            return 0
        }
        var reasons: [String: Int] = [:]
        for finding in findings {
            reasons[finding.reason, default: 0] += 1
        }
        let summary = reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        report("audit-replica: removed \(findings.count) file(s): \(summary)")
        await audit?.record(AuditEvent(event: "replica.contaminated", resultCount: findings.count, reason: summary))
        return Self.contaminated
    }

    func scanAndDelete() -> [Finding] {
        let fileManager = FileManager.default
        let vault = config.vaultDir.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: vault, includingPropertiesForKeys: nil, options: []
        ) else { return [] }
        let prefix = vault.path + "/"
        let policy = ExportPolicy()
        var findings: [Finding] = []
        var doomed: [(URL, String, String)] = []
        for case let url as URL in enumerator {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let type = attributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                continue
            }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            if type == .typeSymbolicLink {
                doomed.append((url, relative, "symlink"))
            } else if type != .typeRegular {
                doomed.append((url, relative, "notRegularFile"))
            } else if let data = try? Data(contentsOf: url) {
                if case let .excluded(reason) = policy.decide(relativePath: relative, contents: data) {
                    doomed.append((url, relative, reason.rawValue))
                }
            } else {
                doomed.append((url, relative, "unreadable"))
            }
        }
        for (url, relative, reason) in doomed {
            try? fileManager.removeItem(at: url)
            findings.append(Finding(path: relative, reason: reason))
        }
        return findings
    }
}
