import Foundation

/// The validated OAuth configuration (spec 07). `RemoteConfig` parses the
/// `NR_*` keys; this type enforces "required when serving" and every shape rule.
/// There is exactly one client (`clientID`) and one human (`allowedEmail`);
/// there is no dynamic client registration endpoint anywhere in this server.
public struct OAuthSettings: Sendable {
    public static let claudeRedirectURI = "https://claude.ai/api/mcp/auth_callback"
    public static let scope = "vault:read"

    public struct Timings: Sendable, Equatable {
        public var accessTTL: TimeInterval
        public var refreshIdle: TimeInterval
        public var refreshAbsolute: TimeInterval
        public var codeTTL: TimeInterval
        public var pendingTTL: TimeInterval = 600
        public var consentTTL: TimeInterval = 300
        public var discoveryTTL: TimeInterval = 86400

        public init(
            accessTTL: TimeInterval,
            refreshIdle: TimeInterval,
            refreshAbsolute: TimeInterval,
            codeTTL: TimeInterval
        ) {
            self.accessTTL = accessTTL
            self.refreshIdle = refreshIdle
            self.refreshAbsolute = refreshAbsolute
            self.codeTTL = codeTTL
        }
    }

    public struct Google: Sendable {
        public let clientID: String
        public let clientSecret: SecretValue
        public let issuer: String
        /// `PUBLIC_URL/auth/google/callback`
        public let redirectURI: String
    }

    /// `PUBLIC_URL` — the AS `issuer` and the `iss` authorization-response parameter.
    public let issuer: String
    /// `PUBLIC_URL/mcp` — every token's audience.
    public let resourceURL: String
    /// ASCII, lowercased. Compared exactly against the ID token's `email`.
    public let allowedEmail: String
    public let clientID: String
    public let redirectURIs: [String]
    public let allowLoopback: Bool
    public let google: Google
    /// Raw 32-byte digest when the optional client-secret hook is on.
    public let clientSecretDigest: [UInt8]?
    public var timings: Timings

    public init(config: RemoteConfig) throws(RemoteConfig.ConfigError) {
        let keys = config.oauth
        issuer = config.publicURL
        resourceURL = config.resourceURL

        guard let email = keys.allowedEmail else { throw .missing("NR_ALLOWED_EMAIL") }
        guard Self.isPlainEmail(email) else {
            throw .invalid("NR_ALLOWED_EMAIL", "must be a single plain ASCII address")
        }
        allowedEmail = email.lowercased()

        guard let clientID = keys.clientID else { throw .missing("NR_OAUTH_CLIENT_ID") }
        guard clientID.count >= 16, clientID.count <= 128, clientID.unicodeScalars.allSatisfy(OAuthText.isUnreserved)
        else {
            throw .invalid("NR_OAUTH_CLIENT_ID", "must be 16-128 characters of [A-Za-z0-9._~-]")
        }
        self.clientID = clientID

        let uris = keys.redirectURIs.isEmpty ? [Self.claudeRedirectURI] : keys.redirectURIs
        for uri in uris {
            guard let parts = URLComponents(string: uri), parts.scheme == "https", parts.host?.isEmpty == false,
                  parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil
            else {
                throw .invalid("NR_OAUTH_REDIRECT_URIS", "each entry must be an https URL without query or fragment")
            }
        }
        redirectURIs = uris
        allowLoopback = keys.allowLoopback

        guard let googleID = keys.googleClientID else { throw .missing("NR_GOOGLE_CLIENT_ID") }
        guard let googleSecret = keys.googleClientSecret else { throw .missing("NR_GOOGLE_CLIENT_SECRET") }
        var googleIssuer = keys.googleIssuer
        while googleIssuer.hasSuffix("/") {
            googleIssuer.removeLast()
        }
        guard OAuthText.isAcceptableEndpoint(googleIssuer), URLComponents(string: googleIssuer)?.query == nil else {
            throw .invalid("NR_GOOGLE_ISSUER", "must be https (http only for a loopback test issuer)")
        }
        google = Google(
            clientID: googleID, clientSecret: googleSecret, issuer: googleIssuer,
            redirectURI: config.publicURL + "/auth/google/callback"
        )

        if let hex = keys.clientSecretSHA256 {
            guard let digest = OAuthText.hexBytes(hex), digest.count == 32 else {
                throw .invalid("NR_OAUTH_CLIENT_SECRET_SHA256", "must be 64 hex characters")
            }
            clientSecretDigest = digest
        } else {
            clientSecretDigest = nil
        }

        timings = Timings(
            accessTTL: TimeInterval(keys.accessTTLSeconds),
            refreshIdle: TimeInterval(keys.refreshIdleDays) * 86400,
            refreshAbsolute: TimeInterval(keys.refreshAbsoluteDays) * 86400,
            codeTTL: TimeInterval(keys.codeTTLSeconds)
        )
    }

    /// One `@`, a non-empty local part and domain, printable ASCII, no spaces.
    /// ASCII-only is what makes the later case-fold comparison safe: Unicode
    /// case mapping folds look-alikes (KELVIN SIGN → `k`) onto ASCII letters.
    static func isPlainEmail(_ value: String) -> Bool {
        guard value.count <= 254, value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            return false
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Exact redirect allowlist, plus RFC 8252 §7.3 loopback when enabled:
    /// `http://127.0.0.1|localhost[:port]/path` — no query, fragment or userinfo.
    func isAllowedRedirect(_ uri: String) -> Bool {
        if redirectURIs.contains(where: { $0 == uri }) {
            return true
        }
        return allowLoopback && Self.isLoopbackRedirect(uri)
    }

    static func isLoopbackRedirect(_ uri: String) -> Bool {
        var rest: Substring
        if uri.hasPrefix("http://127.0.0.1") {
            rest = uri.dropFirst("http://127.0.0.1".count)
        } else if uri.hasPrefix("http://localhost") {
            rest = uri.dropFirst("http://localhost".count)
        } else {
            return false
        }
        if rest.first == ":" {
            rest = rest.dropFirst()
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 5, let port = Int(digits), (1 ... 65535).contains(port) else {
                return false
            }
            rest = rest.dropFirst(digits.count)
        }
        if rest.isEmpty {
            return true
        }
        guard rest.first == "/" else { return false }
        // Path characters only: no `?`, `#`, `\`, `@`, whitespace or non-ASCII.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/!$&'()*+,;=:%")
        return rest.allSatisfy { allowed.contains($0) }
    }

    public var metadataDocument: [String: Any] {
        let methods = clientSecretDigest == nil ? ["none"] : ["client_secret_post", "client_secret_basic"]
        return [
            "issuer": issuer,
            "authorization_endpoint": issuer + "/authorize",
            "token_endpoint": issuer + "/token",
            "revocation_endpoint": issuer + "/revoke",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": methods,
            "revocation_endpoint_auth_methods_supported": methods,
            "scopes_supported": [Self.scope],
            "authorization_response_iss_parameter_supported": true,
        ]
    }
}
