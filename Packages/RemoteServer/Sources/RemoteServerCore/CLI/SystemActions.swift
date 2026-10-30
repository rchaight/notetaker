import Foundation

/// Every destructive step `kill` takes, behind a seam so tests can verify the
/// ordered plan without running systemctl or deleting anything.
public protocol SystemActions: Sendable {
    func effectiveUserID() -> UInt32
    /// Best-effort; returns whether it succeeded.
    func removeFile(at url: URL) -> Bool
    func removeContents(of directory: URL) -> Bool
    /// Removes every direct child of `directory` whose name starts with `prefix` (a missing directory is success).
    func removeFiles(in directory: URL, withPrefix prefix: String) -> Bool
    func writeMarker(at url: URL) -> Bool
    func run(_ executable: String, arguments: [String]) -> Bool
}

public struct LiveSystemActions: SystemActions {
    public init() {}

    public func effectiveUserID() -> UInt32 {
        geteuid()
    }

    public func removeFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    public func removeContents(of directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return true }
        var ok = true
        for name in names {
            if (try? fileManager.removeItem(at: directory.appendingPathComponent(name))) == nil {
                ok = false
            }
        }
        return ok
    }

    public func removeFiles(in directory: URL, withPrefix prefix: String) -> Bool {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return true }
        var ok = true
        for name in names where name.hasPrefix(prefix) {
            if (try? fileManager.removeItem(at: directory.appendingPathComponent(name))) == nil {
                ok = false
            }
        }
        return ok
    }

    public func writeMarker(at url: URL) -> Bool {
        (try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )) != nil && FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )
    }

    public func run(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
