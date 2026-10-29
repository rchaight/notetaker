import Foundation

/// Environment → validated configuration. The single place `NR_*` variables
/// are read (spec 07 consumes the OAuth keys from here rather than re-parsing).
public struct RemoteConfig: Sendable, Equatable {
    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalid(String, String)

        public var description: String {
            switch self {
            case let .missing(name): "\(name) is required"
            case let .invalid(name, why): "\(name) is invalid: \(why)"
            }
        }
    }

    /// OAuth keys: parsed here, validated by spec 07.
    public struct OAuthKeys: Sendable, Equatable {
        public var allowedEmail: String?
        public var clientID: String?
        public var redirectURIs: [String]
        public var allowLoopback: Bool
        public var googleClientID: String?
        public var googleClientSecret: String?
    }

    /// `https://host` — no path, no trailing slash.
    public let publicURL: String
    /// `publicURL + "/mcp"` — the RFC 9728 `resource`.
    public let resourceURL: String
    public let bindHost: String
    public let bindPort: Int
    public let replicaDir: URL
    public let stateDir: URL
    public let auditLog: URL
    public let allowedHosts: [String]
    public let trustForwardedFor: Bool
    public let anthropicIPAllowlist: Bool
    public let staleAfterHours: Int
    public let oauth: OAuthKeys

    public var metadataURL: String {
        publicURL + "/.well-known/oauth-protected-resource/mcp"
    }

    public var vaultDir: URL {
        replicaDir.appendingPathComponent("vault", isDirectory: true)
    }

    public var manifestURL: URL {
        replicaDir.appendingPathComponent("manifest.json")
    }

    public var calendarURL: URL {
        replicaDir.appendingPathComponent("calendar-remote.json")
    }

    public var disabledMarkerURL: URL {
        replicaDir.appendingPathComponent("DISABLED")
    }

    public var indexURL: URL {
        stateDir.appendingPathComponent("index.sqlite")
    }

    public var tokensURL: URL {
        stateDir.appendingPathComponent("tokens.sqlite")
    }

    public init(environment env: [String: String]) throws {
        guard let rawURL = env["NR_PUBLIC_URL"]?.trimmingCharacters(in: .whitespaces), !rawURL.isEmpty else {
            throw ConfigError.missing("NR_PUBLIC_URL")
        }
        var trimmed = rawURL
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let components = URLComponents(string: trimmed), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil
        else {
            throw ConfigError.invalid("NR_PUBLIC_URL", "must be https://<host> with no path, query or credentials")
        }
        publicURL = trimmed
        resourceURL = trimmed + "/mcp"

        let (bindHost, bindPort) = try Self.parseBind(env["NR_BIND"] ?? "127.0.0.1:8787")
        if !Self.isLoopback(bindHost), env["NR_ALLOW_NONLOOPBACK_BIND"] != "1" {
            throw ConfigError.invalid("NR_BIND", "must be a loopback address (tailscaled fronts this service)")
        }
        self.bindHost = bindHost
        self.bindPort = bindPort

        replicaDir = URL(fileURLWithPath: env["NR_REPLICA_DIR"] ?? "/srv/replica/inbox", isDirectory: true)
        stateDir = URL(fileURLWithPath: env["NR_STATE_DIR"] ?? "/var/lib/notetaker-remote", isDirectory: true)
        auditLog = URL(fileURLWithPath: env["NR_AUDIT_LOG"] ?? "/var/log/notetaker-remote/audit.jsonl")

        let publicAuthority = components.port.map { "\(host):\($0)" } ?? host
        if let hosts = env["NR_ALLOWED_HOSTS"], !hosts.trimmingCharacters(in: .whitespaces).isEmpty {
            allowedHosts = hosts.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty }
        } else {
            allowedHosts = [publicAuthority.lowercased(), "127.0.0.1:*", "localhost:*"]
        }
        trustForwardedFor = env["NR_TRUST_FORWARDED_FOR"] == "1"
        anthropicIPAllowlist = env["NR_ANTHROPIC_IP_ALLOWLIST"] == "1"

        if let rawHours = env["NR_STALE_AFTER_HOURS"] {
            guard let hours = Int(rawHours), hours > 0 else {
                throw ConfigError.invalid("NR_STALE_AFTER_HOURS", "must be a positive integer")
            }
            staleAfterHours = hours
        } else {
            staleAfterHours = 24
        }

        func nonEmpty(_ key: String) -> String? {
            env[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        oauth = OAuthKeys(
            allowedEmail: nonEmpty("NR_ALLOWED_EMAIL"),
            clientID: nonEmpty("NR_OAUTH_CLIENT_ID"),
            redirectURIs: (env["NR_OAUTH_REDIRECT_URIS"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            allowLoopback: env["NR_ALLOW_LOOPBACK"] == "1",
            googleClientID: nonEmpty("NR_GOOGLE_CLIENT_ID"),
            googleClientSecret: nonEmpty("NR_GOOGLE_CLIENT_SECRET")
        )
    }

    static func parseBind(_ value: String) throws -> (String, Int) {
        guard let colon = value.lastIndex(of: ":") else {
            throw ConfigError.invalid("NR_BIND", "expected host:port")
        }
        var host = String(value[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, let port = Int(value[value.index(after: colon)...]), (0 ... 65535).contains(port) else {
            throw ConfigError.invalid("NR_BIND", "expected host:port")
        }
        return (host, port)
    }

    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    /// `status` output: the config with secrets masked.
    public func describe() -> [String] {
        func mask(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "(unset)" }
            return "set (\(value.count) chars, masked)"
        }
        var lines = [
            "public_url: \(publicURL)",
            "resource_url: \(resourceURL)",
            "bind: \(bindHost):\(bindPort)",
            "replica_dir: \(replicaDir.path)",
            "state_dir: \(stateDir.path)",
            "audit_log: \(auditLog.path)",
            "allowed_hosts: \(allowedHosts.joined(separator: ","))",
            "trust_forwarded_for: \(trustForwardedFor)",
            "anthropic_ip_allowlist: \(anthropicIPAllowlist)",
            "stale_after_hours: \(staleAfterHours)",
            "oauth.allowed_email: \(oauth.allowedEmail ?? "(unset)")",
            "oauth.client_id: \(oauth.clientID ?? "(unset)")",
            "oauth.redirect_uris: \(oauth.redirectURIs.isEmpty ? "(unset)" : oauth.redirectURIs.joined(separator: ","))",
            "oauth.allow_loopback: \(oauth.allowLoopback)",
            "oauth.google_client_id: \(oauth.googleClientID ?? "(unset)")",
            "oauth.google_client_secret: \(mask(oauth.googleClientSecret))",
        ]
        if oauth.allowLoopback {
            lines.append("WARNING: NR_ALLOW_LOOPBACK=1 is a stage-1 (tailnet-only) setting; turn it off before Funnel.")
        }
        return lines
    }
}
