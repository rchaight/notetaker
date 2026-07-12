import IndexKit
import MarkdownKit
import SwiftUI

/// Bear/Obsidian-style Info panel: outline of the current note plus its
/// linked backlinks and unlinked mentions — all read straight from the
/// derived index.
struct NoteInspector: View {
    let noteId: String
    let noteTitle: String
    let noteText: String
    let service: VaultIndexService
    let onJump: (NSRange) -> Void
    let onOpen: (String) -> Void

    private var headings: [(level: Int, text: String, range: NSRange)] {
        MarkdownStyler.styleRanges(in: noteText).compactMap { styled in
            guard case let .heading(level) = styled.kind,
                  NSMaxRange(styled.range) <= (noteText as NSString).length
            else { return nil }
            let raw = (noteText as NSString).substring(with: styled.range)
            let text = raw.drop { $0 == "#" || $0 == " " }
            return (level, String(text), styled.range)
        }
    }

    var body: some View {
        List {
            Section("Outline") {
                if headings.isEmpty {
                    Text("No headings").foregroundStyle(.tertiary)
                }
                ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                    Button {
                        onJump(heading.range)
                    } label: {
                        Text(heading.text)
                            .padding(.leading, CGFloat(heading.level - 1) * 12)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Backlinks") {
                let linked = service.backlinks(toTitle: noteTitle)
                if linked.isEmpty {
                    Text("No notes link here").foregroundStyle(.tertiary)
                }
                ForEach(linked, id: \.self) { id in
                    linkRow(id, icon: "link")
                }
            }
            Section("Unlinked mentions") {
                let mentions = service.unlinkedMentions(ofTitle: noteTitle, excluding: noteId)
                if mentions.isEmpty {
                    Text("None").foregroundStyle(.tertiary)
                }
                ForEach(mentions, id: \.self) { id in
                    linkRow(id, icon: "text.magnifyingglass")
                }
            }
        }
    }

    private func linkRow(_ id: String, icon: String) -> some View {
        Button {
            onOpen(id)
        } label: {
            Label(
                URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent,
                systemImage: icon
            )
            .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}
