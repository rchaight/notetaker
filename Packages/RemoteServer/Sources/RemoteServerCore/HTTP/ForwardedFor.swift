import Foundation
import Synchronization

/// Strict parsing of the client address tailscaled appends to `X-Forwarded-For`.
/// Accepted forms of the LAST hop: a bare IPv4, a bare IPv6, `IPv4:port`, or
/// `[IPv6]:port` — the port is always dropped, so the limiter key is per client
/// address, never per connection. Addresses are validated with `inet_pton` and
/// re-printed canonically (one key per address however it is spelled). Anything
/// else (`unknown`, hostnames, junk) is no address at all, and is counted so a
/// misbehaving proxy shows up in the audit log and `status` (stage 2 must
/// verify what tailscaled/Funnel actually sends).
public enum ForwardedFor {
    static let unparseable = Mutex(0)

    /// Takes the count of unparseable headers seen since the last call.
    public static func drainUnparseable() -> Int {
        unparseable.withLock { value in
            defer { value = 0 }
            return value
        }
    }

    /// The client address of the last hop, or nil (and counted) when it is not one.
    static func lastHop(_ lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        let last = lines.joined(separator: ",").split(separator: ",", omittingEmptySubsequences: false).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if let address = parse(last) {
            return address
        }
        unparseable.withLock { $0 += 1 }
        return nil
    }

    static func parse(_ hop: String) -> String? {
        guard !hop.isEmpty, hop.utf8.count <= 64 else { return nil }
        if hop.hasPrefix("[") {
            guard let close = hop.firstIndex(of: "]") else { return nil }
            let inside = String(hop[hop.index(after: hop.startIndex) ..< close])
            let rest = hop[hop.index(after: close)...]
            guard rest.isEmpty || isPort(rest.dropFirst()) && rest.first == ":" else { return nil }
            return canonical(inside, family: AF_INET6)
        }
        if let v4 = canonical(hop, family: AF_INET) {
            return v4
        }
        let colons = hop.count { $0 == ":" }
        if colons == 1, let colon = hop.firstIndex(of: ":"), isPort(hop[hop.index(after: colon)...]) {
            return canonical(String(hop[..<colon]), family: AF_INET)
        }
        return canonical(hop, family: AF_INET6)
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard (1 ... 5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text) else {
            return false
        }
        return (1 ... 65535).contains(port)
    }

    /// `inet_pton` then `inet_ntop`: nil unless `text` is exactly an address of `family`.
    private static func canonical(_ text: String, family: Int32) -> String? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }) else {
            return nil
        }
        var storage = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, text, &storage) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard inet_ntop(family, storage, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Sum of `xff.unparseable` counts in the audit log's last `maxBytes` (for `status`).
    public static func unparseableInAudit(at url: URL, maxBytes: Int = 4 << 20) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var total = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
            where line.contains("\"event\":\"xff.unparseable\"") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let count = object["result_count"] as? Int {
                total += count
            }
        }
        return total
    }
}
