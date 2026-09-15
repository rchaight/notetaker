import Foundation

/// Small abstraction over UserDefaults so `EditorFontPreferences` can be
/// unit tested against a plain dictionary instead of real UserDefaults. The
/// app passes `UserDefaults.standard`.
public protocol EditorFontStore {
    func get(_ key: String) -> Any?
    func set(_ key: String, _ value: Any)
}

extension UserDefaults: EditorFontStore {
    public func get(_ key: String) -> Any? {
        object(forKey: key)
    }

    public func set(_ key: String, _ value: Any) {
        set(value, forKey: key)
    }
}

/// Per-mode font design + size (Source / Live Preview / Reading — spec 04).
/// Live keeps the pre-existing keys (`editorFontDesign` / `editorFontSize`)
/// because Live is what those always applied to; Source and Reading get
/// their own so all three can diverge. A one-time migration seeds
/// Source/Reading from the legacy shared size and the old
/// `sourceModeMonospace` toggle, then that toggle is never read again.
public enum EditorFontPreferences {
    public static let minSize: CGFloat = 11
    public static let maxSize: CGFloat = 28
    public static let defaultSize: CGFloat = 16
    public static let defaultDesign = "system"

    /// "system" | "serif" | "rounded" | "mono" — the vocabulary
    /// `MarkdownTheme.systemDesign` and `ReadingStyle`'s design mapping
    /// both switch on. Anything else falls back to `defaultDesign`.
    private static let validDesigns: Set<String> = ["system", "serif", "rounded", "mono"]

    /// The legacy shared toggle — read only by `migrateIfNeeded`, never by
    /// `resolve`. Left in the store untouched after migration runs.
    private static let legacyMonospaceKey = "sourceModeMonospace"

    /// UserDefaults key names, not @AppStorage bindings — callers bind with
    /// `@AppStorage(EditorFontPreferences.keys(for: .source).design)`.
    public static func keys(for mode: EditorMode) -> (design: String, size: String) {
        switch mode {
        case .source: ("sourceFontDesign", "sourceFontSize")
        case .live: ("editorFontDesign", "editorFontSize")
        case .reading: ("readingFontDesign", "readingFontSize")
        }
    }

    /// The design a per-row Reset restores. Source resets to the legacy
    /// monospace default (matching `migrateIfNeeded`'s true/absent case);
    /// Live and Reading reset to the shared default.
    public static func resetDesign(for mode: EditorMode) -> String {
        mode == .source ? "mono" : defaultDesign
    }

    public static func clamp(_ size: CGFloat) -> CGFloat {
        min(max(size, minSize), maxSize)
    }

    /// Reads a mode's current design + size, clamping the size and falling
    /// back to defaults for anything unset or unrecognized.
    public static func resolve(mode: EditorMode, store: EditorFontStore) -> (design: String, size: CGFloat) {
        let (designKey, sizeKey) = keys(for: mode)
        let rawDesign = store.get(designKey) as? String ?? defaultDesign
        let design = validDesigns.contains(rawDesign) ? rawDesign : defaultDesign
        let rawSize = store.get(sizeKey) as? Double ?? Double(defaultSize)
        return (design, clamp(CGFloat(rawSize)))
    }

    /// Runs once, safe to call on every launch: if `sourceFontDesign` is
    /// already set this is a no-op, so a second run changes nothing.
    public static func migrateIfNeeded(store: EditorFontStore) {
        let sourceKeys = keys(for: .source)
        guard store.get(sourceKeys.design) == nil else { return }

        let liveKeys = keys(for: .live)
        let liveDesign = store.get(liveKeys.design) as? String ?? defaultDesign
        let liveSize = store.get(liveKeys.size) as? Double ?? Double(defaultSize)

        // true or absent (nil) -> mono; explicit false -> Live's design.
        let monospaceToggle = store.get(legacyMonospaceKey) as? Bool ?? true
        store.set(sourceKeys.design, monospaceToggle ? "mono" : liveDesign)
        store.set(sourceKeys.size, liveSize)

        let readingKeys = keys(for: .reading)
        store.set(readingKeys.design, liveDesign)
        store.set(readingKeys.size, liveSize)
    }
}
