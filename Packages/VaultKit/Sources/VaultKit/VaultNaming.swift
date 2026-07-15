import Foundation

/// Overwrite-safe file naming. A name is taken when the file exists on
/// disk OR as an undownloaded iCloud placeholder (".Name.md.icloud") —
/// in-memory listings miss placeholders, and clobbering a remote note
/// destroys data on every synced device.
public enum VaultNaming {
    public static func isTaken(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// First free "Base.ext", "Base 2.ext", "Base 3.ext"… in `folder`,
    /// also honoring `reserved` relative paths (the caller's in-memory
    /// listing, which can know about files disk doesn't show yet).
    public static func uniqueFileName(
        base: String, ext: String, in folder: URL, reserved: Set<String> = []
    ) -> String {
        func taken(_ name: String) -> Bool {
            reserved.contains(name) || isTaken(folder.appendingPathComponent(name))
        }
        var name = "\(base).\(ext)"
        var counter = 2
        while taken(name) {
            name = "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }
}
