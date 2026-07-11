import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit

    public typealias PlatformFont = NSFont
    public typealias PlatformColor = NSColor
#else
    import UIKit

    public typealias PlatformFont = UIFont
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
        textColor: PlatformColor,
        accentColor: PlatformColor,
        codeBackground: PlatformColor,
        secondaryColor: PlatformColor
    ) {
        self.baseFontSize = baseFontSize
        self.textColor = textColor
        self.accentColor = accentColor
        self.codeBackground = codeBackground
        self.secondaryColor = secondaryColor
    }

    public var baseFont: PlatformFont {
        .systemFont(ofSize: baseFontSize)
    }

    public var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor]
    }

    /// Multipliers for heading levels 1–6.
    static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    public func headingFont(level: Int) -> PlatformFont {
        let scale = Self.headingScales[min(max(level, 1), 6) - 1]
        return .boldSystemFont(ofSize: (baseFontSize * scale).rounded())
    }

    public var monoFont: PlatformFont {
        .monospacedSystemFont(ofSize: baseFontSize * 0.93, weight: .regular)
    }

    public func attributes(for kind: MarkdownElementKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case let .heading(level):
            [.font: headingFont(level: level)]
        case .strong:
            [.font: PlatformFont.boldSystemFont(ofSize: baseFontSize)]
        case .emphasis:
            [.font: italicFont]
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
             .foregroundColor: secondaryColor]
        case .inlineCode, .codeBlock:
            [.font: monoFont, .backgroundColor: codeBackground]
        case .link:
            [.foregroundColor: accentColor,
             .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .blockQuote:
            [.foregroundColor: secondaryColor]
        case .taskCheckbox(checked: true):
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
             .foregroundColor: secondaryColor]
        case .listItem, .taskCheckbox, .thematicBreak, .table:
            [:]
        }
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
