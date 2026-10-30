import CryptoKit
import Foundation
import MarkdownKit
import SecurityKit
import Testing
@testable import VaultKit

/// The leak tests are the contract: sentinel plaintext goes through real
/// `LockedNoteFile` envelopes and must never appear anywhere under staging.
private final class Fixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let stagingParent: URL
    let staging: URL
    /// Base64 ciphertext strings of the locked notes, for leak assertions.
    private(set) var ciphertexts: [String] = []
    private var sentinelCount = 0
    private let key: SymmetricKey
    private let salt: Data

    static let rounds = 1000

    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "ReplicaExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        root = base.appendingPathComponent("vault", isDirectory: true)
        stagingParent = base.appendingPathComponent("export", isDirectory: true)
        staging = stagingParent.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        salt = NoteCrypto.makeSalt()
        key = try NoteCrypto.deriveKey(passphrase: "pw", salt: salt, rounds: Self.rounds)
    }

    deinit {
        // Restore any chmod 000 files so cleanup works.
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: base)
    }

    func url(_ rel: String) -> URL {
        root.appendingPathComponent(rel)
    }

    func put(_ rel: String, _ text: String) throws {
        try put(rel, Data(text.utf8))
    }

    func put(_ rel: String, _ data: Data) throws {
        let dest = url(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    /// A real SecurityKit envelope around a sentinel plaintext.
    @discardableResult
    func putLocked(_ rel: String, crlf: Bool = false) throws -> String {
        sentinelCount += 1
        let plaintext = "SENTINEL-LOCKED-9f3a-\(sentinelCount)"
        let sealed = try NoteCrypto.encrypt(plaintext, key: key)
        ciphertexts.append(sealed.base64EncodedString())
        var rendered = LockedNoteFile.render(title: "t", salt: salt, rounds: Self.rounds, ciphertext: sealed)
        if crlf {
            rendered = rendered.replacingOccurrences(of: "\n", with: "\r\n")
        }
        try put(rel, rendered)
        return plaintext
    }

    /// The spec's fixture.
    func populate() throws {
        for index in 0 ..< 5 {
            try put("Note\(index).md", "# Note \(index)\nbody \(index)\n")
        }
        for index in 0 ..< 5 {
            try put("Work/W\(index).md", "---\ntitle: W\(index)\ntags: [a]\n---\nwork \(index)\n")
        }
        for index in 0 ..< 5 {
            try put("Work/Curriculum/C\(index).md", "# C\(index)\ncurriculum\n")
        }
        for index in 0 ..< 3 {
            try put("Daily/2026-10-0\(index + 1).md", "- [ ] task \(index) >today\n")
        }
        try put("Daily/crlf.md", "---\r\ntitle: crlf\r\n---\r\nbody\r\n")
        try put("Daily/mentions-lock.md", "# Mentions\nlocked: true\nis just text in a body\n")
        try put("Daily/mention-two.md", "# Two\nsalt: abc and rounds: 5 in prose\n")
        try putLocked("Secret.md")
        try putLocked("Work/Curriculum/Secret2.md")
        try putLocked("Daily/Secret3.md", crlf: true)
        try put("_index.md", "# toc\n- [[Secret]]\n")
        try put("Work/_index.md", "# toc\n")
        try put(".DS_Store", "junk")
        try put(".Hidden.md.icloud", "")
        try put("notes.txt", "not markdown")
        try put("CLAUDE.md", "# Vault guide\n")
        try put("Work Notes/Personnel/eval.md", "# Eval\nPERSONNEL-SECRET\n")
        try put("Private/opt-out.md", "---\nremote: false\n---\nOPT-OUT-SECRET\n")
    }

    func exporter(
        policy: ExportPolicy = ExportPolicy(),
        maxFileBytes: Int = ReplicaExporter.defaultMaxFileBytes
    ) -> ReplicaExporter {
        ReplicaExporter(root: root, staging: staging, policy: policy, maxFileBytes: maxFileBytes)
    }

    var stagedVault: URL {
        staging.appendingPathComponent("vault", isDirectory: true)
    }

    /// Every entry under `dir` (hidden included), relative paths, files only.
    func files(under dir: URL) -> [String] {
        var result: [String] = []
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        let prefix = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
            result.append(String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count)))
        }
        return result.sorted()
    }

    func staged(_ rel: String) -> String? {
        try? String(contentsOf: stagedVault.appendingPathComponent(rel), encoding: .utf8)
    }

    func stagedExists(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: stagedVault.appendingPathComponent(rel).path)
    }

    func stagingSiblings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stagingParent.path)) ?? []).sorted()
    }

    /// path -> sha256+mtime, for "the exporter never writes inside root".
    func rootSnapshot() -> [String: String] {
        var result: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let data = (info.st_mode & S_IFMT == S_IFREG) ? ((try? Data(contentsOf: url)) ?? Data()) : Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            result[url.path] = "\(digest) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_mode)"
        }
        return result
    }
}

struct ReplicaExporterTests {
    // MARK: Spec tests 1-13

    @Test func nothingLockedLeaves() async throws {
        let fx = try Fixture()
        try fx.populate()
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(result.manifest.lockedExcludedCount == 3)
        #expect(result.manifest.noteCount > 0)

        var bodyMention = 0
        for rel in fx.files(under: fx.stagedVault) {
            let text = try #require(fx.staged(rel))
            #expect(!text.contains("SENTINEL-LOCKED-9f3a"), "\(rel)")
            for ciphertext in fx.ciphertexts {
                #expect(!text.contains(ciphertext), "\(rel)")
            }
            #expect(!ExportPolicy.looksLocked(text), "\(rel)")
            if text.contains("locked: true") {
                // The one ordinary note that merely mentions it in body prose.
                #expect(rel == "Daily/mentions-lock.md")
                bodyMention += 1
            }
        }
        #expect(bodyMention == 1)
        // Raw-bytes sweep too (not just UTF-8 text).
        for rel in fx.files(under: fx.staging) {
            let data = try Data(contentsOf: fx.staging.appendingPathComponent(rel))
            for ciphertext in fx.ciphertexts {
                #expect(data.range(of: Data(ciphertext.utf8)) == nil, "\(rel)")
            }
            #expect(data.range(of: Data("SENTINEL-LOCKED-9f3a".utf8)) == nil, "\(rel)")
        }
    }

    @Test func noAppFiles() async throws {
        let fx = try Fixture()
        try fx.populate()
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        let files = fx.files(under: fx.stagedVault)
        #expect(!files.contains { $0.split(separator: "/").last.map(String.init)?.lowercased() == "_index.md" })
        #expect(!files.contains { $0.split(separator: "/").contains { $0.hasPrefix(".") } })
        #expect(!files.contains("notes.txt"))
        #expect(result.manifest.indexExcludedCount == 2)
        #expect(files.contains("CLAUDE.md"))
    }

    @Test func countsAndDigestAndCamelCaseDecode() async throws {
        let fx = try Fixture()
        try fx.populate()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try await fx.exporter().export(calendarSnapshot: nil, appVersion: "9.9", now: fixedNow)
        let manifest = result.manifest
        let onDisk = fx.files(under: fx.stagedVault)
        #expect(manifest.noteCount == manifest.files.count)
        #expect(manifest.files.count == onDisk.count)
        #expect(manifest.files.map(\.path) == manifest.files.map(\.path)
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        for entry in manifest.files {
            let data = try Data(contentsOf: fx.stagedVault.appendingPathComponent(entry.path))
            #expect(entry.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            #expect(entry.bytes == data.count)
        }
        var hasher = SHA256()
        for entry in manifest.files {
            hasher.update(data: Data("\(entry.path.utf8.count):\(entry.path)\n\(entry.sha256)\n".utf8))
        }
        #expect(manifest.filesDigest == hasher.finalize().map { String(format: "%02x", $0) }.joined())

        let json = try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json"))
        let text = try #require(String(data: json, encoding: .utf8))
        for key in [
            "schemaVersion",
            "generatedAt",
            "policyVersion",
            "lockedExcludedCount",
            "filesDigest",
            "notDownloadedCount",
        ] {
            #expect(text.contains("\"\(key)\""))
        }
        #expect(!text.contains("schema_version"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplicaManifest.self, from: json)
        #expect(decoded == manifest)
        #expect(decoded.policyVersion == ExportPolicy.version)
        #expect(decoded.appVersion == "9.9")
        #expect(!decoded.disabled)
    }

    @Test func convergenceBothDirections() async throws {
        let fx = try Fixture()
        try fx.populate()
        let exporter = fx.exporter()
        #expect(try await exporter.export(calendarSnapshot: nil).manifest.lockedExcludedCount == 3)
        #expect(!fx.stagedExists("Secret.md"))

        try fx.put("Secret.md", "# Unlocked now\n")
        let second = try await exporter.export(calendarSnapshot: nil)
        #expect(second.manifest.lockedExcludedCount == 2)
        #expect(fx.stagedExists("Secret.md"))

        try fx.putLocked("Note0.md")
        let third = try await exporter.export(calendarSnapshot: nil)
        #expect(third.manifest.lockedExcludedCount == 3)
        #expect(!fx.stagedExists("Note0.md"))
        #expect(fx.stagedExists("Secret.md"))
    }

    @Test func scopeLevers() async throws {
        let fx = try Fixture()
        try fx.populate()
        let open = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(fx.stagedExists("Work Notes/Personnel/eval.md"))
        #expect(!fx.stagedExists("Private/opt-out.md"))

        let scoped = try await fx.exporter(policy: ExportPolicy(excludedFolders: ["Work Notes/Personnel"]))
            .export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Work Notes/Personnel/eval.md"))
        #expect(!fx.stagedExists("Private/opt-out.md"))
        #expect(scoped.manifest.otherExcludedCount == open.manifest.otherExcludedCount + 1)
        #expect(scoped.manifest.noteCount == open.manifest.noteCount - 1)
    }

    @Test func calendarPassthrough() async throws {
        let fx = try Fixture()
        try fx.populate()
        let bytes = Data("{\"schemaVersion\":1}".utf8)
        let with = try await fx.exporter().export(calendarSnapshot: bytes)
        #expect(with.manifest.calendarIncluded)
        #expect(try Data(contentsOf: fx.staging.appendingPathComponent("calendar-remote.json")) == bytes)
        let without = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!without.manifest.calendarIncluded)
        #expect(!FileManager.default.fileExists(atPath: fx.staging.appendingPathComponent("calendar-remote.json").path))
    }

    @Test func mtimePreserved() async throws {
        let fx = try Fixture()
        try fx.populate()
        let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fx.url("Note1.md").path)
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        let attrs = try FileManager.default
            .attributesOfItem(atPath: fx.stagedVault.appendingPathComponent("Note1.md").path)
        let staged = try #require(attrs[.modificationDate] as? Date)
        #expect(abs(staged.timeIntervalSince(old)) < 1)
    }

    @Test func atomicSwapRebuildsAndNeverWritesInsideRoot() async throws {
        let fx = try Fixture()
        try fx.populate()
        let before = fx.rootSnapshot()
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        try Data("planted".utf8).write(to: fx.stagedVault.appendingPathComponent("zzz.md"))
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("zzz.md"))
        #expect(fx.stagingSiblings() == ["staging"])
        #expect(fx.rootSnapshot() == before)
    }

    @Test func stagingInsideOrAroundVaultIsRefused() async throws {
        let fx = try Fixture()
        try fx.populate()
        let inside = ReplicaExporter(
            root: fx.root,
            staging: fx.root.appendingPathComponent("Sub/staging"),
            policy: ExportPolicy()
        )
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await inside.export(calendarSnapshot: nil) }
        let around = ReplicaExporter(root: fx.root, staging: fx.base, policy: ExportPolicy())
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await around.export(calendarSnapshot: nil) }
    }

    @Test func verifyFlagsContamination() throws {
        let fx = try Fixture()
        let vault = fx.stagedVault
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("a/b"),
            withIntermediateDirectories: true
        )
        try Data("ok\n".utf8).write(to: vault.appendingPathComponent("ok.md"))
        try fx.putLocked("tmp.md")
        try FileManager.default.moveItem(at: fx.url("tmp.md"), to: vault.appendingPathComponent("a/locked.md"))
        try Data("toc".utf8).write(to: vault.appendingPathComponent("a/b/_index.md"))
        let result = try ReplicaExporter.verify(staging: fx.staging, policy: ExportPolicy())
        #expect(result.fileCount == 3)
        #expect(result.violations.count == 2)
        #expect(result.violations.contains(.init(path: "a/locked.md", reason: .lockedEnvelope))
            || result.violations.contains(.init(path: "a/locked.md", reason: .locked)))
        #expect(result.violations.contains(.init(path: "a/b/_index.md", reason: .indexFile)))
    }

    @Test func verifyFlagsSymlinksHiddenOversizeAndNonUTF8() throws {
        let fx = try Fixture()
        let vault = fx.stagedVault
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: vault.appendingPathComponent("real.md"))
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("link.md"),
            withDestinationURL: vault.appendingPathComponent("real.md")
        )
        try Data("x".utf8).write(to: vault.appendingPathComponent(".hidden.md"))
        try Data(repeating: 0x61, count: 200).write(to: vault.appendingPathComponent("big.md"))
        try Data([0xFF, 0xFE, 0x00]).write(to: vault.appendingPathComponent("bin.md"))
        let result = try ReplicaExporter.verify(staging: fx.staging, policy: ExportPolicy(), maxFileBytes: 100)
        let paths = Set(result.violations.map(\.path))
        #expect(paths == ["link.md", ".hidden.md", "big.md", "bin.md"])
    }

    @Test func selfCheckRefusesContaminatedOutputAndKeepsPreviousImage() async throws {
        let fx = try Fixture()
        try fx.populate()
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        let previous = try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json"))
        let previousFiles = fx.files(under: fx.staging)

        let sentinel = try fx.putLocked("Late.md")
        let leaked = try Data(contentsOf: fx.url("Late.md"))
        try FileManager.default.removeItem(at: fx.url("Late.md"))
        var contaminated = fx.exporter()
        contaminated.beforeSelfCheck = { tmp in
            try? leaked.write(to: tmp.appendingPathComponent("vault/Leak.md"))
        }
        await #expect {
            try await contaminated.export(calendarSnapshot: nil)
        } throws: { error in
            guard case let .selfCheckFailed(path, reason) = error as? ReplicaExporter.ExporterError
            else { return false }
            return path == "Leak.md" && [.locked, .lockedEnvelope].contains(reason)
        }
        #expect(try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json")) == previous)
        #expect(fx.files(under: fx.staging) == previousFiles)
        #expect(fx.stagingSiblings() == ["staging"])
        #expect(fx.staged("Leak.md") == nil)
        _ = sentinel

        // A plain (policy-clean) file that is not in the manifest is refused too.
        var stray = fx.exporter()
        stray.beforeSelfCheck = { tmp in
            try? Data("sneaky".utf8).write(to: tmp.appendingPathComponent("vault/Stray.md"))
        }
        await #expect {
            try await stray.export(calendarSnapshot: nil)
        } throws: { error in
            error as? ReplicaExporter.ExporterError == .selfCheckFailed(path: "Stray.md", reason: .invalidPath)
        }
        #expect(fx.stagingSiblings() == ["staging"])

        // A symlink planted into the tree is refused.
        var linked = fx.exporter()
        linked.beforeSelfCheck = { tmp in
            try? FileManager.default.createSymbolicLink(
                at: tmp.appendingPathComponent("vault/Link.md"), withDestinationURL: fx.url("Note0.md")
            )
        }
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await linked.export(calendarSnapshot: nil) }
        #expect(fx.stagingSiblings() == ["staging"])
    }

    @Test func disabledImageAndRestore() async throws {
        let fx = try Fixture()
        try fx.populate()
        _ = try await fx.exporter().export(calendarSnapshot: Data("{}".utf8))
        let manifest = try ReplicaExporter.writeDisabled(staging: fx.staging, vaultRoot: fx.root)
        #expect(fx.files(under: fx.staging) == ["DISABLED", "manifest.json"])
        #expect(try Data(contentsOf: fx.staging.appendingPathComponent("DISABLED")).isEmpty)
        #expect(manifest.disabled && manifest.noteCount == 0 && manifest.files.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ReplicaManifest.self,
            from: Data(contentsOf: fx.staging.appendingPathComponent("manifest.json"))
        )
        #expect(decoded.disabled && decoded.files.isEmpty && !decoded.calendarIncluded)
        #expect(fx.stagingSiblings() == ["staging"])

        let restored = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!restored.manifest.disabled && restored.manifest.noteCount > 0)
        #expect(!FileManager.default.fileExists(atPath: fx.staging.appendingPathComponent("DISABLED").path))
    }

    @Test func placeholderIsCountedAndUntouched() async throws {
        let fx = try Fixture()
        try fx.populate()
        try fx.put("Work/.Evicted.md.icloud", "placeholder-bytes")
        let before = try FileManager.default.attributesOfItem(atPath: fx.url(".Hidden.md.icloud").path)
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(result.manifest.notDownloadedCount == 2)
        #expect(!fx.stagedExists(".Hidden.md.icloud"))
        #expect(!fx.stagedExists("Work/.Evicted.md.icloud"))
        let after = try FileManager.default.attributesOfItem(atPath: fx.url(".Hidden.md.icloud").path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(try String(contentsOf: fx.url("Work/.Evicted.md.icloud"), encoding: .utf8) == "placeholder-bytes")
    }

    @Test func datalessFlagIsRecognised() {
        #expect(ReplicaExporter.isDataless(flags: 0x4000_0000))
        #expect(ReplicaExporter.isDataless(flags: 0x4000_0001))
        #expect(!ReplicaExporter.isDataless(flags: 0))
        #expect(!ReplicaExporter.isDataless(flags: 0x0000_0020))
    }

    @Test func indexFileNameParity() {
        #expect(ExportPolicy.indexFileName == VaultFileStore.indexFileName)
    }

    // MARK: Adversarial

    @Test func symlinkedDirectoryToExcludedFolderDoesNotBypassTheRule() async throws {
        let fx = try Fixture()
        try fx.populate()
        try FileManager.default.createSymbolicLink(
            atPath: fx.url("Innocent").path, withDestinationPath: "Work Notes/Personnel"
        )
        try FileManager.default.createSymbolicLink(
            atPath: fx.url("Abs").path, withDestinationPath: fx.url("Work Notes/Personnel").path
        )
        try FileManager.default.createSymbolicLink(atPath: fx.url("loop").path, withDestinationPath: ".")
        let result = try await fx.exporter(policy: ExportPolicy(excludedFolders: ["Work Notes/Personnel"]))
            .export(calendarSnapshot: nil)
        for rel in fx.files(under: fx.staging) {
            let data = try Data(contentsOf: fx.staging.appendingPathComponent(rel))
            #expect(data.range(of: Data("PERSONNEL-SECRET".utf8)) == nil, "\(rel)")
        }
        #expect(!fx.stagedExists("Innocent/eval.md"))
        #expect(!fx.stagedExists("Abs/eval.md"))
        #expect(!fx.stagedExists("loop/Note0.md"))
        #expect(result.manifest.otherExcludedCount >= 3)
    }

    @Test func symlinkedFilesAreNeverExported() async throws {
        let fx = try Fixture()
        try fx.populate()
        let outside = fx.base.appendingPathComponent("outside-secret.md")
        try Data("OUTSIDE-SECRET\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: fx.url("ToOutside.md").path,
            withDestinationPath: outside.path
        )
        try FileManager.default.createSymbolicLink(atPath: fx.url("ToInside.md").path, withDestinationPath: "Note0.md")
        try FileManager.default.createSymbolicLink(atPath: fx.url("Dangling.md").path, withDestinationPath: "nope.md")
        // A link whose target is a LOCKED note: content would be refused anyway; still never opened.
        try FileManager.default.createSymbolicLink(atPath: fx.url("ToLocked.md").path, withDestinationPath: "Secret.md")
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        for rel in ["ToOutside.md", "ToInside.md", "Dangling.md", "ToLocked.md"] {
            #expect(!fx.stagedExists(rel))
        }
        #expect(fx.stagedExists("Note0.md"))
        for rel in fx.files(under: fx.staging) {
            #expect(try Data(contentsOf: fx.staging.appendingPathComponent(rel))
                .range(of: Data("OUTSIDE-SECRET".utf8)) == nil)
        }
        // Everything staged is a regular file.
        var info = stat()
        for rel in fx.files(under: fx.stagedVault) {
            #expect(lstat(fx.stagedVault.appendingPathComponent(rel).path, &info) == 0 && info
                .st_mode & S_IFMT == S_IFREG)
        }
    }

    @Test func hardLinkedFilesAreExcluded() async throws {
        let fx = try Fixture()
        try fx.populate()
        // Personnel note hard-linked to an innocuous path; plain note linked twice.
        try FileManager.default.linkItem(at: fx.url("Work Notes/Personnel/eval.md"), to: fx.url("Public-copy.md"))
        try FileManager.default.linkItem(at: fx.url("Note2.md"), to: fx.url("Note2-alias.md"))
        let result = try await fx.exporter(policy: ExportPolicy(excludedFolders: ["Work Notes/Personnel"]))
            .export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Public-copy.md"))
        #expect(!fx.stagedExists("Note2.md"))
        #expect(!fx.stagedExists("Note2-alias.md"))
        #expect(result.manifest.otherExcludedCount >= 4)
    }

    @Test func hardLinkedLockedNoteStaysHome() async throws {
        let fx = try Fixture()
        try fx.populate()
        try FileManager.default.linkItem(at: fx.url("Secret.md"), to: fx.url("Renamed-plain.md"))
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Renamed-plain.md"))
        for rel in fx.files(under: fx.staging) {
            let data = try Data(contentsOf: fx.staging.appendingPathComponent(rel))
            for ciphertext in fx.ciphertexts {
                #expect(data.range(of: Data(ciphertext.utf8)) == nil)
            }
        }
    }

    @Test func oversizeFileIsExcludedEntirely() async throws {
        let fx = try Fixture()
        try fx.put("Small.md", "tiny\n")
        try fx.put("AtCap.md", "# t\n" + String(repeating: "a ", count: 497) + "\n\n")
        try fx.put("OverByOne.md", "# t\n" + String(repeating: "a ", count: 497) + "\n\n\n")
        try fx.put("Huge.md", "HUGE-HEAD\n" + String(repeating: "b", count: 50000))
        let result = try await fx.exporter(maxFileBytes: 1000).export(calendarSnapshot: nil)
        #expect(fx.stagedExists("Small.md") && fx.stagedExists("AtCap.md"))
        #expect(!fx.stagedExists("OverByOne.md") && !fx.stagedExists("Huge.md"))
        #expect(result.manifest.noteCount == 2)
        #expect(result.manifest.otherExcludedCount == 2)
    }

    @Test func fileGrowingHugeAfterEnumerationIsExcluded() async throws {
        let fx = try Fixture()
        try fx.put("Grows.md", "small\n")
        try fx.put("Stays.md", "ok\n")
        var exporter = fx.exporter(maxFileBytes: 1000)
        let target = fx.url("Grows.md")
        exporter.beforeRead = { rel in
            if rel == "Grows.md" {
                try? Data(repeating: 0x61, count: 5000).write(to: target)
            }
        }
        let result = try await exporter.export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Grows.md") && fx.stagedExists("Stays.md"))
        #expect(result.manifest.otherExcludedCount == 1)
    }

    @Test func fileLockedAfterEnumerationIsJudgedOnWhatWasRead() async throws {
        let fx = try Fixture()
        try fx.put("Becomes.md", "plain at enumeration\n")
        let planted = try fx.putLocked("scratch.md")
        let envelope = try Data(contentsOf: fx.url("scratch.md"))
        try FileManager.default.removeItem(at: fx.url("scratch.md"))
        var exporter = fx.exporter()
        let target = fx.url("Becomes.md")
        exporter.beforeRead = { rel in
            if rel == "Becomes.md" {
                try? envelope.write(to: target)
            }
        }
        let result = try await exporter.export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Becomes.md"))
        #expect(result.manifest.lockedExcludedCount == 1)
        _ = planted
    }

    @Test func fileSwappedForSymlinkAfterEnumerationIsNotRead() async throws {
        let fx = try Fixture()
        try fx.put("Swapped.md", "plain\n")
        let outside = fx.base.appendingPathComponent("outside.md")
        try Data("OUTSIDE-SECRET\n".utf8).write(to: outside)
        var exporter = fx.exporter()
        let target = fx.url("Swapped.md")
        exporter.beforeRead = { rel in
            guard rel == "Swapped.md" else { return }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        let result = try await exporter.export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Swapped.md"))
        #expect(result.manifest.noteCount == 0)
        #expect(result.manifest.otherExcludedCount == 1)
    }

    @Test func fileReplacedByOtherInodeAfterEnumerationIsExcluded() async throws {
        let fx = try Fixture()
        try fx.put("Replaced.md", "plain\n")
        var exporter = fx.exporter()
        let target = fx.url("Replaced.md")
        exporter.beforeRead = { rel in
            guard rel == "Replaced.md" else { return }
            try? FileManager.default.removeItem(at: target)
            try? Data("different file, same name\n".utf8).write(to: target)
        }
        let result = try await exporter.export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Replaced.md"))
        #expect(result.manifest.otherExcludedCount == 1)
    }

    @Test func directorySwappedForSymlinkToExcludedFolderAfterEnumerationIsNotRead() async throws {
        let fx = try Fixture()
        try fx.put("Work/a.md", "work note\n")
        try fx.put("Work Notes/Personnel/a.md", "PERSONNEL-SECRET\n")
        var exporter = fx.exporter(policy: ExportPolicy(excludedFolders: ["Work Notes/Personnel"]))
        let work = fx.url("Work")
        let moved = fx.url("Work-moved")
        let personnel = fx.url("Work Notes/Personnel")
        exporter.beforeRead = { rel in
            guard rel == "Work/a.md" else { return }
            try? FileManager.default.moveItem(at: work, to: moved)
            try? FileManager.default.createSymbolicLink(at: work, withDestinationURL: personnel)
        }
        _ = try await exporter.export(calendarSnapshot: nil)
        for rel in fx.files(under: fx.staging) {
            #expect(try Data(contentsOf: fx.staging.appendingPathComponent(rel))
                .range(of: Data("PERSONNEL-SECRET".utf8)) == nil)
        }
        #expect(!fx.stagedExists("Work/a.md"))
    }

    @Test func nonUTF8AndNULFilesAreExcluded() async throws {
        let fx = try Fixture()
        try fx.put("Latin1.md", Data([0x48, 0xE9, 0x6C, 0x6C, 0x6F, 0xFF]))
        try fx.put("Utf16.md", Data("---\nlocked: true\n---\nx".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        try fx.put("Fine.md", "fine\n")
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(fx.stagedExists("Fine.md") && !fx.stagedExists("Latin1.md") && !fx.stagedExists("Utf16.md"))
        #expect(result.manifest.otherExcludedCount == 2)
    }

    @Test func unreadableFileIsSkippedAndExportContinues() async throws {
        let fx = try Fixture()
        try fx.put("Locked-by-perms.md", "private\n")
        try fx.put("Fine.md", "fine\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fx.url("Locked-by-perms.md").path
        )
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Locked-by-perms.md") && fx.stagedExists("Fine.md"))
        #expect(result.manifest.otherExcludedCount == 1)
    }

    @Test func collidingPathsAreAllExcluded() throws {
        let fx = try Fixture()
        let exporter = fx.exporter()
        func candidate(_ rel: String, _ inode: UInt64) -> ReplicaExporter.Candidate {
            .init(relativePath: rel, device: 1, inode: ino_t(inode))
        }
        var counters = ReplicaExporter.Counters()
        let kept = exporter.dropCollisions([
            candidate("Note.md", 1), candidate("note.md", 2), // case
            candidate("caf\u{E9}.md", 3), candidate("cafe\u{301}.md", 4), // NFC vs NFD
            candidate("Work/A.md", 5), candidate("work/a.md", 6), // folder case
            candidate("Unique.md", 7),
        ], counters: &counters)
        #expect(kept.map(\.relativePath) == ["Unique.md"])
        #expect(counters.other == 6)
    }

    @Test func collidingPathsOnDiskNeverOverwriteEachOther() async throws {
        let fx = try Fixture()
        try fx.put("Fine.md", "fine\n")
        try fx.put("Note.md", "UPPER\n")
        // On a case-insensitive volume the second write replaces the first (one file);
        // on a case-sensitive one both exist and both must be dropped.
        try? fx.put("note.md", "lower\n")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: fx.root.path)
            .filter { $0.lowercased() == "note.md" }
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(fx.stagedExists("Fine.md"))
        if onDisk.count > 1 {
            #expect(!fx.stagedExists("Note.md") && !fx.stagedExists("note.md"))
            #expect(result.manifest.otherExcludedCount >= 2)
        } else {
            #expect(result.manifest.noteCount == 2)
        }
    }

    @Test func excludedTitleInsideExportedNoteIsFineButNeverInIndexFiles() async throws {
        let fx = try Fixture()
        let title = "Personnel Review of Jane Doe"
        try fx.put("Work Notes/Personnel/\(title).md", "# \(title)\nPERSONNEL-SECRET\n")
        try fx.put("Meeting.md", "Discussed [[\(title)]] briefly.\n")
        try fx.put("_index.md", "- [[\(title)]]\n")
        try fx.put("Work Notes/_index.md", "- \(title)\n")
        try fx.put("Work Notes/_Index.md.bak", "- \(title)\n")
        let result = try await fx.exporter(policy: ExportPolicy(excludedFolders: ["Work Notes/Personnel"]))
            .export(calendarSnapshot: nil)
        #expect(try #require(fx.staged("Meeting.md")).contains(title))
        #expect(!fx.stagedExists("_index.md") && !fx.stagedExists("Work Notes/_index.md"))
        #expect(!fx.stagedExists("Work Notes/Personnel/\(title).md"))
        for rel in fx.files(under: fx.staging) where rel != "vault/Meeting.md" && rel != "manifest.json" {
            let text = try String(contentsOf: fx.staging.appendingPathComponent(rel), encoding: .utf8)
            #expect(!text.contains(title), "\(rel)")
        }
        // Titles are not in the manifest either (it holds only exported paths).
        let manifestText = try String(contentsOf: fx.staging.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!manifestText.contains(title))
        #expect(result.manifest.indexExcludedCount == 2)
    }

    @Test func indexFileSpelledInOtherCaseIsExcluded() async throws {
        let fx = try Fixture()
        try fx.put("Sub/_INDEX.md", "- [[secret title]]\n")
        try fx.put("Sub/ok.md", "ok\n")
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(!fx.stagedExists("Sub/_INDEX.md") && fx.stagedExists("Sub/ok.md"))
        #expect(result.manifest.indexExcludedCount == 1)
    }

    @Test func fifoIsNeverOpened() async throws {
        let fx = try Fixture()
        try fx.put("Fine.md", "fine\n")
        #expect(mkfifo(fx.url("Pipe.md").path, 0o644) == 0)
        let result = try await fx.exporter().export(calendarSnapshot: nil) // would hang if opened blocking
        #expect(!fx.stagedExists("Pipe.md") && fx.stagedExists("Fine.md"))
        #expect(result.manifest.otherExcludedCount == 1)
    }

    @Test func lockedNoteRenamedToHiddenOrOddNamesStaysHome() async throws {
        let fx = try Fixture()
        try fx.putLocked("Normal.md")
        try fx.putLocked(".Hidden-locked.md")
        try fx.putLocked("Upper.MD")
        try fx.putLocked("folder/Deep.md", crlf: true)
        // Bare ciphertext with frontmatter stripped.
        try fx.put("Stripped.md", fx.ciphertexts[0] + "\n")
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(fx.files(under: fx.stagedVault).isEmpty)
    }

    // MARK: Review round 2

    @Test func overlapRefusalCreatesNothingInsideTheVault() async throws {
        let fx = try Fixture()
        try fx.populate()
        let before = fx.rootSnapshot()
        for target in ["Sub/Deeper/staging", "Sub/staging", "Work/New/staging"] {
            let inside = ReplicaExporter(
                root: fx.root,
                staging: fx.root.appendingPathComponent(target),
                policy: ExportPolicy()
            )
            await #expect(throws: ReplicaExporter.ExporterError.self) { try await inside.export(calendarSnapshot: nil) }
            #expect(throws: ReplicaExporter.ExporterError.self) {
                try ReplicaExporter.writeDisabled(staging: fx.root.appendingPathComponent(target), vaultRoot: fx.root)
            }
            #expect(fx.rootSnapshot() == before)
        }
        // Staging equal to the root, and a symlink that points into the vault.
        let link = fx.base.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.root)
        let viaLink = ReplicaExporter(
            root: fx.root,
            staging: link.appendingPathComponent("NewDir/staging"),
            policy: ExportPolicy()
        )
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await viaLink.export(calendarSnapshot: nil) }
        #expect(throws: ReplicaExporter.ExporterError.self) {
            try ReplicaExporter.writeDisabled(
                staging: link.appendingPathComponent("NewDir/staging"),
                vaultRoot: fx.root
            )
        }
        #expect(fx.rootSnapshot() == before)
        #expect(throws: ReplicaExporter.ExporterError.self) {
            try ReplicaExporter.writeDisabled(staging: fx.base, vaultRoot: fx.root) // contains the vault
        }
        #expect(fx.rootSnapshot() == before)
    }

    @Test func iCloudLocationsAreRefusedForStaging() async throws {
        let fx = try Fixture()
        try fx.populate()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let target = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ReplicaTest/staging")
        let exporter = ReplicaExporter(root: fx.root, staging: target, policy: ExportPolicy())
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await exporter.export(calendarSnapshot: nil) }
        #expect(throws: ReplicaExporter.ExporterError.self) {
            try ReplicaExporter.writeDisabled(staging: target, vaultRoot: fx.root)
        }
        #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    }

    @Test func stagingIsPrivate() async throws {
        let fx = try Fixture()
        try fx.populate()
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: fx.staging.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func staleTempAndOldSiblingsAreSweptAndOthersKept() async throws {
        let fx = try Fixture()
        try fx.populate()
        try FileManager.default.createDirectory(at: fx.stagingParent, withIntermediateDirectories: true)
        let staleTmp = "staging.tmp-\(UUID().uuidString)"
        let staleOld = "staging.old-\(UUID().uuidString)"
        let keep = [
            "staging.tmp-notauuid",
            "staging.other-\(UUID().uuidString)",
            "unrelated",
            "staging.tmp-\(UUID().uuidString).bak",
        ]
        for name in [staleTmp, staleOld] + keep {
            let dir = fx.stagingParent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("PLAINTEXT-COPY".utf8).write(to: dir.appendingPathComponent("x.md"))
        }
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(fx.stagingSiblings() == (["staging"] + keep).sorted())

        // Same for the disabled image.
        for name in [staleTmp, staleOld] {
            try FileManager.default.createDirectory(
                at: fx.stagingParent.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        _ = try ReplicaExporter.writeDisabled(staging: fx.staging, vaultRoot: fx.root)
        #expect(fx.stagingSiblings() == (["staging"] + keep).sorted())
    }

    @Test func selfCheckRejectsStrayEntriesAtTheTreeRoot() async throws {
        let fx = try Fixture()
        try fx.populate()
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        let previous = try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json"))
        let previousFiles = fx.files(under: fx.staging)
        for plant in ["leak.md", "vault2/x.md"] {
            var exporter = fx.exporter()
            exporter.beforeSelfCheck = { tmp in
                let dest = tmp.appendingPathComponent(plant)
                try? FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? Data("clean text".utf8).write(to: dest)
            }
            await #expect(throws: ReplicaExporter.ExporterError.self) {
                try await exporter.export(calendarSnapshot: nil)
            }
            #expect(try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json")) == previous)
            #expect(fx.files(under: fx.staging) == previousFiles)
            #expect(fx.stagingSiblings() == ["staging"])
        }
        // A calendar file is only allowed when one was supplied.
        var sneaky = fx.exporter()
        sneaky
            .beforeSelfCheck = { tmp in
                try? Data("{}".utf8).write(to: tmp.appendingPathComponent("calendar-remote.json"))
            }
        await #expect(throws: ReplicaExporter.ExporterError.self) { try await sneaky.export(calendarSnapshot: nil) }
    }

    @Test func materializationPolicyIsRestoredAfterUse() {
        #if os(macOS)
            let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            let inside = ReplicaExporter.withoutMaterializing {
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            }
            let after = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            #expect(after == before)
        #endif
    }

    @Test func controlCharacterNamesAreExcludedAndDigestIsUnambiguous() async throws {
        let fx = try Fixture()
        try fx.put("Fine.md", "fine\n")
        try fx.put("evil\nname.md", "x\n")
        try fx.put("tab\tname.md", "x\n")
        try fx.put("dir\u{2028}x/inner.md", "x\n")
        let result = try await fx.exporter().export(calendarSnapshot: nil)
        #expect(result.manifest.files.map(\.path) == ["Fine.md"])
        #expect(result.manifest.otherExcludedCount == 3)

        typealias Entry = ReplicaManifest.Entry
        let decode = { (path: String, sha: String, bytes: Int) -> Entry in
            try! JSONDecoder().decode(
                Entry.self,
                from: Data("{\"path\":\(String(reflecting: path).replacingOccurrences(of: "\\n", with: "\\n")),\"sha256\":\"\(sha)\",\"bytes\":\(bytes)}"
                    .utf8)
            )
        }
        // Under the old "path\nsha\n" framing these two sets hashed identically.
        let one = [decode("a\\nSHA1\\nb", "SHA2", 1)]
        let two = [decode("a", "SHA1", 1), decode("b", "SHA2", 1)]
        #expect(ReplicaManifest.digest(of: one) != ReplicaManifest.digest(of: two))
    }

    private static func block(on semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    @Test func cancelledExportLeavesPreviousImageAndCleansUp() async throws {
        let fx = try Fixture()
        try fx.populate()
        _ = try await fx.exporter().export(calendarSnapshot: nil)
        let previous = try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json"))
        let previousFiles = fx.files(under: fx.staging)

        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var exporter = fx.exporter()
        exporter.beforeRead = { rel in
            if rel == "Note0.md" {
                started.signal()
                proceed.wait()
            }
        }
        let running = exporter
        let task = Task { try await running.export(calendarSnapshot: nil) }
        await Task.detached { Self.block(on: started) }.value
        task.cancel()
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fx.staging.appendingPathComponent("manifest.json")) == previous)
        #expect(fx.files(under: fx.staging) == previousFiles)
        #expect(fx.stagingSiblings() == ["staging"])
    }

    @Test func calendarIsCappedAndMustBeJSON() async throws {
        let fx = try Fixture()
        try fx.populate()
        let exporter = fx.exporter()
        let big = Data(("\"" + String(repeating: "a", count: ReplicaExporter.maxCalendarBytes) + "\"").utf8)
        await #expect(throws: ReplicaExporter.ExporterError
            .calendarRejected("calendar snapshot over \(ReplicaExporter.maxCalendarBytes) bytes")) {
            try await exporter.export(calendarSnapshot: big)
        }
        await #expect(throws: ReplicaExporter.ExporterError.calendarRejected("calendar snapshot is not valid JSON")) {
            try await exporter.export(calendarSnapshot: Data("{not json".utf8))
        }
        #expect(fx.stagingSiblings().isEmpty) // refused before anything was created
        let ok = try await exporter.export(calendarSnapshot: Data("{\"schemaVersion\":1}".utf8))
        #expect(ok.manifest.calendarIncluded)
    }
}
