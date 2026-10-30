import CryptoKit
import Darwin
import Foundation
import MarkdownKit
import os

/// What the Mac tells the remote replica about the image it just built
/// (design 00 §4.1). Pushed last; spec 06 reads the same type.
public struct ReplicaManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let policyVersion: Int
    public let disabled: Bool
    public let noteCount: Int
    /// `.locked` + `.lockedEnvelope` + `.unclosedFrontmatterWithLockKey`.
    public let lockedExcludedCount: Int
    /// `.indexFile`.
    public let indexExcludedCount: Int
    /// Every other reason: policy exclusions, symlinks, hard links, oversize,
    /// unreadable, unstable, case/normalization collisions, hidden files.
    public let otherExcludedCount: Int
    /// iCloud placeholders (`.Name.icloud`, dataless files) — skipped unread.
    public let notDownloadedCount: Int
    public let calendarIncluded: Bool
    public let files: [Entry]
    public let filesDigest: String
    public let appVersion: String?

    /// sha256 over `"\(path.utf8.count):\(path)\n\(sha256)\n"` for each entry, in
    /// order. The byte-length prefix makes the framing unambiguous even for
    /// a path containing a newline (the exporter also refuses such names).
    public static func digest(of entries: [Entry]) -> String {
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data("\(entry.path.utf8.count):\(entry.path)\n\(entry.sha256)\n".utf8))
        }
        return ReplicaExporter.hex(hasher.finalize())
    }
}

/// Builds the remote replica image on the Mac, in a non-iCloud staging
/// directory (design 00 §3, §4.1, §4.6, spec 03).
///
/// This is the last line before notes leave the Mac, so it FAILS CLOSED and
/// does not trust the filesystem between steps:
///
/// - It never follows a symlink (a link can bypass `excludedFolders`), never
///   opens a FIFO/socket/device, and excludes hard-linked files (`nlink > 1`:
///   a second name for a file that may live somewhere the path rules protect).
/// - It never reads, coordinates on, or downloads iCloud placeholders
///   (`.Name.icloud`, or a dataless file flagged `SF_DATALESS`).
/// - Files over `maxFileBytes` are excluded entirely; a file is never read in
///   part.
/// - The bytes that are policy-checked are the very bytes that are written
///   (no String round trip), read through one `O_NOFOLLOW` descriptor whose
///   identity (device/inode/path) is checked against what was enumerated, so
///   a swap between enumeration and read excludes the file.
/// - Paths that collide on a case-insensitive / normalization-insensitive
///   volume are all excluded rather than letting one overwrite the other.
/// - Before the swap, the finished tree is re-scanned against the policy and
///   against the manifest; any difference throws and the previous image is
///   left untouched.
///
/// Reads cannot go through `VaultFileStore.readString` because that API
/// follows symlinks and re-decodes the bytes (so the spec's `fileStore`
/// init parameter was dropped: it would have been unused). Reads are still
/// wrapped in `NSFileCoordinator`, with dataless materialization switched off
/// for the thread so an eviction race fails the open instead of downloading.
public struct ReplicaExporter: Sendable {
    public static let defaultMaxFileBytes = 5 * 1024 * 1024
    static let maxDepth = 64
    public static let maxCalendarBytes = 1024 * 1024

    public struct Result: Sendable, Equatable {
        public let manifest: ReplicaManifest
        public let stagingURL: URL
    }

    public enum ExporterError: Error, Equatable {
        case selfCheckFailed(path: String, reason: ExportExclusionReason)
        case stagingUnavailable(String)
        case calendarRejected(String)
    }

    public struct Violation: Sendable, Equatable {
        public let path: String
        public let reason: ExportExclusionReason
    }

    public struct Verification: Sendable, Equatable {
        public let fileCount: Int
        public let violations: [Violation]
    }

    let root: URL
    let staging: URL
    let policy: ExportPolicy
    let maxFileBytes: Int

    /// Test hooks (internal): called with the relative path just before a
    /// candidate is opened, and with the temp tree just before the self-check.
    var beforeRead: (@Sendable (String) -> Void)?
    var beforeSelfCheck: (@Sendable (URL) -> Void)?

    static let log = Logger(subsystem: "com.rchaight.notetaker", category: "ReplicaExporter")

    public init(
        root: URL,
        staging: URL,
        policy: ExportPolicy,
        maxFileBytes: Int = ReplicaExporter.defaultMaxFileBytes
    ) {
        self.root = root
        self.staging = staging
        self.policy = policy
        self.maxFileBytes = maxFileBytes
    }

    // MARK: - Export

    /// Full rebuild. `calendarSnapshot` is already-encoded JSON from CalendarKit's codec.
    public func export(calendarSnapshot: Data?, appVersion: String? = nil, now: Date = Date()) async throws -> Result {
        let exporter = self
        // Task.detached does not inherit cancellation, so forward it by hand.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try exporter.exportBlocking(
                    calendarSnapshot: calendarSnapshot, appVersion: appVersion, now: now,
                    isCancelled: { cancelled.withLock { $0 } }
                )
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    func exportBlocking(
        calendarSnapshot: Data?, appVersion: String?, now: Date,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Result {
        if let calendarSnapshot {
            try Self.validateCalendar(calendarSnapshot)
        }
        let rootReal = try Self.realPath(root.path, what: "vault root")
        try Self.prepareStagingParent(staging, rootReal: rootReal)
        Self.sweepStale(staging: staging)
        let tmp = Self.sibling(of: staging, tag: "tmp")
        let vaultDir = tmp.appendingPathComponent("vault", isDirectory: true)
        do {
            try Self.makePrivateDirectory(tmp)
            try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            let manifest = try build(
                tmp: tmp, vaultDir: vaultDir, rootReal: rootReal,
                calendarSnapshot: calendarSnapshot, appVersion: appVersion, now: now,
                isCancelled: isCancelled
            )
            if isCancelled() {
                throw CancellationError()
            }
            try Self.swapIn(tmp: tmp, staging: staging)
            return Result(manifest: manifest, stagingURL: staging)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private func build(
        tmp: URL, vaultDir: URL, rootReal: String,
        calendarSnapshot: Data?, appVersion: String?, now: Date,
        isCancelled: @Sendable () -> Bool
    ) throws -> ReplicaManifest {
        var counters = Counters()
        var candidates: [Candidate] = []
        walk(dir: rootReal, relativePrefix: "", depth: 0, counters: &counters, candidates: &candidates)
        candidates.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        candidates = dropCollisions(candidates, counters: &counters)

        var entries: [ReplicaManifest.Entry] = []
        for candidate in candidates {
            if isCancelled() {
                throw CancellationError()
            }
            beforeRead?(candidate.relativePath)
            if isCancelled() {
                throw CancellationError()
            }
            switch readNoFollow(candidate, rootReal: rootReal) {
            case let .failure(why):
                Self.log.notice("skip \(candidate.relativePath, privacy: .private): \(why, privacy: .public)")
                if why == .dataless {
                    counters.notDownloaded += 1
                } else {
                    counters.other += 1
                }
            case let .success(file):
                switch policy.decide(relativePath: candidate.relativePath, contents: file.data) {
                case let .excluded(reason):
                    counters.record(reason)
                case .export:
                    try entries.append(write(file, candidate: candidate, vaultDir: vaultDir))
                }
            }
        }

        let calendarIncluded = calendarSnapshot != nil
        if let calendarSnapshot {
            try calendarSnapshot.write(
                to: tmp.appendingPathComponent("calendar-remote.json"),
                options: .withoutOverwriting
            )
        }

        beforeSelfCheck?(tmp)
        if isCancelled() {
            throw CancellationError()
        }

        // Whole-root allowlist: nothing but the vault tree and the calendar file.
        try Self.checkRootEntries(tmp, allowed: calendarIncluded ? ["vault", "calendar-remote.json"] : ["vault"])

        // Self-check: the tree on disk must be exactly the manifest, and every
        // file must still pass the policy. Anything else -> nothing is swapped.
        let scan = Self.scan(staging: tmp, policy: policy, maxFileBytes: maxFileBytes)
        if let first = scan.verification.violations.first {
            throw ExporterError.selfCheckFailed(path: first.path, reason: first.reason)
        }
        let onDisk = scan.entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        if onDisk != entries {
            let stray = Set(onDisk.map(\.path)).symmetricDifference(entries.map(\.path)).sorted().first
            throw ExporterError.selfCheckFailed(path: stray ?? "manifest", reason: .invalidPath)
        }

        let manifest = ReplicaManifest(
            schemaVersion: ReplicaManifest.schemaVersion,
            generatedAt: now,
            policyVersion: ExportPolicy.version,
            disabled: false,
            noteCount: entries.count,
            lockedExcludedCount: counters.locked,
            indexExcludedCount: counters.index,
            otherExcludedCount: counters.other,
            notDownloadedCount: counters.notDownloaded,
            calendarIncluded: calendarIncluded,
            files: entries,
            filesDigest: ReplicaManifest.digest(of: entries),
            appVersion: appVersion
        )
        try Self.writeManifest(manifest, in: tmp)
        return manifest
    }

    // MARK: - Disabled image

    /// The kill-switch image: only `DISABLED` (empty) and a manifest with `disabled: true`.
    /// `vaultRoot` is needed only for the same staging-overlap check `export` runs.
    public static func writeDisabled(staging: URL, vaultRoot: URL, now: Date = Date()) throws -> ReplicaManifest {
        let rootReal = try realPath(vaultRoot.path, what: "vault root")
        try prepareStagingParent(staging, rootReal: rootReal)
        sweepStale(staging: staging)
        let tmp = sibling(of: staging, tag: "tmp")
        do {
            try makePrivateDirectory(tmp)
            try Data().write(to: tmp.appendingPathComponent("DISABLED"), options: .withoutOverwriting)
            let manifest = ReplicaManifest(
                schemaVersion: ReplicaManifest.schemaVersion,
                generatedAt: now,
                policyVersion: ExportPolicy.version,
                disabled: true,
                noteCount: 0,
                lockedExcludedCount: 0,
                indexExcludedCount: 0,
                otherExcludedCount: 0,
                notDownloadedCount: 0,
                calendarIncluded: false,
                files: [],
                filesDigest: ReplicaManifest.digest(of: []),
                appVersion: nil
            )
            try writeManifest(manifest, in: tmp)
            try checkRootEntries(tmp, allowed: ["DISABLED", "manifest.json"])
            try swapIn(tmp: tmp, staging: staging)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Verify

    /// Walks `staging/vault` and re-applies the policy to every file. Symlinks,
    /// non-regular files, oversize and unreadable files are violations too.
    public static func verify(
        staging: URL, policy: ExportPolicy, maxFileBytes: Int = defaultMaxFileBytes
    ) throws -> Verification {
        scan(staging: staging, policy: policy, maxFileBytes: maxFileBytes).verification
    }

    struct ScanResult {
        var verification: Verification
        var entries: [ReplicaManifest.Entry]
    }

    static func scan(staging: URL, policy: ExportPolicy, maxFileBytes: Int) -> ScanResult {
        var violations: [Violation] = []
        var entries: [ReplicaManifest.Entry] = []
        let vault = staging.appendingPathComponent("vault", isDirectory: true).path
        var info = stat()
        guard lstat(vault, &info) == 0 else {
            return ScanResult(verification: Verification(fileCount: 0, violations: []), entries: [])
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            // `vault` itself a symlink or file: nothing may be served from it.
            return ScanResult(
                verification: Verification(fileCount: 0, violations: [Violation(path: "vault", reason: .invalidPath)]),
                entries: []
            )
        }
        var fileCount = 0
        scanDir(
            vault, prefix: "", depth: 0, policy: policy, maxFileBytes: maxFileBytes,
            fileCount: &fileCount, violations: &violations, entries: &entries
        )
        return ScanResult(verification: Verification(fileCount: fileCount, violations: violations), entries: entries)
    }

    private static func scanDir(
        _ dir: String, prefix: String, depth: Int, policy: ExportPolicy, maxFileBytes: Int,
        fileCount: inout Int, violations: inout [Violation], entries: inout [ReplicaManifest.Entry]
    ) {
        guard depth <= maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            violations.append(Violation(path: prefix.isEmpty ? "vault" : prefix, reason: .invalidPath))
            return
        }
        for name in names.sorted() {
            let path = dir + "/" + name
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else {
                violations.append(Violation(path: rel, reason: .undecodable))
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                scanDir(
                    path, prefix: rel, depth: depth + 1, policy: policy, maxFileBytes: maxFileBytes,
                    fileCount: &fileCount, violations: &violations, entries: &entries
                )
            case S_IFREG:
                fileCount += 1
                guard info.st_size <= maxFileBytes,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                else {
                    violations.append(Violation(path: rel, reason: .undecodable))
                    continue
                }
                if case let .excluded(reason) = policy.decide(relativePath: rel, contents: data) {
                    violations.append(Violation(path: rel, reason: reason))
                } else {
                    entries.append(.init(path: rel, sha256: hex(SHA256.hash(data: data)), bytes: data.count))
                }
            default: // symlink, FIFO, socket, device
                fileCount += 1
                violations.append(Violation(path: rel, reason: .invalidPath))
            }
        }
    }

    // MARK: - Enumeration (lstat-based; never follows links)

    struct Counters {
        var locked = 0
        var index = 0
        var other = 0
        var notDownloaded = 0

        mutating func record(_ reason: ExportExclusionReason) {
            switch reason {
            case .locked, .lockedEnvelope, .unclosedFrontmatterWithLockKey: locked += 1
            case .indexFile: index += 1
            default: other += 1
            }
        }
    }

    struct Candidate {
        let relativePath: String
        let device: dev_t
        let inode: ino_t
    }

    /// `SF_DATALESS`: the file's content is in iCloud only; reading it would
    /// make the OS download it.
    static let dataless: UInt32 = 0x4000_0000

    static func isDataless(flags: UInt32) -> Bool {
        flags & dataless != 0
    }

    private func walk(
        dir: String, relativePrefix: String, depth: Int,
        counters: inout Counters, candidates: inout [Candidate]
    ) {
        guard depth <= Self.maxDepth else {
            counters.other += 1
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            counters.other += 1
            return
        }
        for name in names {
            let path = dir + "/" + name
            let rel = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else {
                counters.other += 1
                continue
            }
            let type = info.st_mode & S_IFMT
            if name.hasPrefix(".") {
                // Hidden. An iCloud placeholder is reported, never touched.
                if type != S_IFDIR {
                    if name.hasSuffix(".icloud") {
                        counters.notDownloaded += 1
                    } else {
                        counters.other += 1
                    }
                }
                continue // hidden directories (.git, .obsidian, .trash) are never entered
            }
            switch type {
            case S_IFDIR:
                walk(dir: path, relativePrefix: rel, depth: depth + 1, counters: &counters, candidates: &candidates)
            case S_IFREG:
                classify(rel: rel, info: info, counters: &counters, candidates: &candidates)
            default: // symlink, FIFO, socket, device: skipped, never opened
                counters.other += 1
            }
        }
    }

    private func classify(rel: String, info: stat, counters: inout Counters, candidates: inout [Candidate]) {
        // A control character (or line/paragraph separator) in any component
        // makes path framing ambiguous; refuse the name outright.
        if Self.hasControlCharacter(rel) {
            counters.other += 1
            return
        }
        // Path gate first: excluded files (folders, _index.md, non-.md) are never read.
        if case let .excluded(reason) = policy.decide(relativePath: rel) {
            counters.record(reason)
            return
        }
        // Defense in depth: the enumeration choke point's own index rule.
        if VaultFileStore.isIndexFile(rel) {
            counters.index += 1
            return
        }
        if Self.isDataless(flags: info.st_flags) {
            counters.notDownloaded += 1
            return
        }
        if info.st_nlink != 1 || info.st_size > maxFileBytes {
            counters.other += 1
            return
        }
        candidates.append(Candidate(relativePath: rel, device: info.st_dev, inode: info.st_ino))
    }

    /// Case-/normalization-insensitive duplicates: exclude every member.
    func dropCollisions(_ candidates: [Candidate], counters: inout Counters) -> [Candidate] {
        var groups: [String: Int] = [:]
        for candidate in candidates {
            groups[Self.collisionKey(candidate.relativePath), default: 0] += 1
        }
        var kept: [Candidate] = []
        for candidate in candidates {
            if groups[Self.collisionKey(candidate.relativePath), default: 0] > 1 {
                counters.other += 1
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }

    static func hasControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .uppercased().lowercased()
    }

    // MARK: - Reading

    struct FileBytes {
        let data: Data
        let modified: Date
    }

    private func readNoFollow(_ candidate: Candidate, rootReal: String) -> Swift.Result<FileBytes, ReadFailure> {
        let url = URL(fileURLWithPath: rootReal + "/" + candidate.relativePath)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Swift.Result<FileBytes, ReadFailure> = .failure(.coordination)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            outcome = readDescriptor(at: actual.path, candidate: candidate, rootReal: rootReal)
        }
        return coordinationError == nil ? outcome : .failure(.coordination)
    }

    enum ReadFailure: String, Error {
        case coordination, open, notRegular, identityChanged, pathChanged, hardLinked, dataless, oversize, unstable,
             readError
    }

    private func readDescriptor(
        at path: String, candidate: Candidate, rootReal: String
    ) -> Swift.Result<FileBytes, ReadFailure> {
        // With materialization off, opening a file evicted since the lstat
        // fails (EDEADLK) instead of making the OS download it.
        let fd = Self.withoutMaterializing { open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { return .failure(errno == EDEADLK ? .dataless : .open) }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegular) }
        guard before.st_dev == candidate.device,
              before.st_ino == candidate.inode else { return .failure(.identityChanged) }
        guard before.st_nlink == 1 else { return .failure(.hardLinked) }
        guard !Self.isDataless(flags: before.st_flags) else { return .failure(.dataless) }
        guard before.st_size <= maxFileBytes else { return .failure(.oversize) }
        guard Self.descriptorPath(fd, matches: rootReal, relativePath: candidate.relativePath) else {
            return .failure(.pathChanged) // an ancestor was swapped for a link
        }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Self
                .withoutMaterializing { chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) } }
            if count < 0 {
                return .failure(.readError)
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: chunk[0 ..< count])
            if data.count > maxFileBytes {
                return .failure(.oversize)
            } // never a partial read
        }

        var after = stat()
        guard fstat(fd, &after) == 0,
              after.st_size == data.count,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else { return .failure(.unstable) }

        let seconds = TimeInterval(before.st_mtimespec.tv_sec) + TimeInterval(before.st_mtimespec.tv_nsec) / 1e9
        return .success(FileBytes(data: data, modified: Date(timeIntervalSince1970: seconds)))
    }

    /// True when the kernel's resolved path for `fd` is `rootReal/relativePath`
    /// (root prefix compared case-insensitively, the rest canonically exact).
    static func descriptorPath(_ fd: Int32, matches rootReal: String, relativePath: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return false }
        let actual = cPath(buffer).precomposedStringWithCanonicalMapping
        let rootPart = rootReal.precomposedStringWithCanonicalMapping
        let relPart = "/" + relativePath.precomposedStringWithCanonicalMapping
        guard actual.count == rootPart.count + relPart.count else { return false }
        let split = actual.index(actual.startIndex, offsetBy: rootPart.count)
        return actual[..<split].compare(rootPart, options: [.caseInsensitive]) == .orderedSame
            && actual[split...] == relPart
    }

    // MARK: - Writing

    private func write(_ file: FileBytes, candidate: Candidate, vaultDir: URL) throws -> ReplicaManifest.Entry {
        let destination = vaultDir.appendingPathComponent(candidate.relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try file.data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: destination.path)
        return .init(
            path: candidate.relativePath,
            sha256: Self.hex(SHA256.hash(data: file.data)),
            bytes: file.data.count
        )
    }

    static func writeManifest(_ manifest: ReplicaManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .withoutOverwriting
        )
    }

    static func cPath(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Staging plumbing

    static func realPath(_ path: String, what: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { throw ExporterError.stagingUnavailable("\(what) not found") }
        return cPath(buffer)
    }

    static func sibling(of staging: URL, tag: String) -> URL {
        staging.deletingLastPathComponent()
            .appendingPathComponent("\(staging.lastPathComponent).\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Runs `body` with dataless-file materialization disabled for this thread
    /// and restores the previous policy afterwards. Darwin/macOS only; elsewhere
    /// (iOS Simulator builds) it is a plain call, as the exporter only runs on macOS.
    static func withoutMaterializing<T>(_ body: () -> T) -> T {
        #if os(macOS)
            let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                IOPOL_SCOPE_THREAD,
                IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            )
            defer {
                if previous >= 0 {
                    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
                }
            }
            return body()
        #else
            return body()
        #endif
    }

    static func validateCalendar(_ data: Data) throws {
        guard data.count <= maxCalendarBytes else {
            throw ExporterError.calendarRejected("calendar snapshot over \(maxCalendarBytes) bytes")
        }
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw ExporterError.calendarRejected("calendar snapshot is not valid JSON")
        }
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    /// The tree must contain exactly these top-level names (and no links).
    static func checkRootEntries(_ dir: URL, allowed: Set<String>) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where !allowed.contains(name) {
            throw ExporterError.selfCheckFailed(path: name, reason: .invalidPath)
        }
        for name in allowed where name != "vault" {
            var info = stat()
            if lstat(dir.appendingPathComponent(name).path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
                throw ExporterError.selfCheckFailed(path: name, reason: .invalidPath)
            }
        }
    }

    /// Realpath of the nearest existing ancestor plus the not-yet-existing tail.
    static func resolvedTarget(_ staging: URL) throws -> String {
        var current = staging.standardizedFileURL.path
        var tail: [String] = []
        var info = stat()
        while lstat(current, &info) != 0 {
            guard current != "/", current.contains("/") else {
                throw ExporterError.stagingUnavailable("staging path has no existing ancestor")
            }
            tail.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty {
                current = "/"
            }
        }
        var base = try realPath(current, what: "staging ancestor")
        if base == "/" {
            base = ""
        }
        return ([base] + tail).joined(separator: "/")
    }

    /// Refuses a staging location inside the vault, containing it, or inside an
    /// iCloud container, BEFORE anything is created; then creates the parent.
    static func prepareStagingParent(_ staging: URL, rootReal: String) throws {
        let target = try resolvedTarget(staging).lowercased()
        let vault = rootReal.lowercased()
        if target == vault || target.hasPrefix(vault + "/") || vault.hasPrefix(target + "/") {
            throw ExporterError.stagingUnavailable("staging overlaps the vault")
        }
        if target.contains("/library/mobile documents/") || target.hasSuffix("/library/mobile documents")
            || target.contains("/library/cloudstorage/") {
            throw ExporterError.stagingUnavailable("staging is inside an iCloud/cloud-synced location")
        }
        do {
            try FileManager.default.createDirectory(
                at: staging.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw ExporterError.stagingUnavailable("cannot create staging parent: \(error.localizedDescription)")
        }
    }

    /// Removes `<name>.tmp-<uuid>` / `<name>.old-<uuid>` siblings (exactly that
    /// pattern, nothing else): leftovers of a killed or failed export hold a
    /// full plaintext copy of the vault.
    public static func sweepStale(staging: URL) {
        let parent = staging.deletingLastPathComponent()
        let name = staging.lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for entry in entries {
            for tag in ["tmp", "old"] {
                let prefix = "\(name).\(tag)-"
                if entry.hasPrefix(prefix), UUID(uuidString: String(entry.dropFirst(prefix.count))) != nil {
                    try? FileManager.default.removeItem(at: parent.appendingPathComponent(entry))
                }
            }
        }
    }

    /// `staging` -> `staging.old-<uuid>`, `tmp` -> `staging`, delete old. A
    /// crash between the renames leaves no `staging`; the next export rebuilds.
    static func swapIn(tmp: URL, staging: URL) throws {
        let fm = FileManager.default
        let old = sibling(of: staging, tag: "old")
        var existing = stat()
        let hadOld = lstat(staging.path, &existing) == 0
        do {
            if hadOld {
                try fm.moveItem(at: staging, to: old)
            }
            try fm.moveItem(at: tmp, to: staging)
        } catch {
            if hadOld {
                try? fm.moveItem(at: old, to: staging)
            }
            throw ExporterError.stagingUnavailable("swap failed: \(error.localizedDescription)")
        }
        if hadOld {
            try? fm.removeItem(at: old)
        }
        sweepStale(staging: staging)
    }
}
