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
    ]
    /// Logged values stay strictly under 256 characters.
    public static let maxValueLength = 255

    private let url: URL
    private var handle: FileHandle?
    private var warned = false
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func record(_ event: AuditEvent) {
        let line = Self.encode(event, at: now())
        guard let handle = openIfNeeded() else { return }
        do {
            try handle.write(contentsOf: line)
        } catch {
            warnOnce("audit write failed: \(error)")
            self.handle = nil
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
