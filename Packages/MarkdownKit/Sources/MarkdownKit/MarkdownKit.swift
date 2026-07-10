import Markdown

/// MarkdownKit — parsing/AST layer over swift-markdown; fleshed out in M2.
public enum MarkdownKitInfo {
    public static let name = "MarkdownKit"

    /// Smoke-level proof that swift-markdown is linked: count top-level
    /// block children of a parsed document.
    public static func blockCount(of markdown: String) -> Int {
        Document(parsing: markdown).childCount
    }
}
