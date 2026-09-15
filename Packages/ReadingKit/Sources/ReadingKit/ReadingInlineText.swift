import Foundation
import SwiftUI

/// Renders `[ReadingInline]` as one `AttributedString`, so a paragraph
/// flows and wraps as real text instead of as a row of stacked views.
///
/// Taps ride on link attributes: an `[[Note Title]]` becomes a private-scheme
/// URL that `ReadingView` intercepts through `OpenURLAction`. That keeps
/// wikilinks tappable without breaking text layout.
public enum ReadingInlineText {
    /// Private scheme for wikilink taps — never leaves the process.
    static let wikilinkScheme = "notetaker-wikilink"

    /// The note title a wikilink URL carries, or nil for any other URL.
    public static func wikilinkTarget(of url: URL) -> String? {
        guard url.scheme == wikilinkScheme else { return nil }
        // The title is the host+path of an opaque URL; read it back from the
        // percent-encoded form so spaces and punctuation survive.
        let raw = url.absoluteString.dropFirst(wikilinkScheme.count + 3)
        return String(raw).removingPercentEncoding
    }

    static func url(forWikilink target: String) -> URL? {
        let encoded = target.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? target
        return URL(string: "\(wikilinkScheme)://\(encoded)")
    }

    /// Accumulated inline styling, materialized into attributes at each leaf.
    struct Context {
        var bold = false
        var italic = false
        var strikethrough = false
        var highlighted = false
        var color: Color?
        var link: URL?
    }

    public static func attributed(
        _ inlines: [ReadingInline], style: ReadingStyle
    ) -> AttributedString {
        var result = AttributedString()
        append(inlines, style: style, context: Context(), into: &result)
        return result
    }

    private static func append(
        _ inlines: [ReadingInline],
        style: ReadingStyle,
        context: Context,
        into result: inout AttributedString
    ) {
        for inline in inlines {
            switch inline {
            case let .text(text):
                result.append(run(text, style: style, context: context))
            case let .strong(children):
                var inner = context
                inner.bold = true
                append(children, style: style, context: inner, into: &result)
            case let .emphasis(children):
                var inner = context
                inner.italic = true
                append(children, style: style, context: inner, into: &result)
            case let .strikethrough(children):
                var inner = context
                inner.strikethrough = true
                append(children, style: style, context: inner, into: &result)
            case let .highlight(children):
                var inner = context
                inner.highlighted = true
                append(children, style: style, context: inner, into: &result)
            case let .code(code):
                var piece = AttributedString(code)
                piece.font = style.monoFont
                piece.backgroundColor = style.codeBackground
                piece.foregroundColor = context.color ?? style.textColor
                result.append(piece)
            case let .link(destination, children):
                var inner = context
                inner.color = style.accentColor
                inner.link = URL(string: destination)
                if inner.link == nil, children.isEmpty {
                    result.append(run(destination, style: style, context: context))
                } else {
                    append(
                        children.isEmpty ? [.text(destination)] : children,
                        style: style, context: inner, into: &result
                    )
                }
            case let .wikilink(target):
                var inner = context
                inner.color = style.accentColor
                inner.link = url(forWikilink: target)
                result.append(run(target, style: style, context: inner))
            case let .image(source, alt):
                // Inline (mid-sentence) images stay textual; a standalone
                // image line is its own block and draws for real.
                var inner = context
                inner.color = style.secondaryColor
                result.append(run(alt.isEmpty ? source : alt, style: style, context: inner))
            case let .tag(name):
                var inner = context
                inner.bold = true
                inner.color = style.tagColor(name)
                result.append(run("#" + name, style: style, context: inner))
            case let .mention(name):
                var inner = context
                inner.bold = true
                inner.color = style.mentionColor
                result.append(run("@" + name, style: style, context: inner))
            case let .kindToken(kind):
                var inner = context
                inner.bold = true
                inner.color = style.kindColor(kind)
                result.append(run("?" + kind, style: style, context: inner))
            case .lineBreak:
                result.append(AttributedString("\n"))
            case .softBreak:
                result.append(run(" ", style: style, context: context))
            }
        }
    }

    private static func run(
        _ text: String, style: ReadingStyle, context: Context
    ) -> AttributedString {
        var piece = AttributedString(text)
        var font = Font.system(
            size: style.baseFontSize,
            weight: context.bold ? .bold : .regular,
            design: style.fontDesign
        )
        if context.italic {
            font = font.italic()
        }
        piece.font = font
        piece.foregroundColor = context.color ?? style.textColor
        if context.strikethrough {
            piece.strikethroughStyle = .single
        }
        if context.highlighted {
            piece.backgroundColor = style.highlightBackground
        }
        if let link = context.link {
            piece.link = link
            piece.underlineStyle = .single
        }
        return piece
    }

    /// Plain text of an inline run — accessibility labels and tests.
    public static func plainText(_ inlines: [ReadingInline]) -> String {
        inlines.map { inline in
            switch inline {
            case let .text(text): text
            case let .strong(children): plainText(children)
            case let .emphasis(children): plainText(children)
            case let .strikethrough(children): plainText(children)
            case let .highlight(children): plainText(children)
            case let .code(code): code
            case let .link(destination, children):
                children.isEmpty ? destination : plainText(children)
            case let .image(source, alt): alt.isEmpty ? source : alt
            case let .wikilink(target): target
            case let .tag(name): "#" + name
            case let .mention(name): "@" + name
            case let .kindToken(kind): "?" + kind
            case .lineBreak: "\n"
            case .softBreak: " "
            }
        }.joined()
    }
}
