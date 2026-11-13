import Foundation

/// A note split into optional YAML frontmatter and markdown body.
/// The split is purely textual — the body is never mutated — so
/// `render()` always round-trips byte-for-byte.
public struct MarkdownDocument: Equatable, Sendable {
    public let frontmatter: Frontmatter?
    public let body: String
    /// UTF-16 offset of the body within the original source, for shifting
    /// body-relative styling ranges into full-document coordinates.
    public let bodyUTF16Offset: Int

    public init(source: String) {
        if let split = Frontmatter.split(source) {
            frontmatter = split.frontmatter
            body = split.body
            bodyUTF16Offset = split.bodyUTF16Offset
        } else {
            frontmatter = nil
            body = source
            bodyUTF16Offset = 0
        }
    }

    public init(frontmatter: Frontmatter?, body: String) {
        self.frontmatter = frontmatter
        self.body = body
        bodyUTF16Offset = frontmatter.map(\.rawBlock.utf16.count) ?? 0
    }

    /// Reassembles the full file contents.
    public func render() -> String {
        (frontmatter?.rawBlock ?? "") + body
    }
}

/// Leading YAML frontmatter delimited by `---` lines. The raw text is
/// preserved verbatim; `values` is a shallow string map good enough for
/// note metadata (title, project, status, dates) without a YAML dependency.
public struct Frontmatter: Equatable, Sendable {
    /// The full block including both `---` fences and the trailing newline.
    public let rawBlock: String
    /// Shallow `key: value` pairs (nested YAML is preserved raw, not parsed).
    public let values: [String: String]

    public init(rawBlock: String, values: [String: String]) {
        self.rawBlock = rawBlock
        self.values = values
    }

    /// Builds a block from key/value pairs (keys sorted for stable output).
    public init(values: [String: String]) {
        let lines = values.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        self.init(rawBlock: "---\n\(lines)\n---\n", values: values)
    }

    /// `values[key]` with one level of YAML scalar quoting removed:
    /// `"a \"b\""` → `a "b"`, `'it''s'` → `it's`; an unquoted value is
    /// returned as written. Nil when the key is absent.
    public func string(_ key: String) -> String? {
        guard let raw = values[key] else { return nil }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in raw.dropFirst().dropLast() {
                if escaping {
                    result.append(character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    /// A copy with `key` set to `value` (nil removes it), editing the raw
    /// block minimally: unrelated lines keep their exact bytes.
    public func updating(key: String, value: String?) -> Frontmatter {
        var lines = splitLines(rawBlock)
        if lines.last == "" {
            lines.removeLast()
        } // block ends with newline
        lines.removeAll {
            strippingCarriageReturn($0).hasPrefix(key + ":")
        }
        if let value {
            // Insert just before the closing fence.
            let insertAt = lines.lastIndex { strippingCarriageReturn($0) == "---" } ?? lines.endIndex
            lines.insert("\(key): \(value)", at: insertAt)
        }
        var merged = values
        merged[key] = value
        return Frontmatter(rawBlock: lines.joined(separator: "\n") + "\n", values: merged)
    }

    static func split(_ source: String) -> (frontmatter: Frontmatter, body: String, bodyUTF16Offset: Int)? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let lines = splitLines(source)
        var values: [String: String] = [:]

        for (index, rawLine) in lines.enumerated().dropFirst() {
            let line = strippingCarriageReturn(rawLine)
            if line == "---" {
                let blockLineCount = index + 1
                let block = lines.prefix(blockLineCount).joined(separator: "\n") + "\n"
                let body = String(source.dropFirst(block.count))
                return (
                    Frontmatter(rawBlock: block, values: values),
                    body,
                    block.utf16.count
                )
            }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.hasPrefix("#") {
                    values[key] = value
                }
            }
        }
        return nil // opening fence without a closing fence — treat as body
    }
}
