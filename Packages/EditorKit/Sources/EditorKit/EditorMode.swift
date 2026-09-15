/// How the open note is shown. Three modes, Obsidian's vocabulary:
/// Source is strict markdown, Live Preview hides syntax off the caret line,
/// Reading is the rendered read-only view (ReadingKit). The packages know
/// nothing about "modes" — EditorKit still takes `livePreview: Bool`.
///
/// Lives in EditorKit (moved from the App target in spec 04) so both
/// SettingsView and NotesView — which already import EditorKit — and
/// `EditorFontPreferences` can share one definition. Raw values are
/// unchanged: the persisted `editorMode` @AppStorage value still decodes.
public enum EditorMode: String, CaseIterable, Sendable {
    case source, live, reading

    /// ⌘E order: Source → Live → Reading → Source.
    public var next: EditorMode {
        switch self {
        case .source: .live
        case .live: .reading
        case .reading: .source
        }
    }

    public var isEditing: Bool {
        self != .reading
    }

    public var symbol: String {
        switch self {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .live: "eye"
        case .reading: "book"
        }
    }

    public var title: String {
        switch self {
        case .source: "Source"
        case .live: "Live Preview"
        case .reading: "Reading"
        }
    }
}
