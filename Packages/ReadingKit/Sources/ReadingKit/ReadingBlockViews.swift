import Foundation
import SwiftUI
import TaskEngine

/// One rendered block. Recursive: quotes and list items render blocks of
/// their own through `ReadingBlocksView`.
struct ReadingBlockView: View {
    let block: ReadingBlock
    let style: ReadingStyle
    let imageBase: URL?
    let onToggleTask: (Int) -> Void

    var body: some View {
        switch block.kind {
        case let .frontmatter(pairs):
            ReadingFrontmatterCard(pairs: pairs, style: style)
        case let .heading(level, inlines):
            Text(ReadingInlineText.attributed(inlines, style: style))
                .font(.system(
                    size: style.headingSize(level: level),
                    weight: level <= 2 ? .bold : .semibold,
                    design: style.fontDesign
                ))
                .padding(.top, level <= 2 ? 8 : 2)
        case let .paragraph(inlines):
            Text(ReadingInlineText.attributed(inlines, style: style))
        case let .list(ordered, start, items):
            ReadingListView(
                ordered: ordered, start: start, items: items,
                style: style, imageBase: imageBase, onToggleTask: onToggleTask
            )
        case let .blockquote(blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(style.accentColor.opacity(0.75))
                    .frame(width: 3)
                ReadingBlocksView(
                    blocks: blocks, style: style, imageBase: imageBase,
                    onToggleTask: onToggleTask
                )
                .foregroundStyle(style.secondaryColor)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .codeBlock(language, text):
            ReadingCodeCard(language: language, text: text, style: style)
        case let .table(header, rows, alignments):
            ReadingTableView(header: header, rows: rows, alignments: alignments, style: style)
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        case let .image(source, alt):
            ReadingImageView(source: source, alt: alt, base: imageBase, style: style)
        case let .html(raw):
            Text(raw)
                .font(style.monoFont)
                .foregroundStyle(style.secondaryColor)
        case .locked:
            ReadingLockedCard(style: style)
        }
    }
}

struct ReadingBlocksView: View {
    let blocks: [ReadingBlock]
    let style: ReadingStyle
    let imageBase: URL?
    let onToggleTask: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReadingBlockView(
                    block: block, style: style, imageBase: imageBase,
                    onToggleTask: onToggleTask
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Lists and tasks

struct ReadingListView: View {
    let ordered: Bool
    let start: Int
    let items: [ReadingListItem]
    let style: ReadingStyle
    let imageBase: URL?
    let onToggleTask: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item, number: start + index)
                    VStack(alignment: .leading, spacing: 4) {
                        content(for: item)
                        if !item.children.isEmpty {
                            ReadingBlocksView(
                                blocks: item.children, style: style, imageBase: imageBase,
                                onToggleTask: onToggleTask
                            )
                            .padding(.leading, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func marker(for item: ReadingListItem, number: Int) -> some View {
        if let checked = item.checked {
            // The tappable circle IS the toggle — it writes through the
            // app's index path to the source markdown line.
            Button {
                onToggleTask(item.sourceLine)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: style.baseFontSize * 0.95))
                    .foregroundStyle(checked ? style.secondaryColor : style.accentColor)
            }
            .buttonStyle(.plain)
            .help(checked ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(checked ? "Completed task" : "Open task")
        } else if ordered {
            Text("\(number).")
                .font(.system(size: style.baseFontSize, design: style.fontDesign))
                .foregroundStyle(style.secondaryColor)
                .monospacedDigit()
        } else {
            Text("•")
                .font(.system(size: style.baseFontSize, design: style.fontDesign))
                .foregroundStyle(style.secondaryColor)
        }
    }

    @ViewBuilder private func content(for item: ReadingListItem) -> some View {
        let text = Text(ReadingInlineText.attributed(item.inlines, style: style))
        if let task = item.task {
            VStack(alignment: .leading, spacing: 3) {
                if item.checked == true {
                    text.strikethrough().foregroundStyle(style.secondaryColor)
                } else {
                    text
                }
                ReadingTaskChips(task: task, style: style)
            }
        } else {
            text
        }
    }
}

/// The token chips for a task line. `#tag` labels are deliberately NOT
/// repeated here: `TaskTokenParser` leaves them in `cleanText`, so they
/// already render colored in their written position (exactly as the editor
/// shows them) and a second copy would read as duplication.
struct ReadingTaskChips: View {
    let task: ParsedTaskMetadata
    let style: ReadingStyle

    var body: some View {
        if hasChips {
            HStack(spacing: 5) {
                if let priority = task.priority {
                    chip("P\(priority)", tint: style.priorityColor(priority))
                }
                if let due = task.dueDate {
                    chip(due, systemImage: "calendar", tint: style.accentColor)
                }
                if let start = task.startDate {
                    chip(start, systemImage: "hourglass", tint: style.secondaryColor)
                }
                if let recurrence = task.recurrence {
                    chip(recurrence.rawToken, systemImage: "repeat", tint: style.secondaryColor)
                }
                if let assignee = task.assignee {
                    chip("@" + assignee, tint: style.mentionColor)
                }
                if let kind = task.kind {
                    chip("?" + kind, tint: style.kindColor(kind))
                }
                if let done = task.completedDay {
                    chip(done, systemImage: "checkmark", tint: style.secondaryColor)
                }
            }
        }
    }

    private var hasChips: Bool {
        task.priority != nil || task.dueDate != nil || task.startDate != nil
            || task.recurrence != nil || task.assignee != nil || task.kind != nil
            || task.completedDay != nil
    }

    private func chip(_ text: String, systemImage: String? = nil, tint: Color) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: style.baseFontSize * 0.6))
            }
            Text(text)
        }
        .font(style.chipFont)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
    }
}

// MARK: - Cards

struct ReadingFrontmatterCard: View {
    let pairs: [ReadingKeyValue]
    let style: ReadingStyle

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.key)
                        .font(style.chipFont)
                        .foregroundStyle(style.secondaryColor)
                    Text(pair.value)
                        .font(.system(size: style.baseFontSize * 0.88, design: style.fontDesign))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ReadingCodeCard: View {
    let language: String?
    let text: String
    let style: ReadingStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(style.chipFont)
                    .foregroundStyle(style.secondaryColor)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(style.monoFont)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ReadingLockedCard: View {
    let style: ReadingStyle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.doc").font(.system(size: style.baseFontSize * 1.3))
            VStack(alignment: .leading, spacing: 2) {
                Text("Locked note").font(.system(
                    size: style.baseFontSize, weight: .semibold, design: style.fontDesign
                ))
                Text("This note is encrypted. Unlock it to read its contents.")
                    .font(.system(size: style.baseFontSize * 0.88, design: style.fontDesign))
                    .foregroundStyle(style.secondaryColor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Tables

struct ReadingTableView: View {
    let header: [ReadingTableCell]
    let rows: [[ReadingTableCell]]
    let alignments: [ReadingColumnAlignment]
    let style: ReadingStyle

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        // Only the table scrolls sideways — the page body never does.
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0 ..< columnCount, id: \.self) { column in
                        cell(header[safe: column], column: column, bold: true)
                    }
                }
                Divider().gridCellColumns(max(columnCount, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0 ..< columnCount, id: \.self) { column in
                            cell(row[safe: column], column: column, bold: false)
                        }
                    }
                }
            }
            .padding(10)
            .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cell(_ cell: ReadingTableCell?, column: Int, bold: Bool) -> some View {
        var text = AttributedString()
        if let cell {
            text = ReadingInlineText.attributed(cell.inlines, style: style)
        }
        return Text(text)
            .fontWeight(bold ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: frameAlignment(column))
            .multilineTextAlignment(textAlignment(column))
    }

    private func alignment(_ column: Int) -> ReadingColumnAlignment {
        alignments.indices.contains(column) ? alignments[column] : .leading
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Images

/// Vault-relative image sources resolve against the note's folder, the same
/// rule the editor's thumbnail fragment uses, and cap at the same height so
/// a picture is the same size in both modes.
enum ReadingImageResolver {
    static func localURL(_ source: String, base: URL?) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return nil
        }
        if source.hasPrefix("file://") {
            return URL(string: source)
        }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
        }
        guard let base else { return nil }
        // appendingPathComponent, not fileURLWithPath(relativeTo:) — the
        // latter probes the filesystem and drops the base's last component
        // when the folder isn't local yet.
        return base
            .appendingPathComponent(source.removingPercentEncoding ?? source)
            .standardizedFileURL
    }

    static func remoteURL(_ source: String) -> URL? {
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else { return nil }
        return URL(string: source)
    }

    static func load(_ url: URL) -> Image? {
        #if canImport(AppKit)
            guard let image = NSImage(contentsOf: url) else { return nil }
            return Image(nsImage: image)
        #elseif canImport(UIKit)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return nil }
            return Image(uiImage: image)
        #else
            return nil
        #endif
    }
}

struct ReadingImageView: View {
    let source: String
    let alt: String
    let base: URL?
    let style: ReadingStyle

    @State private var local: Image?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = ReadingImageResolver.remoteURL(source) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        capped(image)
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else if let local {
                capped(local)
            } else {
                placeholder
            }
            if !alt.isEmpty {
                Text(alt)
                    .font(.system(size: style.baseFontSize * 0.82, design: style.fontDesign))
                    .foregroundStyle(style.secondaryColor)
            }
        }
        .task(id: source) {
            guard ReadingImageResolver.remoteURL(source) == nil,
                  let url = ReadingImageResolver.localURL(source, base: base)
            else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                ReadingImageResolver.load(url)
            }.value
            guard !Task.isCancelled else { return }
            local = loaded
        }
    }

    private func capped(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: ReadingStyle.imageMaxHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(source)
        }
        .font(.system(size: style.baseFontSize * 0.85, design: style.fontDesign))
        .foregroundStyle(style.secondaryColor)
        .padding(8)
        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}
