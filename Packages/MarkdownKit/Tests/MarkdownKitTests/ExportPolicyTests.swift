import Foundation
@testable import MarkdownKit
import Testing

// Spec: specs/remote-vault/02-export-policy.md. The tables ARE the contract —
// add rows freely, never remove one. Every locked fixture carries the
// plaintext sentinel so later specs can grep exported trees for leaks.

private let sentinel = "SENTINEL-LOCKED-9f3a"
private let lockedBody = "\(sentinel) secret plaintext\n"
private let plainBody = "Ordinary note body.\n"

private func fillerLines(_ count: Int) -> String {
    (1 ... count).map { "filler line \($0) without a fence" }.joined(separator: "\n") + "\n"
}

/// Stand-in AES-GCM output: 12-byte nonce + "ciphertext" + 16-byte tag.
private let fakeCiphertext: [UInt8] = Array(repeating: 0xA5, count: 12) + Array(sentinel.utf8)
    + Array(repeating: 0x5A, count: 16)
private let fakeSalt: [UInt8] = Array(0 ..< 16)
private var ciphertextB64: String {
    Data(fakeCiphertext).base64EncodedString()
}

/// Byte-for-byte the template of `SecurityKit.LockedNoteFile.render(title:salt:rounds:ciphertext:)`
/// (Packages/SecurityKit/Sources/SecurityKit/NoteCrypto.swift). Hand-rolled
/// because MarkdownKit must not import SecurityKit; spec 03 renders the real one.
private func renderLockedNote(salt: [UInt8] = fakeSalt, rounds: Int = 600_000,
                              ciphertext: [UInt8] = fakeCiphertext) -> String {
    """
    ---
    locked: true
    salt: \(Data(salt).base64EncodedString())
    rounds: \(rounds)
    ---
    \(Data(ciphertext).base64EncodedString())
    """ + "\n"
}

struct ContentCase: Sendable, CustomTestStringConvertible {
    let group: String
    let name: String
    let contents: String
    let expected: ExportDecision

    var testDescription: String {
        "\(group): \(name)"
    }

    init(_ group: String, _ name: String, _ contents: String, _ expected: ExportDecision) {
        self.group = group
        self.name = name
        self.contents = contents
        self.expected = expected
    }
}

private let locked = ExportDecision.excluded(.locked)
private let envelope = ExportDecision.excluded(.lockedEnvelope)
private let unclosed = ExportDecision.excluded(.unclosedFrontmatterWithLockKey)
private let optedOut = ExportDecision.excluded(.optedOut)
private let export = ExportDecision.export

private let contentCases: [ContentCase] = [
    // MARK: spec table — locked variants

    ContentCase("locked", "plain", "---\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("locked", "no space after colon", "---\nlocked:true\n---\n" + lockedBody, locked),
    ContentCase("locked", "quoted key and value", "---\n\"locked\": \"true\"\n---\n" + lockedBody, locked),
    ContentCase("locked", "uppercase", "---\nLocked: TRUE\n---\n" + lockedBody, locked),
    ContentCase("locked", "yes", "---\nlocked: yes\n---\n" + lockedBody, locked),
    ContentCase("locked", "unknown value fails closed", "---\nlocked: maybe\n---\n" + lockedBody, locked),
    ContentCase("locked", "CRLF", "---\r\nlocked: true\r\n---\r\n\(sentinel) secret\r\n", locked),
    ContentCase("locked", "BOM", "\u{FEFF}---\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("locked", "leading blank lines", "\n\n---\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("locked", "... fence", "---\ntitle: x\nlocked: true\n...\n" + lockedBody, locked),
    ContentCase("locked", "locked beats salt", "---\nlocked: true\nsalt: AAAA\n---\n" + lockedBody, locked),
    ContentCase("locked", "unclosed, 300 lines", "---\nlocked: true\n" + fillerLines(300), unclosed),
    ContentCase("locked", "LockedNoteFile.render output", renderLockedNote(), locked),

    // MARK: spec table — envelope

    ContentCase("envelope", "salt only", "---\nsalt: AAAA\n---\n" + lockedBody, envelope),
    ContentCase("envelope", "rounds only", "---\nrounds: 600000\n---\n" + lockedBody, envelope),

    // MARK: spec table — opt-out

    ContentCase("opt-out", "remote: false", "---\nremote: false\n---\n" + plainBody, optedOut),
    ContentCase("opt-out", "remote: \"no\"", "---\nremote: \"no\"\n---\n" + plainBody, optedOut),
    ContentCase("opt-out", "remote: true exports", "---\nremote: true\n---\n" + plainBody, export),

    // MARK: spec table — unlocked look-alikes

    ContentCase("look-alike", "no frontmatter", "# Note\nlocked: true\n", export),
    ContentCase("look-alike", "lock text in body", "---\ntitle: a\n---\n\nlocked: true in the body", export),
    ContentCase("look-alike", "locked: false", "---\nlocked: false\n---\n" + plainBody, export),
    ContentCase("look-alike", "unlocked key", "---\nunlocked: true\n---\n" + plainBody, export),
    ContentCase("look-alike", "value contains the words", "---\ntitle: locked: true\n---\n" + plainBody, export),
    ContentCase("look-alike", "comment line", "---\n# locked: true\n---\n" + plainBody, export),
    ContentCase("look-alike", "unclosed, no lock key", "---\ntitle: x\n" + fillerLines(300), export),
    ContentCase("look-alike", "empty file", "", export),
    ContentCase("look-alike", "plain text with CRLF", "Plain text\r\nwith CRLF\r\nline ends\r\n", export),

    // MARK: added — fences the app's parser reads past (it closes ONLY on an exact `---`)

    ContentCase("added fence", "... before the key, exact close after",
                "---\n...\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("added fence", "indented --- before the key", "---\n  ---\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("added fence", "--- with trailing space before the key",
                "---\ntitle: x\n--- \nlocked: true\n---\n" + lockedBody, locked),
    // Critique round 1: no exact `---` close means the block is unclosed, so a
    // lock key anywhere after the opening fence keeps the note home (was export).
    ContentCase("added fence", "... close, body never exactly closed",
                "---\ntitle: x\n...\nlocked: true in the body\n", unclosed),
    ContentCase("added fence", "critique: ... then lock key, `--` never closes",
                "---\n...\nlocked: true\n--\n", unclosed),
    ContentCase("added fence", "critique: ... then envelope, `--- ` (not exact) before ciphertext",
                "---\n...\nlocked: true\nsalt: X\n--- \n\(ciphertextB64)\n", unclosed),
    ContentCase("added fence", "locked: false under a ... close, no exact close (key presence)",
                "---\nlocked: false\n...\n" + plainBody, unclosed),
    ContentCase("added fence", "lock key after a --- (trailing space) close, no exact close",
                "---\ntitle: x\n--- \nlocked: true\n" + lockedBody, unclosed),
    ContentCase("added fence", "opt-out under a ... close", "---\nremote: false\n...\n" + plainBody, optedOut),
    ContentCase("added fence", "... close, plain body, no exact close", "---\ntitle: x\n...\n" + plainBody, export),
    ContentCase("added fence", "second fenced block in the body",
                "---\ntitle: a\n---\n---\nlocked: true\n---\n" + plainBody, export),
    ContentCase("added fence", "indented opening fence", "  ---  \nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("added fence", "lock-looking block after a first-line heading",
                "# Title\n---\nlocked: true\n---\n" + plainBody, export),

    // MARK: added — encodings and line ends

    ContentCase("added bytes", "double BOM", "\u{FEFF}\u{FEFF}---\nlocked: true\n---\n" + lockedBody, locked),
    ContentCase("added bytes", "BOM-only first line, CRLF",
                "\u{FEFF}\r\n\r\n---\r\nlocked: true\r\n---\r\n" + lockedBody, locked),
    ContentCase("added bytes", "bare CR line ends", "---\rlocked: true\r---\r\(sentinel)\r", locked),
    ContentCase("added bytes", "U+2028 line separators",
                "---\u{2028}locked: true\u{2028}---\u{2028}\(sentinel)", locked),
    ContentCase("added bytes", "NEL line ends", "---\u{85}locked: true\u{85}---\u{85}\(sentinel)", locked),
    ContentCase("added bytes", "mixed CRLF and LF", "---\r\nlocked: true\n---\r\n" + lockedBody, locked),
    ContentCase("added bytes", "zero-width space before key", "---\n\u{200B}locked: true\n---\n" + lockedBody, locked),
    ContentCase("added bytes", "NBSP before colon", "---\nlocked\u{00A0}: true\n---\n" + lockedBody, locked),
    ContentCase("added bytes", "double CR before LF", "---\r\r\nlocked: true\r\r\n---\r\n" + lockedBody, locked),
    ContentCase("added bytes", "bare CR plain text", "Plain\rclassic Mac\rline ends\r", export),
    ContentCase("added bytes", "BOM then heading", "\u{FEFF}# Heading\nlocked: true\n", export),

    // MARK: added — key and value spellings

    ContentCase("added spelling", "indented key", "---\n  locked: true\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "tabs", "---\n\tlocked:\ttrue\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "single-quoted key", "---\n'locked': true\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "LOCKED: Yes", "---\nLOCKED: Yes\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "on", "---\nlocked: on\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "1", "---\nlocked: 1\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "'yes'", "---\nlocked: 'yes'\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "True", "---\nlocked: True\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "~ (YAML null) fails closed", "---\nlocked: ~\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "null fails closed", "---\nlocked: null\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "tagged !!bool", "---\nlocked: !!bool true\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "trailing comment", "---\nlocked: true # keep home\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "false with a comment fails closed",
                "---\nlocked: false # was locked\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "block scalar", "---\nlocked: |\n  true\n---\n" + lockedBody, locked),
    ContentCase(
        "added spelling",
        "value on the next indented line",
        "---\nlocked:\n  true\n---\n" + lockedBody,
        locked
    ),
    ContentCase("added spelling", "nested mapping value", "---\nlocked:\n  salt_hint: x\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "sequence item", "---\n- locked: true\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "flow mapping", "---\n{locked: true}\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "flow mapping, second entry",
                "---\n{title: x, locked: \"yes\"}\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "nested flow mapping", "---\nmeta: {a: {locked: true}}\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "flow mapping value", "---\nlocked: {at: 2026}\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "deep flow nesting",
                "---\n" + String(repeating: "{a: ", count: 500) + "{locked: true}" + String(repeating: "}", count: 500)
                    + "\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "complex key", "---\n? locked\n: true\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "duplicate keys, true last", "---\nlocked: false\nlocked: true\n---\n" + lockedBody,
                locked),
    ContentCase("added spelling", "duplicate keys, false last (app reads false; fail closed)",
                "---\nlocked: true\nlocked: false\n---\n" + lockedBody, locked),
    ContentCase("added spelling", "empty value", "---\nlocked:\n---\n" + plainBody, export),
    ContentCase("added spelling", "empty value then unindented key", "---\nlocked:\ntitle: a\n---\n" + plainBody,
                export),
    ContentCase("added spelling", "\"\"", "---\nlocked: \"\"\n---\n" + plainBody, export),
    ContentCase("added spelling", "'false'", "---\nlocked: 'false'\n---\n" + plainBody, export),
    ContentCase("added spelling", "FALSE", "---\nlocked: FALSE\n---\n" + plainBody, export),
    ContentCase("added spelling", "off", "---\nlocked: off\n---\n" + plainBody, export),
    ContentCase("added spelling", "no", "---\nlocked: no\n---\n" + plainBody, export),
    ContentCase("added spelling", "0", "---\nlocked: 0\n---\n" + plainBody, export),

    // MARK: added — unclosed and long frontmatter

    ContentCase("added unclosed", "short, no fence", "---\nlocked: true", unclosed),
    ContentCase("added unclosed", "salt, no fence", "---\nsalt: x\n", unclosed),
    ContentCase("added unclosed", "locked: false, no fence (key presence)",
                "---\nlocked: false\n" + fillerLines(300), unclosed),
    ContentCase("added unclosed", "lock key after line 200, exact close later",
                "---\ntitle: x\n" + fillerLines(250) + "locked: true\n---\n" + lockedBody, unclosed),
    ContentCase("added unclosed", "lock key early, exact close after line 200",
                "---\nlocked: true\n" + fillerLines(250) + "---\n" + lockedBody, unclosed),
    ContentCase("added unclosed", "close after line 200, no keys", "---\n" + fillerLines(250) + "---\n" + plainBody,
                export),
    ContentCase("added unclosed", "remote: false, no fence (opt-out honoured)",
                "---\nremote: false\n" + fillerLines(300), optedOut),
    ContentCase("added unclosed", "horizontal rule first, no close",
                "---\nA rule opens this note\nand nothing closes it\n", export),

    // MARK: added — LockedNoteFile envelopes after editors and sync tools

    ContentCase("added envelope", "render with CRLF",
                renderLockedNote().replacingOccurrences(of: "\n", with: "\r\n"), locked),
    ContentCase("added envelope", "render with BOM", "\u{FEFF}" + renderLockedNote(), locked),
    ContentCase("added envelope", "render, locked line deleted",
                renderLockedNote().replacingOccurrences(of: "locked: true\n", with: ""), envelope),
    ContentCase("added envelope", "render, locked: false (tampered)",
                renderLockedNote().replacingOccurrences(of: "locked: true", with: "locked: false"), envelope),
    ContentCase("added envelope", "capitalised Salt", "---\nSalt: x\n---\n" + lockedBody, envelope),
    ContentCase("added envelope", "quoted rounds", "---\n\"rounds\": \"600000\"\n---\n" + lockedBody, envelope),
    ContentCase("added envelope", "flow-mapped salt", "---\n{salt: AAAA}\n---\n" + lockedBody, envelope),
    ContentCase("added envelope", "YAML re-serialised",
                "---\nlocked: true\nsalt: 'AAECAwQFBgcICQoLDA0ODw=='\nrounds: 600000\n---\n\(ciphertextB64)\n", locked),
    ContentCase("added envelope", "frontmatter stripped, ciphertext only", ciphertextB64 + "\n", envelope),
    ContentCase("added envelope", "ciphertext only, padded with blank lines", "\n\n\(ciphertextB64)\n\n", envelope),
    ContentCase("added envelope", "ciphertext under replaced frontmatter",
                "---\ntitle: Secret\n---\n\(ciphertextB64)\n", envelope),
    ContentCase("added envelope", "ciphertext after an unclosed fence", "---\n\(ciphertextB64)\n", envelope),
    ContentCase(
        "added envelope",
        "ciphertext under ... fence",
        "---\ntitle: Secret\n...\n\(ciphertextB64)\n",
        envelope
    ),
    // Accepted false positive (documented): a note that is one long base64-alphabet token.
    ContentCase("added envelope", "single 40+ char token note", String(repeating: "Ab0", count: 14) + "\n", envelope),

    // MARK: added — opt-out spellings

    ContentCase("added opt-out", "off", "---\nremote: off\n---\n" + plainBody, optedOut),
    ContentCase("added opt-out", "Remote: NO", "---\nRemote: NO\n---\n" + plainBody, optedOut),
    ContentCase("added opt-out", "0", "---\nremote: 0\n---\n" + plainBody, optedOut),
    ContentCase("added opt-out", "'false'", "---\nremote: 'false'\n---\n" + plainBody, optedOut),
    ContentCase("added opt-out", "CRLF", "---\r\nremote: false\r\n---\r\n" + plainBody, optedOut),
    ContentCase(
        "added opt-out",
        "locked beats opt-out",
        "---\nremote: false\nlocked: true\n---\n" + lockedBody,
        locked
    ),
    ContentCase("added opt-out", "envelope beats opt-out", "---\nremote: false\nsalt: x\n---\n" + lockedBody, envelope),
    ContentCase("added opt-out", "empty remote exports", "---\nremote:\n---\n" + plainBody, export),
    ContentCase("added opt-out", "remote: maybe exports", "---\nremote: maybe\n---\n" + plainBody, export),

    // MARK: added — more look-alikes that must still export

    ContentCase("added look-alike", "notlocked", "---\nnotlocked: true\n---\n" + plainBody, export),
    ContentCase("added look-alike", "locked_at", "---\nlocked_at: 2026-10-29\n---\n" + plainBody, export),
    ContentCase("added look-alike", "salty", "---\nsalty: yes\n---\n" + plainBody, export),
    ContentCase("added look-alike", "tag list", "---\ntags: [locked, salt]\n---\n" + plainBody, export),
    ContentCase("added look-alike", "block tag list", "---\ntags:\n  - locked\n  - salt\n---\n" + plainBody, export),
    ContentCase("added look-alike", "quoted title with comma",
                "---\ntitle: \"a, locked: true\"\n---\n" + plainBody, export),
    ContentCase("added look-alike", "remote_host", "---\nremote_host: false\n---\n" + plainBody, export),
    ContentCase("added look-alike", "keys only in body", "---\ntitle: a\n---\nlocked: true\nsalt: x\n", export),
    ContentCase("added look-alike", "inline base64 in prose",
                "A token aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd29ybGQ= sits in prose.\n", export),
    ContentCase("added look-alike", "short base64 note", "aGVsbG8=\n", export),
    ContentCase("added look-alike", "blank-only file", "\n \n\t\n", export),
    ContentCase("added look-alike", "CLAUDE.md-style note",
                "# Vault guide\n\nNotes may be `locked: true` in frontmatter.\n", export),
]

struct PathCase: Sendable, CustomTestStringConvertible {
    let path: String
    let expected: ExportDecision
    let folders: [String]

    var testDescription: String {
        "\(path.debugDescription) folders=\(folders)"
    }

    init(_ path: String, _ expected: ExportDecision, folders: [String] = []) {
        self.path = path
        self.expected = expected
        self.folders = folders
    }
}

private let specFolders = ["Work Notes/Personnel", "/Private/"]

private let pathCases: [PathCase] = [
    // spec table
    PathCase("_index.md", .excluded(.indexFile)),
    PathCase("Work/_index.md", .excluded(.indexFile)),
    PathCase("A/B/C/_index.md", .excluded(.indexFile)),
    PathCase("index.md", export),
    // SPEC ROW DEVIATION: the spec table lists `_index.md.bak` under export, but
    // spec rule 4 (extension != md) excludes it, and exporting it would ship a
    // backup of a TOC that lists locked titles. Its intent — "not indexFile" —
    // is asserted in `indexBackupIsNotIndexFileButStaysHome`.
    PathCase("_index.md.bak", .excluded(.notMarkdown)),
    PathCase("Notes_index.md", export),
    PathCase("CLAUDE.md", export),
    PathCase(".DS_Store", .excluded(.hiddenPath)),
    PathCase(".Foo.md.icloud", .excluded(.hiddenPath)),
    PathCase(".obsidian/workspace.md", .excluded(.hiddenPath)),
    PathCase("Work/.hidden.md", .excluded(.hiddenPath)),
    PathCase("Foo.md.icloud", .excluded(.notMarkdown)),
    PathCase("notes.txt", .excluded(.notMarkdown)),
    PathCase("img.png", .excluded(.notMarkdown)),
    PathCase("Foo", .excluded(.notMarkdown)),
    PathCase("Foo.MD", export),
    PathCase("Foo.Md", export),
    PathCase("", .excluded(.invalidPath)),
    PathCase("/abs.md", .excluded(.invalidPath)),
    PathCase("../x.md", .excluded(.invalidPath)),
    PathCase("a/../b.md", .excluded(.invalidPath)),
    PathCase("a\\b.md", .excluded(.invalidPath)),
    PathCase("a\u{0}.md", .excluded(.invalidPath)),
    PathCase("Work Notes/Personnel/x.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("Work Notes/Personnel/deep/y.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("Private/z.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("Work Notes/Personnel.md", export, folders: specFolders),
    PathCase("Work Notes/PersonnelX/x.md", export, folders: specFolders),
    // Critique round 1 flipped this spec row (was export): the vault is on a
    // case-insensitive APFS volume, so this IS the excluded folder.
    PathCase("work notes/personnel/x.md", .excluded(.excludedFolder), folders: specFolders),

    // added
    PathCase("_INDEX.md", .excluded(.indexFile)),
    PathCase("Work/_Index.MD", .excluded(.indexFile)),
    PathCase("_index.md", .excluded(.indexFile), folders: specFolders),
    PathCase("Private/_index.md", .excluded(.indexFile), folders: specFolders),
    PathCase("Private/.x.md", .excluded(.hiddenPath), folders: specFolders),
    PathCase("./x.md", .excluded(.hiddenPath)),
    PathCase("a/./b.md", .excluded(.hiddenPath)),
    PathCase(".md", .excluded(.hiddenPath)),
    PathCase(".git/HEAD.md", .excluded(.hiddenPath)),
    PathCase("Work/.Trash/old.md", .excluded(.hiddenPath)),
    PathCase("Foo.", .excluded(.notMarkdown)),
    PathCase("Foo.markdown", .excluded(.notMarkdown)),
    PathCase("Foo.md ", .excluded(.notMarkdown)),
    PathCase("Folder.md/note.txt", .excluded(.notMarkdown)),
    PathCase("Work/a.b.md", export),
    PathCase("/", .excluded(.invalidPath)),
    PathCase("///", .excluded(.invalidPath)),
    PathCase("a//b.md", .excluded(.invalidPath)),
    PathCase("a/b.md/", .excluded(.invalidPath)),
    PathCase("..", .excluded(.invalidPath)),
    PathCase("x/..", .excluded(.invalidPath)),
    PathCase("Private/../Private/z.md", .excluded(.invalidPath), folders: specFolders),
    PathCase("Private//z.md", .excluded(.invalidPath), folders: specFolders),
    PathCase("Private", .excluded(.notMarkdown), folders: specFolders),
    PathCase("PrivateNotes/z.md", export, folders: specFolders),
    PathCase("Notes/Private/z.md", export, folders: specFolders),
    // NFD path vs NFC folder setting: Swift String comparison is canonical.
    PathCase("Cafe\u{301}/x.md", .excluded(.excludedFolder), folders: ["Caf\u{E9}"]),
    PathCase("Caf\u{E9}/x.md", .excluded(.excludedFolder), folders: ["Cafe\u{301}"]),
    PathCase("Private/Sub/x.md", .excluded(.excludedFolder), folders: ["Private//Sub"]),
    PathCase("Private/x.md", export, folders: ["Private//Sub"]),
    // case-insensitive folder matching (critique round 1)
    PathCase("Work Notes/personnel/x.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("WORK NOTES/PERSONNEL/deep/y.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("private/z.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("PRIVATE/Sub/z.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase("x.md", .excluded(.excludedFolder), folders: ["X.MD"]), // path == folder
    PathCase("work notes/personnel.md", export, folders: specFolders),
    PathCase("work notes/personnelx/x.md", export, folders: specFolders),
    PathCase("privatenotes/z.md", export, folders: specFolders),
    // NFC/NFD × case
    PathCase("CAFE\u{301}/x.md", .excluded(.excludedFolder), folders: ["Caf\u{E9}"]),
    PathCase("caf\u{E9}/x.md", .excluded(.excludedFolder), folders: ["CAFE\u{301}"]),
    PathCase("CAF\u{C9}/x.md", .excluded(.excludedFolder), folders: ["cafe\u{301}"]),
    PathCase("Caf\u{E9}/Sub/x.md", .excluded(.excludedFolder), folders: ["cafe\u{301}/SUB"]),
    PathCase("Cafe/x.md", export, folders: ["Caf\u{E9}"]),
    PathCase("Caf\u{E9}/x.md", export, folders: ["Cafe"]),
    PathCase("Private\u{301}/x.md", export, folders: ["Private"]),
    // Critique round 2: a name starting with a combining mark / ZWJ / VS16
    // glues to the preceding "/" as one grapheme. Components must split on
    // scalars (APFS + FileManager report exactly these spellings).
    PathCase("Private/\u{301}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/\u{308}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/\u{200D}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/\u{FE0F}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/Sub/\u{301}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("private/\u{301}x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/\u{301}Sub/x.md", .excluded(.excludedFolder), folders: ["Private"]),
    PathCase("Private/\u{301}x.md", .excluded(.excludedFolder), folders: specFolders),
    PathCase(".\u{301}hidden.md", .excluded(.hiddenPath)),
    PathCase("Work/.\u{301}hidden.md", .excluded(.hiddenPath)),
    PathCase("Work/.\u{200D}x.md", .excluded(.hiddenPath)),
    PathCase(".\u{FE0F}obsidian/x.md", .excluded(.hiddenPath)),
    PathCase("/\u{301}x.md", .excluded(.invalidPath)),
    PathCase("x.\u{301}md", .excluded(.notMarkdown)),
    PathCase("x.md\u{301}", .excluded(.notMarkdown)),
    PathCase("Work/\u{301}x.md", export), // a legal name, not hidden
    // folder entries that themselves contain combining marks
    PathCase("Work/\u{301}Personnel/x.md", .excluded(.excludedFolder), folders: ["Work/\u{301}Personnel"]),
    PathCase("work/\u{301}PERSONNEL/x.md", .excluded(.excludedFolder), folders: ["Work/\u{301}Personnel"]),
    PathCase("Work/Personnel/x.md", export, folders: ["Work/\u{301}Personnel"]),
    PathCase("M\u{E4}rz/x.md", .excluded(.excludedFolder), folders: ["Ma\u{308}rz"]),
    PathCase("MA\u{308}RZ/x.md", .excluded(.excludedFolder), folders: ["M\u{E4}rz"]),
    PathCase("Marz/x.md", export, folders: ["Ma\u{308}rz"]),
    // full case folding that caseInsensitiveCompare misses: "ᾈ" folds to "ἀι"
    PathCase("\u{1F00}\u{03B9}/x.md", .excluded(.excludedFolder), folders: ["\u{1F88}"]),
    PathCase("\u{1F88}/x.md", .excluded(.excludedFolder), folders: ["\u{1F00}\u{03B9}"]),
]

struct ExportPolicyTests {
    let policy = ExportPolicy()

    // MARK: tables

    @Test(arguments: contentCases)
    func contentTable(_ row: ContentCase) {
        #expect(policy.decide(relativePath: "Note.md", contents: row.contents) == row.expected)
    }

    @Test(arguments: contentCases)
    func dataOverloadAgreesWithString(_ row: ContentCase) {
        #expect(policy.decide(relativePath: "Note.md", contents: Data(row.contents.utf8)) == row.expected)
    }

    @Test(arguments: contentCases)
    func looksLockedAgreesWithDecide(_ row: ContentCase) {
        let lockedReasons: Set<ExportExclusionReason> = [.locked, .lockedEnvelope, .unclosedFrontmatterWithLockKey]
        var expectedLocked = false
        if case let .excluded(reason) = row.expected {
            expectedLocked = lockedReasons.contains(reason)
        }
        #expect(ExportPolicy.looksLocked(row.contents) == expectedLocked)
    }

    @Test(arguments: pathCases)
    func pathTable(_ row: PathCase) {
        let policy = ExportPolicy(excludedFolders: row.folders)
        #expect(policy.decide(relativePath: row.path) == row.expected)
        // The content gate never overrides a path exclusion, and a path that
        // passes still has its contents checked.
        let lockedNote = "---\nlocked: true\n---\n" + lockedBody
        let full = policy.decide(relativePath: row.path, contents: lockedNote)
        #expect(full == (row.expected == .export ? locked : row.expected))
        let fullData = policy.decide(relativePath: row.path, contents: Data([0xFF, 0xFE, 0x00, 0x80]))
        #expect(fullData == (row.expected == .export ? .excluded(.undecodable) : row.expected))
    }

    // MARK: undecodable

    @Test func invalidUTF8IsUndecodable() {
        #expect(policy
            .decide(relativePath: "x.md", contents: Data([0xFF, 0xFE, 0x00, 0x80])) == .excluded(.undecodable))
    }

    @Test func otherUndecodableBytes() throws {
        // UTF-16/32 without a BOM is VALID UTF-8 (ASCII interleaved with NULs);
        // without the NUL rule it would export with its frontmatter unseen.
        let utf16 = try #require(("---\nlocked: true\n---\n" + lockedBody).data(using: .utf16LittleEndian))
        let utf32 = try #require(("---\nlocked: true\n---\n" + lockedBody).data(using: .utf32LittleEndian))
        let cases: [Data] = [
            Data([0xFF, 0xFE]) + utf16, // UTF-16LE with BOM
            utf16, // UTF-16LE without BOM
            Data("---\nlocked: true\n---\n".utf8) + Data([0xE2, 0x82]), // truncated sequence
            Data([0xC0, 0xAF]) + Data("x.md".utf8), // overlong "/"
            Data([0xED, 0xA0, 0x80]), // UTF-16 surrogate encoded as UTF-8
            utf32, // UTF-32LE without BOM: also valid UTF-8 + NULs
            Data("---\nlocked: true\n---\n".utf8) + Data([0x00]), // NUL in otherwise valid UTF-8
        ]
        for data in cases {
            #expect(policy.decide(relativePath: "x.md", contents: data) == .excluded(.undecodable), "\(Array(data))")
        }
    }

    @Test func nulInStringIsUndecodable() {
        #expect(policy.decide(relativePath: "x.md", contents: "plain\u{0}text") == .excluded(.undecodable))
        #expect(!ExportPolicy.looksLocked("plain\u{0}text"))
    }

    @Test func indexBackupIsNotIndexFileButStaysHome() {
        // Spec row intent: `_index.md.bak` is not the index file…
        #expect(policy.decide(relativePath: "_index.md.bak") != .excluded(.indexFile))
        // …but it is not markdown either, so it never leaves (spec rule 4).
        #expect(policy.decide(relativePath: "_index.md.bak") == .excluded(.notMarkdown))
    }

    // MARK: fixed facts

    @Test func versionIsPinned() {
        #expect(ExportPolicy.version == 1)
        #expect(ExportPolicy.indexFileName == "_index.md")
    }

    @Test func reasonRawValuesArePinned() {
        // Written into manifest.json counters; renaming one breaks readers.
        #expect(ExportExclusionReason.allCases.map(\.rawValue) == [
            "invalidPath", "indexFile", "hiddenPath", "notMarkdown", "excludedFolder",
            "undecodable", "locked", "lockedEnvelope", "optedOut", "unclosedFrontmatterWithLockKey",
        ])
    }

    @Test func pathGateRunsBeforeContents() {
        #expect(policy.decide(relativePath: "_index.md", contents: "---\nlocked: true\n---") == .excluded(.indexFile))
        #expect(policy.decide(relativePath: ".x.md", contents: "---\nlocked: true\n---") == .excluded(.hiddenPath))
        #expect(policy.decide(relativePath: "x.txt", contents: Data([0xFF])) == .excluded(.notMarkdown))
    }

    @Test func excludedFoldersAreNormalised() {
        let policy = ExportPolicy(excludedFolders: [
            "  /Work Notes/Personnel/ ", "", "/", " ", "Private//Sub", "a/../b", "../escape", "./c",
        ])
        #expect(policy.excludedFolders == ["Work Notes/Personnel", "Private/Sub", "b", "c"])
        #expect(ExportPolicy(excludedFolders: ["Work Notes/Personnel", "/Private/"]).excludedFolders
            == ["Work Notes/Personnel", "Private"])
    }

    @Test func folderNormalisationSplitsOnScalars() {
        // "/\u{301}" is one grapheme; normalisation must still see both slashes.
        let policy = ExportPolicy(excludedFolders: ["/\u{301}A/./B/", "Private/\u{301}Sub/../Other"])
        #expect(policy.excludedFolders == ["\u{301}A/B", "Private/Other"])
    }

    @Test func emptyFolderEntriesNeverExcludeEverything() {
        let policy = ExportPolicy(excludedFolders: ["", "/", "  "])
        #expect(policy.decide(relativePath: "Note.md") == .export)
    }

    // MARK: performance

    @Test func tenThousandDecisionsOnFiftyKilobyteNote() {
        let paragraph = "Some **bold** prose with `code`, a [link](https://example.com) and filler words.\n"
            + "- [ ] a task >2026-07-15 !p2 #work\n\n"
        var note = "---\ntitle: Big note\ntags: [work, notes]\n---\n# Big Note\n\n"
        while note.utf8.count < 50000 {
            note += paragraph
        }
        let data = Data(note.utf8)
        #expect(data.count >= 50000)
        let start = ContinuousClock.now
        var exported = 0
        for _ in 0 ..< 10000 where policy.decide(relativePath: "Work/Big note.md", contents: data) == .export {
            exported += 1
        }
        let elapsed = ContinuousClock.now - start
        #expect(exported == 10000)
        #expect(elapsed < .seconds(1), "10,000 decisions took \(elapsed)")
    }

    // MARK: fuzz-ish

    @Test func randomBytesNeverTrap() {
        var rng = SplitMix64(seed: 0x9F3A_2026_1029)
        let fragments = ["---", "...", "\n", "\r", "\r\n", "locked", "salt", "rounds", "remote", ":", " ", "true",
                         "false", "\"", "'", "{", "}", ",", "- ", "? ", "#", "\u{FEFF}", "\u{2028}", "QUJD", "=="]
        for iteration in 0 ..< 200 {
            var bytes: [UInt8] = []
            let length = Int(rng.next() % 600)
            while bytes.count < length {
                if iteration.isMultiple(of: 2) {
                    bytes.append(UInt8(truncatingIfNeeded: rng.next()))
                } else {
                    bytes += Array(fragments[Int(rng.next() % UInt64(fragments.count))].utf8)
                }
            }
            let data = Data(bytes)
            let decision = policy.decide(relativePath: "fuzz.md", contents: data)
            // Foundation's decoder must agree with the stdlib one the policy uses.
            #expect((String(data: data, encoding: .utf8) == nil) == (String(validating: data, as: UTF8.self) == nil))
            if let text = String(validating: data, as: UTF8.self) {
                #expect((decision == .excluded(.undecodable)) == text.utf8.contains(0))
                #expect(decision == policy.decide(relativePath: "fuzz.md", contents: text))
                _ = ExportPolicy.looksLocked(text)
            } else {
                #expect(decision == .excluded(.undecodable))
            }
        }
    }
}

/// Deterministic RNG so the fuzz corpus is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
