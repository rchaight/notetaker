import Foundation

/// The one rewrite every rename write goes through: the renamed note's own links (NotesModel)
/// and every inbound note's (VaultIndexService). Composes MarkdownKit's tested pieces
/// (`WikilinkSyntax.links/resolve/rewrite`, `MarkdownStyler.codeRanges`). Only link targets
/// change: frontmatter and code spans/blocks are excluded, and so is any link whose title
/// matches but that resolves (the click resolver, from `sourceId`) to a DIFFERENT note.
public enum WikilinkRenameRewrite {
    public static func rewrite(
        _ contents: String, sourceId: String, renamingTitle old: String, to new: String,
        renamedId: String, among notes: [(id: String, title: String)]
    ) -> (text: String, count: Int) {
        let document = MarkdownDocument(source: contents)
        let offset = document.bodyUTF16Offset
        var excluded = MarkdownStyler.codeRanges(in: document.body).map {
            NSRange(location: $0.location + offset, length: $0.length)
        }
        if offset > 0 {
            excluded.append(NSRange(location: 0, length: offset))
        }
        for link in WikilinkSyntax.links(in: contents, excluding: excluded)
            where link.title.compare(old, options: .caseInsensitive) == .orderedSame
            && WikilinkSyntax.resolve(link, among: notes, from: sourceId) != renamedId {
            excluded.append(link.range)
        }
        return WikilinkSyntax.rewrite(contents, renamingTitle: old, to: new, excluding: excluded)
    }
}
