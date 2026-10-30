import Foundation
import HTTPTypes
import Hummingbird
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

public typealias OAuthClock = @Sendable () -> Date

/// Secrets, hashes and comparisons. Every secret this server mints comes from
/// `SystemRandomNumberGenerator` (the OS CSPRNG on both platforms).
enum OAuthCrypto {
    /// 32 random bytes, base64url without padding (43 characters).
    static func token(bytes count: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(bytes)
    }

    static func sha256(_ text: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(text.utf8)))
    }

    /// What the store keys tokens and codes by. Lookups are SQLite equality on
    /// this digest: an attacker timing them learns (at most) a prefix of the
    /// SHA-256 of a guess, which says nothing about any live 256-bit token.
    static func storageHash(_ secret: String) -> String {
        Hashing.sha256Hex(Data(secret.utf8))
    }

    /// RFC 7636 S256: `base64url(SHA256(ASCII(verifier)))`.
    static func pkceChallenge(for verifier: String) -> String {
        Base64URL.encode(sha256(verifier))
    }

    /// Constant-time equality for secrets. Both sides are hashed first, so the
    /// loop always runs over 32 bytes and neither length nor content leaks.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEquals(sha256(lhs), sha256(rhs))
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0 ..< lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

enum Base64URL {
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only `[A-Za-z0-9_-]`, no padding, no whitespace.
    static func decode(_ text: some StringProtocol) -> Data? {
        guard text.count % 4 != 1, text.unicodeScalars.allSatisfy(isAlphabet) else { return nil }
        var base64 = String(text).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }

    static func isAlphabet(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "-", "_": true
        default: false
        }
    }
}

enum OAuthText {
    /// RFC 3986 unreserved: `[A-Za-z0-9._~-]` (also the PKCE alphabet).
    static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "-", ".", "_", "~": true
        default: false
        }
    }

    /// RFC 7636 §4.1/4.2: 43–128 unreserved characters.
    static func isPKCEValue(_ value: String) -> Bool {
        (43 ... 128).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(isUnreserved)
    }

    /// Our own opaque tokens: exactly 43 base64url characters.
    static func isOurTokenShape(_ value: some StringProtocol) -> Bool {
        value.unicodeScalars.count == 43 && value.unicodeScalars.allSatisfy(Base64URL.isAlphabet)
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// https, or http to a loopback host (only the fake IdP in tests uses that).
    static func isAcceptableEndpoint(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil
        else { return false }
        if parts.scheme == "https" {
            return true
        }
        return parts.scheme == "http" && (host == "127.0.0.1" || host == "localhost")
    }

    /// `application/x-www-form-urlencoded` value encoding.
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    }

    static func htmlEscape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// A parsed query string or `application/x-www-form-urlencoded` body.
/// RFC 6749 §3.1: an empty value is treated as omitted, and a parameter must
/// not appear more than once (`value(_:)` reports duplicates as `.duplicate`).
struct FormData: Sendable {
    enum Lookup: Equatable {
        case absent
        case one(String)
        case duplicate
    }

    static let maxPairs = 64

    private(set) var values: [String: [String]] = [:]

    /// nil for malformed input: bad percent escapes, invalid UTF-8, too many pairs.
    static func parse(_ raw: String) -> FormData? {
        var form = FormData()
        guard !raw.isEmpty else { return form }
        let pairs = raw.split(separator: "&", omittingEmptySubsequences: true)
        guard pairs.count <= maxPairs else { return nil }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]), !name.isEmpty else { return nil }
            let value = parts.count > 1 ? decode(parts[1]) : ""
            guard let value else { return nil }
            if value.isEmpty {
                continue
            }
            form.values[name, default: []].append(value)
        }
        return form
    }

    private static func decode(_ text: Substring) -> String? {
        String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    func value(_ name: String) -> Lookup {
        guard let found = values[name] else { return .absent }
        return found.count == 1 ? .one(found[0]) : .duplicate
    }

    /// The single value, or nil when absent; `duplicate` names the offending key.
    func single(_ name: String) throws(DuplicateParameter) -> String? {
        switch value(name) {
        case .absent: nil
        case let .one(value): value
        case .duplicate: throw DuplicateParameter(name: name)
        }
    }

    struct DuplicateParameter: Error {
        let name: String
    }
}

/// Response builders. Every OAuth response is `no-store`; HTML pages carry a
/// strict CSP that forbids framing (clickjacking on the consent page) and scripts.
enum OAuthHTTP {
    static func html(_ status: HTTPResponse.Status, title: String, message: String, extra: String = "") -> Response {
        let page = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(OAuthText.htmlEscape(title))</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem;color:#1d1d1f;background:#fff}
        h1{font-size:1.3rem}p{line-height:1.5}button{font-size:1rem;padding:.6rem 1.4rem;margin-right:.6rem;border-radius:.5rem;border:1px solid #888;background:#f5f5f7}
        button.allow{background:#0a66d8;color:#fff;border-color:#0a66d8}.warn{font-size:.9rem;color:#6e6e73}
        @media (prefers-color-scheme: dark){body{background:#1d1d1f;color:#f5f5f7}.warn{color:#a1a1a6}button{background:#2c2c2e;color:#f5f5f7}}
        </style></head>
        <body><h1>\(OAuthText.htmlEscape(title))</h1><p>\(message)</p>\(extra)</body></html>
        """
        var headers = securityHeaders()
        headers[.contentType] = "text/html; charset=utf-8"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: page)))
    }

    static func redirect(to location: String) -> Response {
        var headers = securityHeaders()
        headers[.location] = location
        return Response(status: .found, headers: headers)
    }

    static func json(_ status: HTTPResponse.Status, _ object: [String: Any],
                     headers extra: HTTPFields = [:]) -> Response {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ))
            ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[OAuthHTTP.pragma] = "no-cache"
        headers.append(contentsOf: extra)
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// RFC 6749 §5.2 error body.
    static func oauthError(
        _ status: HTTPResponse.Status, _ code: String, _ description: String, headers: HTTPFields = [:]
    ) -> Response {
        json(status, ["error": code, "error_description": description], headers: headers)
    }

    static let pragma = HTTPField.Name("Pragma")!

    static func securityHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[OAuthHTTP.pragma] = "no-cache"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        headers[.xContentTypeOptions] = "nosniff"
        headers[.contentSecurityPolicy] =
            "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
        return headers
    }

    /// `redirect_uri` + `?`/`&` + the parameters (the URI was validated before this).
    static func appendQuery(_ base: String, _ pairs: [(String, String)]) -> String {
        base + (base.contains("?") ? "&" : "?") + OAuthText.formEncode(pairs)
    }
}
