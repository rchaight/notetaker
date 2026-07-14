import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit

    public typealias PlatformFont = NSFont
    public typealias PlatformFontDescriptor = NSFontDescriptor
    public typealias PlatformColor = NSColor
#else
    import UIKit

    public typealias PlatformFont = UIFont
    public typealias PlatformFontDescriptor = UIFontDescriptor
    public typealias PlatformColor = UIColor
#endif

/// Maps markdown element kinds to text attributes. One theme drives the
/// whole editor so typography stays coherent; swap themes wholesale for
/// appearance options later.
///
/// @unchecked Sendable: value struct whose stored platform colors are
/// immutable class instances; fonts are derived on access.
public struct MarkdownTheme: @unchecked Sendable {
    public var baseFontSize: CGFloat
    /// "system" | "serif" | "rounded" | "mono" — applied to body AND
    /// headings; code spans stay monospaced regardless.
    public var fontDesign: String
    public var textColor: PlatformColor
    public var accentColor: PlatformColor
    public var codeBackground: PlatformColor
    public var secondaryColor: PlatformColor

    public static let `default` = MarkdownTheme(
        baseFontSize: 16,
        textColor: .labelColorCompat,
        accentColor: .tintColorCompat,
        codeBackground: .codeBackgroundCompat,
        secondaryColor: .secondaryLabelColorCompat
    )

    public init(
        baseFontSize: CGFloat,
        fontDesign: String = "system",
        textColor: PlatformColor,
        accentColor: PlatformColor,
        codeBackground: PlatformColor,
        secondaryColor: PlatformColor
    ) {
        self.baseFontSize = baseFontSize
        self.fontDesign = fontDesign
        self.textColor = textColor
        self.accentColor = accentColor
        self.codeBackground = codeBackground
        self.secondaryColor = secondaryColor
    }

    /// A user-customized copy (Settings drives size + design).
    public func customized(baseFontSize: CGFloat, fontDesign: String) -> MarkdownTheme {
        var theme = self
        theme.baseFontSize = baseFontSize
        theme.fontDesign = fontDesign
        return theme
    }

    private var systemDesign: PlatformFontDescriptor.SystemDesign? {
        switch fontDesign {
        case "serif": .serif
        case "rounded": .rounded
        case "mono": .monospaced
        default: nil
        }
    }

    func designedFont(size: CGFloat, bold: Bool = false) -> PlatformFont {
        let base = bold
            ? PlatformFont.boldSystemFont(ofSize: size)
            : PlatformFont.systemFont(ofSize: size)
        guard let design = systemDesign,
              let descriptor = base.fontDescriptor.withDesign(design)
        else { return base }
        #if canImport(AppKit)
            return PlatformFont(descriptor: descriptor, size: size) ?? base
        #else
            return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }

    public var baseFont: PlatformFont {
        designedFont(size: baseFontSize)
    }

    public var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor]
    }

    /// Multipliers for heading levels 1–6.
    static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    public func headingFont(level: Int) -> PlatformFont {
        let scale = Self.headingScales[min(max(level, 1), 6) - 1]
        return designedFont(size: (baseFontSize * scale).rounded(), bold: true)
    }

    public var tableHeaderFont: PlatformFont {
        .boldSystemFont(ofSize: baseFontSize * 0.95)
    }

    public var monoFont: PlatformFont {
        .monospacedSystemFont(ofSize: baseFontSize * 0.93, weight: .regular)
    }

    /// Live Preview: markers off the cursor line collapse to a hair-width,
    /// fully transparent run — attributes only, characters untouched.
    public var hiddenMarkerAttributes: [NSAttributedString.Key: Any] {
        [.font: PlatformFont.systemFont(ofSize: 0.01), .foregroundColor: PlatformColor.clear]
    }

    /// The clickable "[ ]" / "[x]" checkbox token — sized up so the ○/●
    /// bubble glyph reads like the To-Do tab's check bubble.
    public func checkboxTokenAttributes(checked: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(
                ofSize: (baseFontSize * 1.25).rounded(), weight: .semibold
            ),
            .foregroundColor: checked ? secondaryColor : accentColor,
        ]
    }

    public func attributes(for kind: MarkdownElementKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case let .heading(level):
            [.font: headingFont(level: level)]
        case .strong:
            [.font: designedFont(size: baseFontSize, bold: true)]
        case .emphasis:
            [.font: italicFont]
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
             .foregroundColor: secondaryColor]
        case .inlineCode:
            [.font: monoFont, .backgroundColor: codeBackground]
        case .codeBlock:
            // The drawn card supplies the background; a per-run color on
            // top would double-tint.
            [.font: monoFont]
        case .link:
            [.foregroundColor: accentColor,
             .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .blockQuote:
            [.foregroundColor: secondaryColor, .paragraphStyle: quoteParagraphStyle]
        case .taskCheckbox(checked: true):
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
             .foregroundColor: secondaryColor]
        case .wikilink:
            [.foregroundColor: accentColor,
             .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .highlightMark:
            [.backgroundColor: highlightBackground]
        case .listItem, .taskCheckbox, .thematicBreak, .table, .image:
            [:]
        }
    }

    /// Marker-pen tint for `==highlight==` runs; translucent so it adapts to
    /// both appearances.
    public var highlightBackground: PlatformColor {
        PlatformColor.systemYellow.withAlphaComponent(0.30)
    }

    // MARK: - Surface tokens

    /// The writing surface. Dark stays off pure black (halation guidance:
    /// ~#1C1C1E, matching system grouped backgrounds) and light stays paper
    /// white; both resolve dynamically with the appearance.
    public var editorBackground: PlatformColor {
        Self.dynamicColor(
            light: PlatformColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            dark: PlatformColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        )
    }

    /// Raised elements over the writing surface (cards, badges).
    public var surfaceBackground: PlatformColor {
        Self.dynamicColor(
            light: PlatformColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
            dark: PlatformColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
        )
    }

    /// Blockquote bar/tint token (consumed by the quote rendering pass).
    public var quoteAccent: PlatformColor {
        accentColor.withAlphaComponent(0.75)
    }

    /// Vertical room reserved under a standalone image line for its
    /// drawn thumbnail (thumbnail max height + gap).
    public static let imageThumbnailHeight: CGFloat = 140
    public var imageParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Self.imageThumbnailHeight + 10
        return style
    }

    /// Indents quote text clear of the drawn accent bar.
    var quoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 14
        style.headIndent = 14
        return style
    }

    /// Focus mode: paragraphs away from the cursor recede to this color.
    public var focusDimColor: PlatformColor {
        #if canImport(AppKit)
            .tertiaryLabelColor
        #else
            .tertiaryLabel
        #endif
    }

    /// Selection tint derived from the accent so selected runs, the caret,
    /// and links all share one hue.
    public var selectionBackground: PlatformColor {
        accentColor.withAlphaComponent(0.25)
    }

    static func dynamicColor(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if canImport(AppKit)
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        #else
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        #endif
    }

    private var italicFont: PlatformFont {
        #if canImport(AppKit)
            NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        #else
            if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                UIFont(descriptor: descriptor, size: baseFontSize)
            } else {
                baseFont
            }
        #endif
    }
}

private extension PlatformColor {
    static var labelColorCompat: PlatformColor {
        #if canImport(AppKit)
            .labelColor
        #else
            .label
        #endif
    }

    static var secondaryLabelColorCompat: PlatformColor {
        #if canImport(AppKit)
            .secondaryLabelColor
        #else
            .secondaryLabel
        #endif
    }

    static var tintColorCompat: PlatformColor {
        #if canImport(AppKit)
            .controlAccentColor
        #else
            .tintColor
        #endif
    }

    static var codeBackgroundCompat: PlatformColor {
        #if canImport(AppKit)
            NSColor.labelColor.withAlphaComponent(0.06)
        #else
            UIColor.label.withAlphaComponent(0.06)
        #endif
    }
}
