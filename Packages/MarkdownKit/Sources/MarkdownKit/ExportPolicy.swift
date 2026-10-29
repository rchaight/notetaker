import Foundation

/// Why `ExportPolicy` kept a file at home. Raw values are written into the
/// remote replica's manifest counters — never rename a case.
public enum ExportExclusionReason: String, Sendable, CaseIterable, Codable {
    case invalidPath // empty, ".." or empty component, absolute, backslash, NUL
    case indexFile // _index.md at any depth (any letter case)
    case hiddenPath // any path component starting with "."
    case notMarkdown // extension != md (case-insensitive); covers ".icloud"
    case excludedFolder // under one of options.excludedFolders
    case undecodable // bytes are not valid UTF-8, or contain NUL (UTF-16/32 without a BOM)
    case locked // frontmatter says locked (any non-false value)
    case lockedEnvelope // salt:/rounds: keys or a bare ciphertext body, i.e. a LockedNoteFile shape
    case optedOut // frontmatter remote: false
    case unclosedFrontmatterWithLockKey // fail-closed on malformed frontmatter
}

public enum ExportDecision: Equatable, Sendable {
    case export
    case excluded(ExportExclusionReason)
}

/// The one Mac-side gate deciding whether a vault file may be copied into the
/// remote replica (design 00 §5 gate 1). Pure and I/O-free.
///
/// It FAILS CLOSED: a false exclusion is a usability bug, a false export is a
/// security bug. Detection is deliberately a superset of every reader that
/// could treat a file as locked — the app's own `Frontmatter.split` (opens on
/// a first line of exactly `---`, closes on the next line of exactly `---`,
/// `values["locked"] == "true"`) as well as tolerant YAML-ish readers (BOM,
/// leading blank lines, CRLF or bare-CR line ends, quoted/uppercase/yes
/// values, `...` fences, indentation, flow mappings). Every key line after
/// the opening fence counts until the app's exact `---` close — to end of
/// file when that close never comes — and only a note exactly closed within
/// the first 200 lines gets the closed-frontmatter reasons; anything else
/// carrying a lock key is `unclosedFrontmatterWithLockKey`.
///
/// Obligations on the caller (spec 03 `ReplicaExporter`), which this pure
/// type cannot enforce: never follow symlinks (a link inside the vault can
/// point at anything); never read or download `.icloud` placeholders (the
/// path gate excludes them, so do not materialise them first); and cap the
/// size of a file before reading it into memory — oversize is an exclusion,
/// not a truncated read.
public struct ExportPolicy: Sendable, Equatable {
    /// Bump when a rule changes; written into manifest.json as policy_version.
    public static let version = 1
    /// Duplicated from VaultKit.VaultFileStore.indexFileName on purpose —
    /// MarkdownKit cannot import VaultKit. Spec 03 adds a parity test.
    public static let indexFileName = "_index.md"
    /// Frontmatter that has not closed within this many lines is "unclosed".
    static let unclosedLineLimit = 200

    /// Vault-relative folder prefixes (e.g. "Work Notes/Personnel").
    /// Normalised on init: trimmed of "/" and whitespace, empty entries dropped.
    public let excludedFolders: [String]

    public init(excludedFolders: [String] = []) {
        self.excludedFolders = excludedFolders.compactMap(Self.normalisedFolder)
    }

    /// Path-only gate: cheap, run before reading the file.
    public func decide(relativePath: String) -> ExportDecision {
        pathExclusion(relativePath).map(ExportDecision.excluded) ?? .export
    }

    /// Full gate: path gate first, then contents.
    public func decide(relativePath: String, contents: Data) -> ExportDecision {
        if let reason = pathExclusion(relativePath) {
            return .excluded(reason)
        }
        // A file we cannot read we cannot clear.
        // Stdlib validation (same on Darwin and Linux); a BOM is kept and trimmed later.
        guard let text = String(validating: contents, as: UTF8.self) else { return .excluded(.undecodable) }
        return Self.contentDecision(text)
    }

    public func decide(relativePath: String, contents: String) -> ExportDecision {
        if let reason = pathExclusion(relativePath) {
            return .excluded(reason)
        }
        return Self.contentDecision(contents)
    }

    /// NUL never appears in a text note, but UTF-16/32 text without a BOM is
    /// valid UTF-8 (ASCII interleaved with NULs) and would hide its
    /// frontmatter from every check below — so NUL is undecodable too.
    static func containsNUL(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return false }
            return memchr(base, 0, buffer.count) != nil
        }
    }

    /// The locked-note detector alone, for self-checks and audit-replica.
    /// True when `decide` would answer .locked, .lockedEnvelope or
    /// .unclosedFrontmatterWithLockKey.
    public static func looksLocked(_ contents: String) -> Bool {
        switch contentDecision(contents) {
        case .excluded(.locked), .excluded(.lockedEnvelope), .excluded(.unclosedFrontmatterWithLockKey):
            true
        default:
            false
        }
    }
}

// MARK: - Path gate

extension ExportPolicy {
    func pathExclusion(_ path: String) -> ExportExclusionReason? {
        // 1. invalidPath
        if path.unicodeScalars.first == "/" || path.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\0" }) {
            return .invalidPath
        }
        if path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            return .invalidPath
        }
        // Split on SCALARS, never Characters: a name starting with a combining
        // mark, ZWJ or VS16 ("Private/\u{301}x.md") glues to the preceding "/"
        // as ONE grapheme, hiding the boundary from Character-based split and
        // hasPrefix — the folder and hidden rules would then miss it.
        let components = Self.scalarComponents(path, omittingEmpty: false)
        // Empty components ("a//b.md", "a/b.md/") would let a folder rule be
        // sidestepped by spelling; nothing enumerated looks like that.
        if components.contains(where: { $0 == ".." || $0.isEmpty }) {
            return .invalidPath
        }
        // 2. hiddenPath — also catches "." components and ".Foo.md.icloud".
        if components.contains(where: { $0.unicodeScalars.first == "." }) {
            return .hiddenPath
        }
        let last = components[components.count - 1]
        // 3. indexFile — case-insensitive: on the case-insensitive vault FS an
        // existing "_Index.md" keeps its spelling while the app rewrites it.
        if last.lowercased() == Self.indexFileName {
            return .indexFile
        }
        // 4. notMarkdown (last "." scalar, so a combining mark cannot hide a dot)
        let scalars = last.unicodeScalars
        guard let dot = scalars.lastIndex(of: "."),
              String(scalars[scalars.index(after: dot)...]).lowercased() == "md"
        else { return .notMarkdown }
        // 5. excludedFolder — case-insensitive, because the vault sits on a
        // case-insensitive APFS volume where "Personnel" and "personnel" are
        // one folder, canonical-equivalence aware (NFC/NFD), compared
        // component by component on scalar boundaries.
        if excludedFolders.contains(where: { Self.components(components, areInFolder: $0) }) {
            return .excludedFolder
        }
        return nil
    }

    /// True when the leading path components equal the folder's components.
    /// Either comparison matching is enough (fail closed): Foundation's
    /// `compare(_:options: .caseInsensitive)` (full case folding, canonical
    /// equivalence — e.g. "ᾈ" == "ἀι", as APFS folds them), or stdlib
    /// `lowercased()` + canonical `==`. Not `caseInsensitiveCompare`, which
    /// misses folds like that one.
    static func components(_ components: [String], areInFolder folder: String) -> Bool {
        let folderParts = scalarComponents(folder, omittingEmpty: true)
        guard !folderParts.isEmpty, components.count >= folderParts.count else { return false }
        return zip(components, folderParts).allSatisfy { part, folderPart in
            part.compare(folderPart, options: [.caseInsensitive]) == .orderedSame
                || part.lowercased() == folderPart.lowercased()
        }
    }

    /// "/"-separated components split on Unicode scalars (see pathExclusion).
    static func scalarComponents(_ path: String, omittingEmpty: Bool) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: omittingEmpty)
            .map { String(String.UnicodeScalarView($0)) }
    }

    static func normalisedFolder(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        var parts: [String] = []
        for part in scalarComponents(trimmed, omittingEmpty: true) where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { return nil } // escapes the vault: matches nothing
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

// MARK: - Content gate

extension ExportPolicy {
    static func contentDecision(_ text: String) -> ExportDecision {
        if containsNUL(text) {
            return .excluded(.undecodable)
        }
        // View 1: the app's own line model (LF; CRLF via a stripped "\r").
        let primary = ContentProbe.decide(text, breaks: .lineFeed)
        if primary != .export {
            return primary
        }
        // View 2: every Unicode/YAML line break (bare CR, U+2028, NEL…) — a
        // tolerant reader could see frontmatter the LF view cannot.
        return ContentProbe.decide(text, breaks: .anyLineBreak)
    }
}

/// Shallow frontmatter scan shared by both line views.
private enum ContentProbe {
    enum Breaks { case lineFeed, anyLineBreak }

    /// Whitespace plus BOM / zero-width characters an editor can leave invisible.
    static let trimSet: CharacterSet = .whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}\u{180E}"))
    static let lockedFalseValues: Set<String> = ["false", "no", "off", "0", ""]
    static let optOutValues: Set<String> = ["false", "no", "off", "0"]
    /// AES-GCM combined output is at least 28 bytes (nonce + tag) = 40 base64 chars.
    static let minimumCiphertextLength = 40

    struct Flags {
        var locked = false // `locked` with a non-false value
        var lockKey = false // `locked` (any value), `salt` or `rounds` present
        var envelope = false // `salt` or `rounds` present
        var optOut = false // `remote` with a false value

        mutating func formUnion(_ other: Flags) {
            locked = locked || other.locked
            lockKey = lockKey || other.lockKey
            envelope = envelope || other.envelope
            optOut = optOut || other.optOut
        }
    }

    struct Entry {
        let key: String
        let value: String
        let valueIsBlank: Bool
    }

    static func decide(_ text: String, breaks: Breaks) -> ExportDecision {
        var reader = LineReader(text: text, breaks: breaks)

        // Skip leading blank (incl. BOM-only) lines; the first real line must be a fence.
        var opening: String?
        while let line = reader.next() {
            let trimmed = line.trimmingCharacters(in: trimSet)
            if trimmed.isEmpty {
                continue
            }
            opening = trimmed
            break
        }
        guard let opening else { return .export } // empty or blank file
        guard opening == "---" else {
            // No frontmatter: a body that merely mentions `locked: true` is content.
            // Still catch a bare ciphertext body whose frontmatter was stripped.
            if breaks == .lineFeed, isBareCiphertext(text.unicodeScalars, from: text.startIndex) {
                return .excluded(.lockedEnvelope)
            }
            return .export
        }

        // Two readers end the frontmatter at different places: the tolerant one
        // at the first `---`/`...` (trimmed), the app at the first line that is
        // exactly `---`. Every key line up to the app's exact close (or EOF)
        // counts. `pre` = lines the tolerant reader saw inside a closed block
        // (or the first 200 lines), kept apart only to report the specific
        // reason; `post` = everything after that.
        let afterOpening = reader.position
        var pre = Flags()
        var post = Flags()
        var lineNumber = 0
        var firstCloseLine: Int?
        var exactlyClosed = false
        var bodyStart: String.Index?
        var awaitingLockedValue = false

        while let line = reader.next() {
            lineNumber += 1
            if line == "---" { // exact close (the app's rule; "\r" already stripped)
                exactlyClosed = true
                firstCloseLine = firstCloseLine ?? lineNumber
                bodyStart = reader.position
                break
            }
            let trimmed = line.trimmingCharacters(in: trimSet)
            if trimmed == "---" || trimmed == "..." {
                awaitingLockedValue = false
                if firstCloseLine == nil {
                    firstCloseLine = lineNumber
                    bodyStart = reader.position
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let countsAsPre = firstCloseLine == nil && lineNumber <= ExportPolicy.unclosedLineLimit
            var flags = countsAsPre ? pre : post
            // `locked:` with its value on the next, indented line (a YAML plain
            // multi-line scalar or nested node) — judge that line as the value.
            if awaitingLockedValue {
                awaitingLockedValue = false
                if let first = line.unicodeScalars.first, CharacterSet.whitespaces.contains(first) {
                    record(Entry(key: "locked", value: normalisedValue(trimmed), valueIsBlank: false), into: &flags)
                }
            }
            for entry in entries(in: trimmed) {
                record(entry, into: &flags)
                if entry.key == "locked", entry.valueIsBlank {
                    awaitingLockedValue = true
                }
            }
            if countsAsPre {
                pre = flags
            } else {
                post = flags
            }
        }

        var effective = pre
        effective.formUnion(post)
        let closedInTime = firstCloseLine.map { $0 <= ExportPolicy.unclosedLineLimit } ?? false

        // Only the app's exact close, within the limit, makes a closed block.
        if exactlyClosed, closedInTime {
            if effective.locked {
                return .excluded(.locked)
            }
            if effective.envelope {
                return .excluded(.lockedEnvelope)
            }
            if effective.optOut {
                return .excluded(.optedOut)
            }
            if breaks == .lineFeed, let bodyStart, isBareCiphertext(text.unicodeScalars, from: bodyStart) {
                return .excluded(.lockedEnvelope)
            }
            return .export
        }
        // Not exactly closed in time. A tolerant reader still saw a closed
        // block (`...`, `--- `): report its specific reason for keys inside it.
        if closedInTime {
            if pre.locked {
                return .excluded(.locked)
            }
            if pre.envelope {
                return .excluded(.lockedEnvelope)
            }
        }
        // Otherwise any lock key at all, anywhere after the opening fence, keeps it home.
        if effective.lockKey {
            return .excluded(.unclosedFrontmatterWithLockKey)
        }
        if effective.optOut {
            return .excluded(.optedOut)
        }
        if breaks == .lineFeed,
           isBareCiphertext(text.unicodeScalars, from: bodyStart ?? afterOpening)
           || isBareCiphertext(text.unicodeScalars, from: afterOpening) {
            return .excluded(.lockedEnvelope)
        }
        return .export
    }

    static func record(_ entry: Entry, into flags: inout Flags) {
        switch entry.key {
        case "locked":
            flags.lockKey = true
            if !lockedFalseValues.contains(entry.value) {
                flags.locked = true
            }
        case "salt", "rounds":
            flags.lockKey = true
            flags.envelope = true
        case "remote":
            if optOutValues.contains(entry.value) {
                flags.optOut = true
            }
        default:
            break
        }
    }

    /// Shallow `key: value` pairs on one trimmed frontmatter line. Tolerates
    /// YAML sequence (`- `) and complex-key (`? `) indicators, and inline flow
    /// mappings at any nesting depth (`{a: 1, b: {locked: true}}`) by also
    /// reading every `{`/`}`/`,`-separated segment — linear, no recursion, no
    /// YAML parser. Extra segments can only add exclusions.
    static func entries(in line: String) -> [Entry] {
        var result: [Entry] = []
        if let whole = entry(inSegment: Substring(line)) {
            result.append(whole)
        }
        if line.contains("{") {
            for segment in line.split(whereSeparator: { $0 == "{" || $0 == "}" || $0 == "," }) {
                if let entry = entry(inSegment: segment) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    static func entry(inSegment segment: Substring) -> Entry? {
        var text = Substring(segment.trimmingCharacters(in: trimSet))
        var sawComplexKeyIndicator = false
        while let first = text.first, first == "-" || first == "?" {
            let rest = text.dropFirst()
            guard rest.isEmpty || rest.first?.isWhitespace == true else { break }
            if first == "?" {
                sawComplexKeyIndicator = true
            }
            text = Substring(rest.trimmingCharacters(in: trimSet))
        }
        guard let colon = text.firstIndex(of: ":") else {
            // `? locked` — a complex key whose value is on a later line: unknown → fail closed.
            guard sawComplexKeyIndicator, !text.isEmpty else { return nil }
            return Entry(key: normalisedKey(text), value: "?", valueIsBlank: false)
        }
        let rawValue = text[text.index(after: colon)...].trimmingCharacters(in: trimSet)
        return Entry(
            key: normalisedKey(text[..<colon]),
            value: normalisedValue(rawValue),
            valueIsBlank: rawValue.isEmpty
        )
    }

    static func normalisedKey(_ key: Substring) -> String {
        strippingOneQuotePair(key.trimmingCharacters(in: trimSet)).lowercased()
    }

    /// Trimmed, one pair of matching quotes removed, lowercased (spec rule 11).
    static func normalisedValue(_ trimmedValue: String) -> String {
        strippingOneQuotePair(trimmedValue).lowercased()
    }

    static func strippingOneQuotePair(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first
        else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// True when everything from `start` is one base64 token of ciphertext
    /// length — the body `LockedNoteFile.render` writes — with nothing else
    /// but surrounding whitespace. Exits on the first non-base64 character,
    /// so ordinary prose costs a few scalars.
    static func isBareCiphertext(_ scalars: String.UnicodeScalarView, from start: String.Index) -> Bool {
        var count = 0
        var padding = 0
        var tokenEnded = false
        for scalar in scalars[start...] {
            if trimSet.contains(scalar) {
                if count > 0 {
                    tokenEnded = true
                }
                continue
            }
            if tokenEnded {
                return false
            }
            if scalar == "=" {
                padding += 1
                guard padding <= 2 else { return false }
            } else {
                guard padding == 0, isBase64Alphabet(scalar) else { return false }
            }
            count += 1
        }
        return count >= minimumCiphertextLength
    }

    static func isBase64Alphabet(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "+", "/": true
        default: false
        }
    }
}

/// Lazy line splitter: only the lines a decision needs are materialised, so
/// a 50 KB note with a three-line frontmatter costs three lines, not 50 KB.
/// `.lineFeed` matches `splitLines` + `strippingCarriageReturn` exactly
/// (split on "\n" scalars, one trailing "\r" removed); `.anyLineBreak` also
/// splits on bare "\r", VT, FF, NEL, U+2028 and U+2029 ("\r\n" stays one break).
private struct LineReader {
    let scalars: String.UnicodeScalarView
    let breaks: ContentProbe.Breaks
    private(set) var position: String.Index

    init(text: String, breaks: ContentProbe.Breaks) {
        scalars = text.unicodeScalars
        self.breaks = breaks
        position = scalars.startIndex
    }

    private var exhausted = false

    mutating func next() -> String? {
        guard !exhausted else { return nil }
        let start = position
        var index = position
        while index < scalars.endIndex {
            let scalar = scalars[index]
            switch breaks {
            case .lineFeed:
                if scalar == "\n" {
                    position = scalars.index(after: index)
                    return strippingCarriageReturn(String(scalars[start ..< index]))
                }
            case .anyLineBreak:
                if Self.isAnyLineBreak(scalar) {
                    var after = scalars.index(after: index)
                    if scalar == "\r", after < scalars.endIndex, scalars[after] == "\n" {
                        after = scalars.index(after: after)
                    }
                    position = after
                    return String(scalars[start ..< index])
                }
            }
            index = scalars.index(after: index)
        }
        // Final line (possibly empty), as `splitLines` yields it.
        exhausted = true
        position = scalars.endIndex
        let last = String(scalars[start ..< scalars.endIndex])
        return breaks == .lineFeed ? strippingCarriageReturn(last) : last
    }

    static func isAnyLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": true
        default: false
        }
    }
}
