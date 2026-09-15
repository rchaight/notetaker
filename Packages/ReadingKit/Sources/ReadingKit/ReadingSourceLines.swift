import Foundation
import Markdown
import MarkdownKit

/// Line ↔ UTF-16 offset math for one text buffer. Reading mode and the
/// TextKit editor have to agree on what "line 12" means: the editor speaks
/// UTF-16 offsets (NSRange), the AST speaks 1-based line/UTF-8 column, and
/// the index speaks 0-based file lines. This is the single converter between
/// all three.
///
/// LF is found at the UTF-16 level on purpose: "\r\n" is ONE Swift grapheme,
/// so a Character-based scan misses every CRLF break.
public struct ReadingSourceLines: Sendable {
    /// UTF-16 offset where each line starts.
    private let lineStarts: [Int]
    /// Each line's text, trailing "\r" kept (byte-exact reassembly).
    private let lines: [String]

    public init(_ text: String) {
        let ns = text as NSString
        var starts = [0]
        var collected: [String] = []
        var lineStart = 0
        for offset in 0 ..< ns.length where ns.character(at: offset) == 0x0A {
            collected.append(
                ns.substring(with: NSRange(location: lineStart, length: offset - lineStart + 1))
            )
            starts.append(offset + 1)
            lineStart = offset + 1
        }
        if lineStart < ns.length || collected.isEmpty {
            collected.append(ns.substring(from: min(lineStart, ns.length)))
        }
        lineStarts = starts
        lines = collected
    }

    public var lineCount: Int {
        max(lines.count, 1)
    }

    /// 0-based line holding `offset`, clamped into the buffer.
    public func line(forUTF16Offset offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return min(low, lineCount - 1)
    }

    /// UTF-16 offset of the start of `line`, clamped into the buffer.
    public func utf16Offset(ofLine line: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        return lineStarts[min(max(line, 0), lineStarts.count - 1)]
    }

    /// UTF-16 offset for a swift-markdown SourceLocation (1-based line,
    /// 1-based UTF-8 column).
    func utf16Offset(of location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0 else { return nil }
        guard lineIndex < lines.count else {
            // A range end may sit one past the last line (EOF).
            return lineIndex == lines.count ? lineStarts.last : nil
        }
        let line = lines[lineIndex]
        let column = max(location.column - 1, 0)
        guard let index = line.utf8.index(
            line.utf8.startIndex, offsetBy: column, limitedBy: line.utf8.endIndex
        ) else {
            return lineStarts[lineIndex] + line.utf16.count
        }
        return lineStarts[lineIndex] + line[..<index].utf16.count
    }

    func nsRange(of range: SourceRange) -> NSRange? {
        guard let start = utf16Offset(of: range.lowerBound),
              let end = utf16Offset(of: range.upperBound),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// How many FILE lines a frontmatter block occupies (0 when there is none).
/// `rawBlock` always ends with a newline, so `splitLines` reports one extra
/// empty trailing element.
func frontmatterLineCount(_ frontmatter: Frontmatter?) -> Int {
    guard let frontmatter else { return 0 }
    return max(splitLines(frontmatter.rawBlock).count - 1, 0)
}
