import Foundation

/// A concurrent-edit version of a file that iCloud could not merge.
public struct ConflictVersion: Sendable, Equatable, Identifiable {
    /// The version's contents path — stable and unique per version, so SwiftUI can list them.
    public let id: String
    public let contentsURL: URL
    public let modificationDate: Date?
    public let deviceName: String?

    public init(contentsURL: URL, modificationDate: Date?, deviceName: String?) {
        id = contentsURL.path
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

/// Abstracts NSFileVersion so resolution logic is testable with plain files (NSFileVersion
/// conflict versions cannot be fabricated in a temp dir).
public protocol ConflictVersionSource: Sendable {
    /// Unresolved conflict versions of `url`, in any order.
    func unresolvedVersions(for url: URL) -> [ConflictVersion]
    /// Marks one version resolved (it stops counting as a conflict).
    func markResolved(_ version: ConflictVersion, of url: URL) throws
    /// Prunes the version store of everything but the current file.
    func removeOtherVersions(of url: URL) throws
}

/// The real source: iCloud's `NSFileVersion` conflict versions.
public struct FileVersionSource: ConflictVersionSource {
    public init() {}

    public func unresolvedVersions(for url: URL) -> [ConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            ConflictVersion(
                contentsURL: $0.url,
                modificationDate: $0.modificationDate,
                deviceName: $0.localizedNameOfSavingComputer
            )
        }
    }

    public func markResolved(_ version: ConflictVersion, of url: URL) throws {
        let match = (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [])
            .first { $0.url.path == version.id }
        match?.isResolved = true
    }

    public func removeOtherVersions(of url: URL) throws {
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

/// How to settle a conflicted file.
public enum ConflictResolution: Sendable, Equatable {
    /// This device's file wins; every conflict version is marked resolved.
    case keepCurrent
    /// That version's bytes replace the file.
    case keepVersion(ConflictVersion)
    /// Every conflict version is kept as its own clearly named sibling file.
    case keepBoth
}

public struct ConflictOutcome: Sendable, Equatable {
    /// Sibling files written by `.keepBoth` (empty for the other strategies).
    public let preserved: [URL]
    /// How many conflict versions were marked resolved.
    public let resolved: Int

    public init(preserved: [URL], resolved: Int) {
        self.preserved = preserved
        self.resolved = resolved
    }
}

/// Detection + resolution of iCloud conflicts. All file writes go through `VaultFileStore`
/// (coordinated); the version bookkeeping goes through the injected `ConflictVersionSource`.
/// Nothing is ever resolved before the winning bytes are safely on disk.
public struct VaultConflictCenter: Sendable {
    private let source: any ConflictVersionSource

    public init(source: any ConflictVersionSource = FileVersionSource()) {
        self.source = source
    }

    /// Unresolved iCloud conflict versions for a file (empty when in sync), oldest first,
    /// then by device name — a stable order, so the sheet and keep-both naming are repeatable.
    public func unresolvedVersions(for url: URL) -> [ConflictVersion] {
        source.unresolvedVersions(for: url).sorted(by: Self.isOrderedBefore)
    }

    /// Settles every unresolved version of `url` the way `resolution` says. With no
    /// unresolved versions this is a no-op. `.keepVersion` fails closed: if reading that
    /// version or writing the file throws, nothing is marked resolved and the error rethrows.
    public func resolve(
        _ resolution: ConflictResolution, at url: URL, store: VaultFileStore
    ) async throws -> ConflictOutcome {
        let versions = unresolvedVersions(for: url)
        guard !versions.isEmpty else { return ConflictOutcome(preserved: [], resolved: 0) }

        var preserved: [URL] = []
        switch resolution {
        case .keepCurrent:
            break
        case let .keepVersion(chosen):
            // Bytes first: only a successful write may mark anything resolved.
            let contents = try await store.readString(at: chosen.contentsURL)
            try await store.writeString(contents, to: url)
        case .keepBoth:
            let directory = url.deletingLastPathComponent()
            var existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            for version in versions {
                let name = ConflictNaming.keepBothName(
                    original: url.lastPathComponent,
                    device: version.deviceName,
                    date: version.modificationDate,
                    existing: existing
                )
                let destination = directory.appendingPathComponent(name)
                try await store.copy(from: version.contentsURL, to: destination)
                try source.markResolved(version, of: url)
                existing.insert(name)
                preserved.append(destination)
            }
            // Versions are marked as they are preserved; the rest is cosmetic pruning.
            try? source.removeOtherVersions(of: url)
            return ConflictOutcome(preserved: preserved, resolved: versions.count)
        }

        for version in versions {
            try source.markResolved(version, of: url)
        }
        try? source.removeOtherVersions(of: url)
        return ConflictOutcome(preserved: preserved, resolved: versions.count)
    }

    /// Keep-both resolution for the debug harness: forwards to `resolve(.keepBoth)`. Returns
    /// the URLs of the preserved copies.
    public func resolveKeepingBoth(at url: URL, store: VaultFileStore) async throws -> [URL] {
        try await resolve(.keepBoth, at: url, store: store).preserved
    }

    /// Oldest first (undated last), then device name (unnamed last), then path.
    private static func isOrderedBefore(_ lhs: ConflictVersion, _ rhs: ConflictVersion) -> Bool {
        if lhs.modificationDate != rhs.modificationDate {
            return (lhs.modificationDate ?? .distantFuture) < (rhs.modificationDate ?? .distantFuture)
        }
        if lhs.deviceName != rhs.deviceName {
            switch (lhs.deviceName, rhs.deviceName) {
            case let (left?, right?): return left.localizedStandardCompare(right) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return lhs.id < rhs.id
    }
}
