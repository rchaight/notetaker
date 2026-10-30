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
    /// `audit.suppressed` line with `result_count=N`), and the file has a hard
    /// size ceiling (one `audit.truncated` line, then nothing until rotation).
    public struct Limits: Sendable {
        public var linesPerEventPerMinute = 120
        public var maxFileBytes: UInt64 = 256 * 1024 * 1024

        public init() {}
    }

    /// Never rate-limited: operator actions and the bound's own summary lines.
    public static let unlimitedEvents: Set<String> = [
        "kill", "server.start", "replica.contaminated", "audit.suppressed", "audit.truncated",
    ]

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

    public init(url: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.limits = limits
        self.now = now
    }

    public func record(_ event: AuditEvent) {
        let moment = now()
        flushEndedWindows(at: moment)
        if !Self.unlimitedEvents.contains(event.event) {
            var window = windows[event.event] ?? Window(start: moment)
            if window.count >= limits.linesPerEventPerMinute {
                window.suppressed += 1
                windows[event.event] = window
                return
            }
            window.count += 1
            windows[event.event] = window
        }
        write(Self.encode(event, at: moment))
    }

    /// Writes one `audit.suppressed` line per event type whose window ended
    /// with refusals. The key space is the fixed set of event names in code.
    private func flushEndedWindows(at moment: Date) {
        for (name, window) in windows where moment.timeIntervalSince(window.start) >= 60 {
            windows[name] = nil
            if window.suppressed > 0 {
                write(Self.encode(
                    AuditEvent(event: "audit.suppressed", resultCount: window.suppressed, reason: name), at: moment
                ))
            }
        }
    }

    private func write(_ line: Data) {
        guard let handle = openIfNeeded() else { return }
        do {
            if bytesWritten == nil {
                bytesWritten = try handle.seekToEnd()
            }
            if let size = bytesWritten, size + UInt64(line.count) > limits.maxFileBytes {
                // Re-check the real size first: logrotate may have truncated the file.
                bytesWritten = try handle.seekToEnd()
                if let real = bytesWritten, real + UInt64(line.count) > limits.maxFileBytes {
                    if !truncated {
                        truncated = true
                        let marker = Self.encode(
                            AuditEvent(event: "audit.truncated", reason: "max_file_bytes"),
                            at: now()
                        )
                        try handle.write(contentsOf: marker)
                        bytesWritten = real + UInt64(marker.count)
                    }
                    return
                }
                truncated = false
            }
            try handle.write(contentsOf: line)
            bytesWritten = (bytesWritten ?? 0) + UInt64(line.count)
        } catch {
            warnOnce("audit write failed: \(error)")
            self.handle = nil
            bytesWritten = nil
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
