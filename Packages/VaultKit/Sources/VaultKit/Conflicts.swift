import Foundation

/// A concurrent-edit version of a file that iCloud could not merge.
public struct ConflictVersion: Sendable, Equatable {
    public let contentsURL: URL
    public let modificationDate: Date?
    public let deviceName: String?

    public init(contentsURL: URL, modificationDate: Date?, deviceName: String?) {
        self.contentsURL = contentsURL
        self.modificationDate = modificationDate
        self.deviceName = deviceName
    }
}

/// Pure naming logic for the two conflict surfaces: iCloud Drive's
/// "* (conflicted copy*)" sibling files, and our own keep-both output names.
public enum ConflictNaming {
    /// Matches "Note (conflicted copy).md", "Note (conflicted copy 2).md",
    /// with or without extension.
    public static func isConflictedCopyName(_ fileName: String) -> Bool {
        originalName(forConflictedCopy: fileName) != nil
    }

    /// "Note (conflicted copy 2).md" → "Note.md"; nil when not a conflicted copy.
    public static func originalName(forConflictedCopy fileName: String) -> String? {
        let pattern = /^(.+) \(conflicted copy(?: [0-9]+)?\)(\.[^.]+)?$/
        guard let match = fileName.wholeMatch(of: pattern) else { return nil }
        return String(match.1) + String(match.2 ?? "")
    }

    /// Name for a preserved conflict version: "Note (conflict from Mac
    /// 2026-07-10 1432).md", suffixed with a counter to avoid collisions.
    public static func keepBothName(
        original: String,
        device: String?,
        date: Date?,
        existing: Set<String>
    ) -> String {
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        var qualifier = "conflict"
        if let device, !device.isEmpty {
            qualifier += " from \(device)"
        }
        if let date {
            qualifier += " \(Self.stamp.string(from: date))"
        }

        func assemble(_ counter: Int) -> String {
            let suffix = counter > 1 ? " \(counter)" : ""
            return ext.isEmpty
                ? "\(base) (\(qualifier)\(suffix))"
                : "\(base) (\(qualifier)\(suffix)).\(ext)"
        }

        var counter = 1
        while existing.contains(assemble(counter)) {
            counter += 1
        }
        return assemble(counter)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()
}

/// Detection + resolution over NSFileVersion. Resolution default is
/// keep-both: every conflicting version becomes its own clearly named file
/// next to the original — never silent data loss.
public struct VaultConflictCenter: Sendable {
    public init() {}

    /// Unresolved iCloud conflict versions for a file (empty when in sync).
    public func unresolvedVersions(for url: URL) -> [ConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            ConflictVersion(
                contentsURL: $0.url,
                modificationDate: $0.modificationDate,
                deviceName: $0.localizedNameOfSavingComputer
            )
        }
    }

    /// Keep-both resolution: copies each conflict version to a sibling file,
    /// marks the versions resolved, and prunes the version store. Returns the
    /// URLs of the preserved copies.
    public func resolveKeepingBoth(at url: URL, store: VaultFileStore) async throws -> [URL] {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !versions.isEmpty else { return [] }

        let directory = url.deletingLastPathComponent()
        var existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        var preserved: [URL] = []

        for version in versions {
            let name = ConflictNaming.keepBothName(
                original: url.lastPathComponent,
                device: version.localizedNameOfSavingComputer,
                date: version.modificationDate,
                existing: existing
            )
            let destination = directory.appendingPathComponent(name)
            try await store.copy(from: version.url, to: destination)
            version.isResolved = true
            existing.insert(name)
            preserved.append(destination)
        }

        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return preserved
    }
}
