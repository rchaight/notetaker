import Foundation
import Testing
@testable import VaultKit

struct ConflictNamingTests {
    @Test func detectsConflictedCopyNames() {
        #expect(ConflictNaming.isConflictedCopyName("Note (conflicted copy).md"))
        #expect(ConflictNaming.isConflictedCopyName("Note (conflicted copy 2).md"))
        #expect(ConflictNaming.isConflictedCopyName("Deep plan (conflicted copy 14).md"))
        #expect(!ConflictNaming.isConflictedCopyName("Note.md"))
        #expect(!ConflictNaming.isConflictedCopyName("Note (copy).md"))
    }

    @Test func extractsOriginalName() {
        #expect(ConflictNaming.originalName(forConflictedCopy: "Note (conflicted copy).md") == "Note.md")
        #expect(ConflictNaming.originalName(forConflictedCopy: "Note (conflicted copy 3).md") == "Note.md")
        #expect(ConflictNaming.originalName(forConflictedCopy: "Plain.md") == nil)
    }

    @Test func keepBothNameIncludesDeviceAndDate() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let name = ConflictNaming.keepBothName(
            original: "Note.md", device: "Robert's iPhone", date: date, existing: []
        )
        #expect(name.hasPrefix("Note (conflict from Robert's iPhone "))
        #expect(name.hasSuffix(").md"))
    }

    @Test func keepBothNameAvoidsCollisions() {
        let first = ConflictNaming.keepBothName(original: "Note.md", device: nil, date: nil, existing: [])
        #expect(first == "Note (conflict).md")
        let second = ConflictNaming.keepBothName(
            original: "Note.md", device: nil, date: nil, existing: [first]
        )
        #expect(second == "Note (conflict 2).md")
    }

    @Test func keepBothNameHandlesNoExtension() {
        let name = ConflictNaming.keepBothName(original: "README", device: nil, date: nil, existing: [])
        #expect(name == "README (conflict)")
    }
}

struct VaultCopyTests {
    @Test func copyPreservesSourceAndContents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let source = root.appendingPathComponent("source.md")

        try await store.writeString("shared history", to: source)
        let destination = root.appendingPathComponent("copies/preserved.md")
        try await store.copy(from: source, to: destination)

        let original = try await store.readString(at: source)
        let copied = try await store.readString(at: destination)
        #expect(original == "shared history")
        #expect(copied == "shared history")
    }

    @Test func unresolvedVersionsEmptyForLocalFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let note = root.appendingPathComponent("local.md")
        try await store.writeString("no conflicts here", to: note)

        let center = VaultConflictCenter()
        #expect(center.unresolvedVersions(for: note).isEmpty)
        let preserved = try await center.resolveKeepingBoth(at: note, store: store)
        #expect(preserved.isEmpty)
    }
}
