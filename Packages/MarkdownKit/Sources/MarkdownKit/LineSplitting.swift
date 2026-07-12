import Foundation

/// Line splitting that survives CRLF. Swift treats "\r\n" as ONE grapheme,
/// so `split(separator: "\n")` never splits CRLF text — every line-oriented
/// API in this package must use this instead. Trailing "\r" stays on each
/// line, so `joined(separator: "\n")` reassembles byte-exactly.
@inlinable
public func splitLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar == "\n" {
            lines.append(String(current))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    lines.append(String(current))
    return lines
}

/// A line with any trailing carriage return removed — for matching; keep the
/// original for byte-exact writes.
@inlinable
public func strippingCarriageReturn(_ line: String) -> String {
    line.hasSuffix("\r") ? String(line.dropLast()) : line
}
