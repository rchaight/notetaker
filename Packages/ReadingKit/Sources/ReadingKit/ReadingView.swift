import Foundation
import SwiftUI

/// One block's position in the scroll view, reported up as a preference.
public struct ReadingBlockOffset: Equatable, Sendable {
    public let line: Int
    public let minY: CGFloat

    public init(line: Int, minY: CGFloat) {
        self.line = line
        self.minY = minY
    }
}

struct ReadingBlockOffsetKey: PreferenceKey {
    static let defaultValue: [ReadingBlockOffset] = []

    static func reduce(value: inout [ReadingBlockOffset], nextValue: () -> [ReadingBlockOffset]) {
        value.append(contentsOf: nextValue())
    }
}

/// Pure position math, so the editor ↔ Reading round-trip is testable
/// without a window.
public enum ReadingLayout {
    /// The source line of the block at the top of the viewport: the last
    /// block that has scrolled to or past the top edge, else the first one
    /// laid out.
    public static func topVisibleLine(from offsets: [ReadingBlockOffset]) -> Int? {
        guard !offsets.isEmpty else { return nil }
        let sorted = offsets.sorted { $0.minY < $1.minY }
        if let straddling = sorted.last(where: { $0.minY <= 1 }) {
            return straddling.line
        }
        return sorted.first?.line
    }
}

/// Holds the top-visible line outside SwiftUI state on purpose: scrolling
/// changes it constantly and a `@State` write per frame would re-run the
/// whole detail pane's body.
@MainActor
final class ReadingScrollTracker {
    private var topLine: Int?
    var onChange: ((Int) -> Void)?

    func accept(_ offsets: [ReadingBlockOffset]) {
        guard let line = ReadingLayout.topVisibleLine(from: offsets), line != topLine else {
            return
        }
        topLine = line
        onChange?(line)
    }
}

/// Reading mode: the note rendered, nothing editable. Built from the same
/// parsers the editor styles with, so chips, wikilinks and highlights can't
/// disagree between modes.
public struct ReadingView: View {
    private static let space = "ReadingKit.scroll"

    let source: String
    let style: ReadingStyle
    let imageBase: URL?
    @Binding var scrollToLine: Int?
    let onToggleTask: (Int) -> Void
    let onOpenNote: (String) -> Void
    let onTopLineChanged: (Int) -> Void

    @State private var blocks: [ReadingBlock] = []
    /// Bumped after each parse so the pending scroll target can be applied
    /// once there is something to scroll to.
    @State private var renderVersion = 0
    @State private var tracker = ReadingScrollTracker()

    public init(
        source: String,
        style: ReadingStyle = .default,
        imageBase: URL? = nil,
        scrollToLine: Binding<Int?> = .constant(nil),
        onToggleTask: @escaping (Int) -> Void = { _ in },
        onOpenNote: @escaping (String) -> Void = { _ in },
        onTopLineChanged: @escaping (Int) -> Void = { _ in }
    ) {
        self.source = source
        self.style = style
        self.imageBase = imageBase
        _scrollToLine = scrollToLine
        self.onToggleTask = onToggleTask
        self.onOpenNote = onOpenNote
        self.onTopLineChanged = onTopLineChanged
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        ReadingBlockView(
                            block: block, style: style, imageBase: imageBase,
                            onToggleTask: onToggleTask
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(block.id)
                        .background(offsetReporter(line: block.firstLine))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .coordinateSpace(.named(Self.space))
            .onChange(of: renderVersion) { _, _ in applyScrollTarget(proxy) }
            .onChange(of: scrollToLine) { _, _ in applyScrollTarget(proxy) }
        }
        .textSelection(.enabled)
        .onAppear { tracker.onChange = onTopLineChanged }
        .onPreferenceChange(ReadingBlockOffsetKey.self) { [tracker] offsets in
            Task { @MainActor in tracker.accept(offsets) }
        }
        // Wikilinks are links with a private scheme — intercept those and
        // let every real URL fall through to the system.
        .environment(\.openURL, OpenURLAction { url in
            if let target = ReadingInlineText.wikilinkTarget(of: url) {
                onOpenNote(target)
                return .handled
            }
            return .systemAction
        })
        .task(id: source) {
            // Parsing a long note off the main actor keeps mode switches
            // from hitching; ReadingDocument is pure, so this is safe.
            let text = source
            let parsed = await Task.detached(priority: .userInitiated) {
                ReadingDocument.build(from: text)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
            renderVersion += 1
        }
    }

    private func offsetReporter(line: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ReadingBlockOffsetKey.self,
                value: [ReadingBlockOffset(
                    line: line, minY: geometry.frame(in: .named(Self.space)).minY
                )]
            )
        }
    }

    /// One-shot, the same contract `MarkdownEditor.scrollTarget` uses: the
    /// caller sets a line, the view consumes it.
    private func applyScrollTarget(_ proxy: ScrollViewProxy) {
        guard let line = scrollToLine, !blocks.isEmpty,
              let anchor = ReadingDocument.anchorLine(for: line, in: blocks)
        else { return }
        proxy.scrollTo(anchor, anchor: .top)
        Task { @MainActor in scrollToLine = nil }
    }
}
