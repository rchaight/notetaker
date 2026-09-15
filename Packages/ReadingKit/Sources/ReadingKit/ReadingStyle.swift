import Foundation
import SwiftUI

/// Everything Reading mode needs to look like the editor. ReadingKit can't
/// import EditorKit (it would drag TextKit into a pure SwiftUI renderer), so
/// the app fills this in from `MarkdownTheme` and the To-Do tab's chip
/// palette — one place to keep the two surfaces in agreement.
public struct ReadingStyle: Sendable {
    public var baseFontSize: CGFloat
    public var fontDesign: Font.Design
    /// Fraction of each heading level's default enlargement to apply
    /// (1 = standard, 0 = body size) — mirrors MarkdownTheme.headingScale.
    public var headingScale: CGFloat
    public var textColor: Color
    public var secondaryColor: Color
    public var accentColor: Color
    /// Inline-code and code-card fill.
    public var codeBackground: Color
    /// Frontmatter / table-header card fill.
    public var cardBackground: Color
    public var highlightBackground: Color
    public var mentionColor: Color
    /// Per-`#tag` chip color — the app passes `TaskChipStyle.labelColor`.
    public var tagColor: @Sendable (String) -> Color
    /// Per-`?kind` chip color.
    public var kindColor: @Sendable (String) -> Color
    /// `!p1`…`!p4` chip color.
    public var priorityColor: @Sendable (Int?) -> Color

    /// Multipliers for heading levels 1–6 — the same ladder
    /// `MarkdownTheme.headingScales` uses, so a heading is the same size in
    /// both modes.
    public static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    /// Matches `MarkdownTheme.imageThumbnailHeight`.
    public static let imageMaxHeight: CGFloat = 280

    public init(
        baseFontSize: CGFloat = 16,
        fontDesign: Font.Design = .default,
        headingScale: CGFloat = 1.0,
        textColor: Color = .primary,
        secondaryColor: Color = .secondary,
        accentColor: Color = .accentColor,
        codeBackground: Color = Color.primary.opacity(0.06),
        cardBackground: Color = Color.primary.opacity(0.04),
        highlightBackground: Color = Color.yellow.opacity(0.30),
        mentionColor: Color = .indigo,
        tagColor: @escaping @Sendable (String) -> Color = { _ in .blue },
        kindColor: @escaping @Sendable (String) -> Color = { _ in .teal },
        priorityColor: @escaping @Sendable (Int?) -> Color = { _ in .secondary }
    ) {
        self.baseFontSize = baseFontSize
        self.fontDesign = fontDesign
        self.headingScale = headingScale
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeBackground = codeBackground
        self.cardBackground = cardBackground
        self.highlightBackground = highlightBackground
        self.mentionColor = mentionColor
        self.tagColor = tagColor
        self.kindColor = kindColor
        self.priorityColor = priorityColor
    }

    public static let `default` = ReadingStyle()

    public func headingSize(level: Int) -> CGFloat {
        let scale = 1 + (Self.headingScales[min(max(level, 1), 6) - 1] - 1) * headingScale
        return (baseFontSize * scale).rounded()
    }

    public var bodyFont: Font {
        .system(size: baseFontSize, design: fontDesign)
    }

    public var monoFont: Font {
        .system(size: (baseFontSize * 0.93).rounded(), design: .monospaced)
    }

    public var chipFont: Font {
        .system(size: (baseFontSize * 0.78).rounded(), weight: .semibold, design: fontDesign)
    }
}
