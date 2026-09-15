@testable import EditorKit
import Foundation
import Testing

/// In-memory stand-in for UserDefaults so these tests never touch real
/// prefs and can construct any starting state precisely.
private final class DictionaryStore: EditorFontStore {
    var values: [String: Any] = [:]

    func get(_ key: String) -> Any? {
        values[key]
    }

    func set(_ key: String, _ value: Any) {
        values[key] = value
    }
}

struct EditorFontPreferencesTests {
    // MARK: - Keys per mode

    @Test func keysAreDistinctPerModeAndLiveKeepsTheLegacyNames() {
        #expect(EditorFontPreferences.keys(for: .source) == (design: "sourceFontDesign", size: "sourceFontSize"))
        #expect(EditorFontPreferences.keys(for: .live) == (design: "editorFontDesign", size: "editorFontSize"))
        #expect(EditorFontPreferences.keys(for: .reading) == (design: "readingFontDesign", size: "readingFontSize"))
    }

    // MARK: - Defaults + clamping

    @Test func resolveDefaultsWhenUnset() {
        let store = DictionaryStore()
        let resolved = EditorFontPreferences.resolve(mode: .reading, store: store)
        #expect(resolved.design == "system")
        #expect(resolved.size == 16)
    }

    @Test func resolveClampsBelowTheMinimum() {
        let store = DictionaryStore()
        store.set("editorFontSize", 4.0)
        let resolved = EditorFontPreferences.resolve(mode: .live, store: store)
        #expect(resolved.size == EditorFontPreferences.minSize)
    }

    @Test func resolveClampsAboveTheMaximum() {
        let store = DictionaryStore()
        store.set("sourceFontSize", 99.0)
        let resolved = EditorFontPreferences.resolve(mode: .source, store: store)
        #expect(resolved.size == EditorFontPreferences.maxSize)
    }

    @Test func resolveFallsBackToSystemForAnUnknownDesignString() {
        let store = DictionaryStore()
        store.set("readingFontDesign", "comic-sans")
        let resolved = EditorFontPreferences.resolve(mode: .reading, store: store)
        #expect(resolved.design == "system")
    }

    // MARK: - Migration

    @Test func migrationSeedsSourceToMonoWhenLegacyToggleIsTrue() {
        let store = DictionaryStore()
        store.set("sourceModeMonospace", true)
        EditorFontPreferences.migrateIfNeeded(store: store)
        #expect(store.get("sourceFontDesign") as? String == "mono")
    }

    @Test func migrationSeedsSourceToMonoWhenLegacyToggleIsAbsent() {
        let store = DictionaryStore()
        EditorFontPreferences.migrateIfNeeded(store: store)
        #expect(store.get("sourceFontDesign") as? String == "mono")
    }

    @Test func migrationSeedsSourceToLivesDesignWhenLegacyToggleIsFalse() {
        let store = DictionaryStore()
        store.set("sourceModeMonospace", false)
        store.set("editorFontDesign", "serif")
        EditorFontPreferences.migrateIfNeeded(store: store)
        #expect(store.get("sourceFontDesign") as? String == "serif")
    }

    @Test func migrationCopiesSizesFromLive() {
        let store = DictionaryStore()
        store.set("editorFontSize", 20.0)
        store.set("editorFontDesign", "rounded")
        EditorFontPreferences.migrateIfNeeded(store: store)
        #expect(store.get("sourceFontSize") as? Double == 20.0)
        #expect(store.get("readingFontSize") as? Double == 20.0)
        #expect(store.get("readingFontDesign") as? String == "rounded")
    }

    @Test func migrationIsIdempotent() {
        let store = DictionaryStore()
        store.set("sourceModeMonospace", false)
        store.set("editorFontDesign", "serif")
        store.set("editorFontSize", 20.0)
        EditorFontPreferences.migrateIfNeeded(store: store)

        // Change what a second run would seed from — a real second run
        // must still be a no-op because sourceFontDesign is already set.
        store.set("editorFontDesign", "mono")
        store.set("editorFontSize", 12.0)
        EditorFontPreferences.migrateIfNeeded(store: store)

        #expect(store.get("sourceFontDesign") as? String == "serif")
        #expect(store.get("sourceFontSize") as? Double == 20.0)
        #expect(store.get("readingFontDesign") as? String == "serif")
        #expect(store.get("readingFontSize") as? Double == 20.0)
    }

    @Test func resolveAfterMigrationReturnsTheSeededValues() {
        let store = DictionaryStore()
        store.set("sourceModeMonospace", true)
        store.set("editorFontSize", 18.0)
        EditorFontPreferences.migrateIfNeeded(store: store)

        let source = EditorFontPreferences.resolve(mode: .source, store: store)
        #expect(source.design == "mono")
        #expect(source.size == 18)

        let reading = EditorFontPreferences.resolve(mode: .reading, store: store)
        #expect(reading.design == "system")
        #expect(reading.size == 18)
    }

    // MARK: - Reset design

    @Test func resetDesignIsMonospacedForSourceAndSystemElsewhere() {
        #expect(EditorFontPreferences.resetDesign(for: .source) == "mono")
        #expect(EditorFontPreferences.resetDesign(for: .live) == "system")
        #expect(EditorFontPreferences.resetDesign(for: .reading) == "system")
    }
}
