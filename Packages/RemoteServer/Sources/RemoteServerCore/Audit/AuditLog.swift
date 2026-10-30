import Foundation

/// One audit line. The type itself is the allowlist: there is no field for
/// note bodies, snippets or titles, and no way to log a token or header value.
public struct AuditEvent: Sendable {
    public var event: String
    public var tool: String?
    /// Filtered through `AuditLog.allowedArgKeys` and truncated on write.
    public var args: [String: String]
    public var resultCount: Int?
    public var bytes: Int?
    public var ms: Int?
    public var status: String?
    public var clientID: String?
    public var tokenFamily: String?
    public var ip: String?
    public var reason: String?

    public init(
        event: String, tool: String? = nil, args: [String: String] = [:], resultCount: Int? = nil,
        bytes: Int? = nil, ms: Int? = nil, status: String? = nil, clientID: String? = nil,
        tokenFamily: String? = nil, ip: String? = nil, reason: String? = nil
    ) {
        self.event = event
        self.tool = tool
        self.args = args
        self.resultCount = resultCount
        self.bytes = bytes
        self.ms = ms
        self.status = status
        self.clientID = clientID
        self.tokenFamily = tokenFamily
        self.ip = ip
        self.reason = reason
    }
}

/// Append-only JSONL audit log (`O_APPEND`, written per line, never buffered).
public actor AuditLog {
    /// Top-level keys a line may contain.
    public static let allowedKeys: Set<String> = [
        "ts", "event", "tool", "args", "result_count", "bytes", "ms", "status",
        "client_id", "token_family", "ip", "reason",
    ]
    /// Keys allowed inside `args`.
    public static let allowedArgKeys: Set<String> = [
        "path", "query", "kind", "label", "assignee", "range", "from", "to", "calendar", "limit",
        // Spec 07 `login.denied`: a foreign account is described only by these two.
        "email_domain", "email_hash8",
    ]
    /// Logged values stay strictly under 256 characters.
    public static let maxValueLength = 255

    /// Flood bounds. Unauthenticated traffic can trigger audit lines, so every
    /// event type is capped per minute (excess counted, then one
    /// `audit.suppressed` line with `result_count=N`), and the file has a size
    /// ceiling: past it, one `audit.truncated` line, then only ceiling-exempt
    /// events until the file is rotated (logrotate: see
    /// `deploy/remote-vault/ct/logrotate.notetaker-remote` — `daily`,
    /// `copytruncate`, `maxsize 64M`, `rotate 90`, `compress`, `missingok`,
    /// `notifempty`). Both copytruncate (size shrinks) and rename+create (inode
    /// changes) are detected and writing resumes in the live file.
    public struct Limits: Sendable {
        public var linesPerEventPerMinute = 120
        public var maxFileBytes: UInt64 = 256 * 1024 * 1024

        public init() {}
    }

    /// Never rate-limited: operator actions and the bound's own summary lines.
    public static let unlimitedEvents: Set<String> = [
        "kill", "server.start", "replica.contaminated", "audit.suppressed", "audit.truncated",
    ]

    /// The anomaly cues: written even past the size ceiling. Their growth stays
    /// bounded without it: `login.denied` ≤ 20/min (Google-exchange cap) and
    /// `refresh.reuse` / `code.reuse` ≤ 120/min each (per-event cap; each also
    /// needs a real, already-used secret); `kill` is an operator action. Worst
    /// case past the ceiling ≈ 260 lines/min ≈ 65 KB/min, and logrotate's
    /// `maxsize 64M` rotates the file long before that matters.
    public static let forensicEvents: Set<String> = ["login.denied", "refresh.reuse", "code.reuse", "kill"]

    /// Events whose `reason` gets its own per-minute bucket, so junk cannot
    /// crowd out the real thing (`revoke` reason=unknown vs the owner's revokes).
    static let reasonBucketedEvents: Set<String> = ["revoke"]

    /// How often the live path is compared with the open file (rename rotation).
    static let rotationCheckInterval: TimeInterval = 60

    private struct Window {
        var start: Date
        var count = 0
        var suppressed = 0
    }

    private let url: URL
    private var handle: FileHandle?
    private var warned = false
    private let now: @Sendable () -> Date
    private let limits: Limits
    private var windows: [String: Window] = [:]
    private var bytesWritten: UInt64?
    private var truncated = false
    private var lastRotationCheck: Date = .distantPast

    public init(url: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.limits = limits
        self.now = now
    }

    public func record(_ event: AuditEvent) {
        let moment = now()
        flushEndedWindows(at: moment)
        if !Self.unlimitedEvents.contains(event.event) {
            let key = Self.bucketKey(event)
            var window = windows[key] ?? Window(start: moment)
            if window.count >= limits.linesPerEventPerMinute {
                window.suppressed += 1
                windows[key] = window
                return
            }
            window.count += 1
            windows[key] = window
        }
        write(Self.encode(event, at: moment), exempt: Self.isCeilingExempt(event.event))
    }

    /// Writes every pending `audit.suppressed` summary now (graceful shutdown).
    public func flush() {
        let moment = now()
        for (key, window) in windows where window.suppressed > 0 {
            windows[key] = Window(start: window.start, count: window.count, suppressed: 0)
            write(Self.summary(key, window.suppressed, at: moment), exempt: true)
        }
    }

    static func bucketKey(_ event: AuditEvent) -> String {
        guard reasonBucketedEvents.contains(event.event), let reason = event.reason else { return event.event }
        return event.event + "|" + reason
    }

    static func isCeilingExempt(_ event: String) -> Bool {
        unlimitedEvents.contains(event) || forensicEvents.contains(event)
    }

    private static func summary(_ key: String, _ count: Int, at moment: Date) -> Data {
        encode(AuditEvent(event: "audit.suppressed", resultCount: count, reason: key), at: moment)
    }

    /// Writes one `audit.suppressed` line per bucket whose window ended with
    /// refusals. The key space is the fixed set of event names (and revoke
    /// reasons) in code.
    private func flushEndedWindows(at moment: Date) {
        for (key, window) in windows where moment.timeIntervalSince(window.start) >= 60 {
            windows[key] = nil
            if window.suppressed > 0 {
                write(Self.summary(key, window.suppressed, at: moment), exempt: true)
            }
        }
    }

    private func write(_ line: Data, exempt: Bool) {
        let moment = now()
        // Rotation check: at most once a minute normally; on every write while
        // the ceiling has tripped (two stat calls), so the first line after a
        // rename+create rotation — junk or forensic — lands in the new file.
        if truncated || moment.timeIntervalSince(lastRotationCheck) >= Self.rotationCheckInterval {
            reopenIfRotated(at: moment)
        }
        guard let handle = openIfNeeded() else { return }
        do {
            if bytesWritten == nil {
                bytesWritten = try handle.seekToEnd()
            }
            if !exempt, let size = bytesWritten, size + UInt64(line.count) > limits.maxFileBytes {
                // Over the ceiling: first make sure we are not looking at a file
                // logrotate already replaced (rename) or emptied (copytruncate).
                reopenIfRotated(at: moment)
                guard let current = openIfNeeded() else { return }
                bytesWritten = try current.seekToEnd()
                if let real = bytesWritten, real + UInt64(line.count) > limits.maxFileBytes {
                    if !truncated {
                        truncated = true
                        let marker = Self.encode(
                            AuditEvent(event: "audit.truncated", reason: "max_file_bytes"),
                            at: moment
                        )
                        try current.write(contentsOf: marker)
                        bytesWritten = real + UInt64(marker.count)
                    }
                    return
                }
                truncated = false
                try current.write(contentsOf: line)
                bytesWritten = (bytesWritten ?? 0) + UInt64(line.count)
                return
            }
            try handle.write(contentsOf: line)
            bytesWritten = (bytesWritten ?? 0) + UInt64(line.count)
        } catch {
            warnOnce("audit write failed: \(error)")
            self.handle = nil
            bytesWritten = nil
        }
    }

    /// Rename rotation: if the path no longer names the open file (different
    /// inode/device, or missing), close it; the next write reopens (creating) the path.
    private func reopenIfRotated(at moment: Date) {
        lastRotationCheck = moment
        guard let handle else { return }
        var open = stat()
        var live = stat()
        let openOK = fstat(handle.fileDescriptor, &open) == 0
        let liveOK = stat(url.path, &live) == 0
        if !openOK || !liveOK || open.st_ino != live.st_ino || open.st_dev != live.st_dev {
            try? handle.close()
            self.handle = nil
            bytesWritten = nil
            truncated = false
        }
    }

    // MARK: - Encoding (pure, unit-tested)

    static func encode(_ event: AuditEvent, at date: Date) -> Data {
        var object: [String: Any] = [
            "ts": DateParsing.string(date),
            "event": truncate(event.event),
        ]
        if let tool = event.tool {
            object["tool"] = truncate(tool)
        }
        let args = event.args.filter { allowedArgKeys.contains($0.key) }.mapValues(truncate)
        if !args.isEmpty {
            object["args"] = args
        }
        if let count = event.resultCount {
            object["result_count"] = count
        }
        if let bytes = event.bytes {
            object["bytes"] = bytes
        }
        if let ms = event.ms {
            object["ms"] = ms
        }
        if let status = event.status {
            object["status"] = truncate(status)
        }
        if let clientID = event.clientID {
            object["client_id"] = truncate(clientID)
        }
        if let family = event.tokenFamily {
            object["token_family"] = truncate(family)
        }
        if let ip = event.ip {
            object["ip"] = truncate(ip)
        }
        if let reason = event.reason {
            object["reason"] = truncate(reason)
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"event\":\"audit.encode_failed\"}".utf8)
        data.append(0x0A)
        return data
    }

    static func truncate(_ value: String) -> String {
        value.count <= maxValueLength ? value : String(value.prefix(maxValueLength))
    }

    // MARK: - File handling

    private func openIfNeeded() -> FileHandle? {
        if let handle {
            return handle
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o750]
        )
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o640)
        guard descriptor >= 0 else {
            warnOnce("cannot open audit log at \(url.path)")
            return nil
        }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle = opened
        return opened
    }

    private func warnOnce(_ message: String) {
        guard !warned else { return }
        warned = true
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// What `status` reports about the audit file itself.
public struct AuditFileSummary: Sendable, Equatable {
    /// An `audit.truncated` line exists in the current file (detail lines were dropped).
    public var truncated = false
    /// Sum of `audit.suppressed` counts over the last 24 hours.
    public var suppressedLastDay = 0

    /// Streams the whole file in 1 MB chunks (bounded memory).
    public static func scan(_ url: URL, now: Date = Date()) -> AuditFileSummary {
        var summary = AuditFileSummary()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return summary }
        defer { try? handle.close() }
        let since = now.addingTimeInterval(-86400)
        var carry = Data()
        func consume(_ line: Data) {
            guard let text = String(data: line, encoding: .utf8) else { return }
            if text.contains("\"event\":\"audit.truncated\"") {
                summary.truncated = true
            } else if text.contains("\"event\":\"audit.suppressed\""),
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let ts = (object["ts"] as? String).flatMap(DateParsing.iso8601), ts >= since,
                      let count = object["result_count"] as? Int {
                summary.suppressedLastDay += count
            }
        }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            while let newline = carry.firstIndex(of: 0x0A) {
                consume(carry[carry.startIndex ..< newline])
                carry = Data(carry[carry.index(after: newline)...])
            }
        }
        if !carry.isEmpty {
            consume(carry)
        }
        return summary
    }

    public var statusLine: String {
        "audit: \(truncated ? "TRUNCATED (size ceiling hit; check logrotate)" : "not truncated"), "
            + "\(suppressedLastDay) line(s) suppressed by the per-minute cap in the last 24 h"
    }
}
