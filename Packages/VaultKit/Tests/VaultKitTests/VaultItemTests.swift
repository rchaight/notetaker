import Foundation
import Testing
@testable import VaultKit

struct DownloadStateMapping {
    @Test func notDownloadedStatusMaps() {
        #expect(VaultItem.DownloadState(
            ubiquitousStatus: NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        ) == .notDownloaded)
    }

    @Test func downloadedStatusMaps() {
        #expect(VaultItem.DownloadState(
            ubiquitousStatus: NSMetadataUbiquitousItemDownloadingStatusDownloaded
        ) == .downloaded)
    }

    @Test func currentStatusMaps() {
        #expect(VaultItem.DownloadState(
            ubiquitousStatus: NSMetadataUbiquitousItemDownloadingStatusCurrent
        ) == .current)
    }

    @Test func missingStatusMeansLocalAndCurrent() {
        #expect(VaultItem.DownloadState(ubiquitousStatus: nil) == .current)
    }
}

struct RelativePaths {
    let root = URL(fileURLWithPath: "/vault/root", isDirectory: true)

    @Test func childFile() {
        let url = URL(fileURLWithPath: "/vault/root/Inbox/note.md")
        #expect(VaultPath.relativePath(of: url, in: root) == "Inbox/note.md")
    }

    @Test func rootItselfIsEmpty() {
        #expect(VaultPath.relativePath(of: root, in: root) == "")
    }

    @Test func outsideRootFallsBackToAbsolute() {
        let url = URL(fileURLWithPath: "/elsewhere/note.md")
        #expect(VaultPath.relativePath(of: url, in: root) == "/elsewhere/note.md")
    }

    @Test func standardizesDotSegments() {
        let url = URL(fileURLWithPath: "/vault/root/Inbox/../Projects/plan.md")
        #expect(VaultPath.relativePath(of: url, in: root) == "Projects/plan.md")
    }

    @Test func relativePathIsStableIdentity() {
        let item = VaultItem(
            url: URL(fileURLWithPath: "/vault/root/a.md"),
            relativePath: "a.md",
            isDirectory: false,
            modificationDate: nil,
            downloadState: .current
        )
        #expect(item.id == "a.md")
    }
}
