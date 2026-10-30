import _CryptoExtras
import Foundation

/// Why a Google login was refused. `reason` is audit-safe; `email` is only set
/// once the ID token's signature and issuer verified (so it is Google's
/// statement, not attacker input) and is reduced to domain + hash before logging.
struct LoginFailure: Error, Equatable {
    var reason: String
    var email: String?

    init(_ reason: String, email: String? = nil) {
        self.reason = reason
        self.email = email
    }
}

struct GoogleDiscovery: Sendable, Equatable {
    var authorizationEndpoint: String
    var tokenEndpoint: URL
    var jwksURI: URL
}

/// Google as the OIDC identity provider: discovery (cached 24 h), the
/// authorization-code exchange (confidential client + PKCE), and ID-token
/// verification. Holds no Google tokens beyond the one request.
actor GoogleOIDC {
    private let settings: OAuthSettings.Google
    private let client: any OIDCHTTPClient
    private let now: OAuthClock
    private let discoveryTTL: TimeInterval
    private let jwks: JWKSCache
    private var discovered: (GoogleDiscovery, Date)?

    init(
        settings: OAuthSettings.Google,
        client: any OIDCHTTPClient,
        now: @escaping OAuthClock,
        discoveryTTL: TimeInterval
    ) {
        self.settings = settings
        self.client = client
        self.now = now
        self.discoveryTTL = discoveryTTL
        jwks = JWKSCache(client: client, now: now)
    }

    func discovery() async throws(LoginFailure) -> GoogleDiscovery {
        if let (cached, fetchedAt) = discovered, now().timeIntervalSince(fetchedAt) < discoveryTTL {
            return cached
        }
        guard let url = URL(string: settings.issuer + "/.well-known/openid-configuration"),
              let result = try? await client.get(url), result.status == 200,
              let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any]
        else { throw LoginFailure("discovery_unavailable") }
        // OIDC Discovery §4.3: the document's issuer must be the one we asked.
        guard object["issuer"] as? String == settings.issuer,
              let authorization = object["authorization_endpoint"] as? String,
              let token = object["token_endpoint"] as? String,
              let jwksURI = object["jwks_uri"] as? String,
              [authorization, token, jwksURI].allSatisfy(OAuthText.isAcceptableEndpoint),
              let tokenURL = URL(string: token), let jwksURL = URL(string: jwksURI)
        else { throw LoginFailure("discovery_invalid") }
        let document = GoogleDiscovery(authorizationEndpoint: authorization, tokenEndpoint: tokenURL, jwksURI: jwksURL)
        discovered = (document, now())
        return document
    }

    /// The Google authorization URL for one pending request.
    func authorizationURL(for pending: PendingAuthorization) async throws(LoginFailure) -> String {
        let endpoint = try await discovery().authorizationEndpoint
        return OAuthHTTP.appendQuery(endpoint, [
            ("client_id", settings.clientID),
            ("redirect_uri", settings.redirectURI),
            ("response_type", "code"),
            ("scope", "openid email"),
            ("state", pending.gstate),
            ("nonce", pending.nonce),
            ("code_challenge", OAuthCrypto.pkceChallenge(for: pending.googleVerifier)),
            ("code_challenge_method", "S256"),
            ("prompt", "select_account"),
            ("access_type", "online"),
        ])
    }

    /// Code → ID token (the only thing kept from Google's response).
    func exchange(code: String, verifier: String) async throws(LoginFailure) -> String {
        let endpoint = try await discovery().tokenEndpoint
        let result: OIDCHTTPResult
        do {
            result = try await client.postForm(endpoint, [
                ("code", code),
                ("client_id", settings.clientID),
                ("client_secret", settings.clientSecret.value),
                ("redirect_uri", settings.redirectURI),
                ("grant_type", "authorization_code"),
                ("code_verifier", verifier),
            ])
        } catch {
            throw LoginFailure("token_exchange_unreachable")
        }
        guard result.status == 200,
              let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let idToken = object["id_token"] as? String, !idToken.isEmpty
        else { throw LoginFailure("token_exchange_failed") }
        return idToken
    }

    func verify(idToken: String, nonce: String, allowedEmail: String) async -> Result<VerifiedLogin, LoginFailure> {
        let jwksURI: URL
        do {
            jwksURI = try await discovery().jwksURI
        } catch {
            return .failure(error)
        }
        let verifier = IDTokenVerifier(issuer: settings.issuer, audience: settings.clientID, allowedEmail: allowedEmail)
        let cache = jwks
        return await verifier.verify(idToken, nonce: nonce, now: now()) { kid in
            await cache.key(kid: kid, jwksURI: jwksURI)
        }
    }
}

struct VerifiedLogin: Sendable, Equatable {
    /// The allowlisted address (lowercased) — the token family's `sub`.
    var email: String
}

/// Compact-JWS RS256 ID-token verification (OIDC Core §3.1.3.7), pure apart from
/// the key lookup. Order: shape → header (alg pinned to RS256 before anything
/// else, so `none`/HS256/ES256 never reach a verifier) → key by `kid` →
/// signature → claims. Nothing in the payload is trusted before the signature.
struct IDTokenVerifier: Sendable {
    let issuer: String
    let audience: String
    let allowedEmail: String
    static let clockSkew: TimeInterval = 300
    static let maxTokenLength = 16 * 1024

    func verify(
        _ token: String, nonce expectedNonce: String, now: Date,
        key: (String) async -> _RSA.Signing.PublicKey?
    ) async -> Result<VerifiedLogin, LoginFailure> {
        guard token.utf8.count <= Self.maxTokenLength else { return .failure(LoginFailure("malformed")) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty,
              let headerData = Base64URL.decode(parts[0]), let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]),
              case let .object(header)? = try? JSONDecoder().decode(JSONValue.self, from: headerData),
              case let .object(claims)? = try? JSONDecoder().decode(JSONValue.self, from: payloadData)
        else { return .failure(LoginFailure("malformed")) }

        guard header["alg"]?.string == "RS256" else { return .failure(LoginFailure("bad_alg")) }
        // Never honour key material or extensions carried by the token itself.
        for forbidden in ["jwk", "jku", "x5u", "x5c", "crit"] where header[forbidden] != nil {
            return .failure(LoginFailure("bad_header"))
        }
        guard let kid = header["kid"]?.string, !kid.isEmpty else { return .failure(LoginFailure("no_kid")) }
        guard let publicKey = await key(kid) else { return .failure(LoginFailure("unknown_kid")) }

        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(
            _RSA.Signing.RSASignature(rawRepresentation: signature), for: signingInput, padding: .insecurePKCS1v1_5
        ) else { return .failure(LoginFailure("bad_signature")) }

        // Claims (trusted from here on).
        let issuerWithoutScheme = issuer.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        guard let iss = claims["iss"]?.string, iss == issuer || iss == issuerWithoutScheme else {
            return .failure(LoginFailure("bad_iss"))
        }
        guard Self.audienceMatches(claims["aud"], audience) else { return .failure(LoginFailure("bad_aud")) }
        if let azp = claims["azp"], azp.string != audience {
            return .failure(LoginFailure("bad_azp"))
        }
        let moment = now.timeIntervalSince1970
        guard let exp = claims["exp"]?.number else { return .failure(LoginFailure("no_exp")) }
        guard exp > moment else { return .failure(LoginFailure("expired")) }
        guard let iat = claims["iat"]?.number, iat <= moment + Self.clockSkew else {
            return .failure(LoginFailure("bad_iat"))
        }
        if let rawNbf = claims["nbf"] {
            guard let nbf = rawNbf.number, nbf <= moment + Self.clockSkew else {
                return .failure(LoginFailure("not_yet_valid"))
            }
        }
        guard let nonce = claims["nonce"]?.string, OAuthCrypto.constantTimeEquals(nonce, expectedNonce) else {
            return .failure(LoginFailure("bad_nonce"))
        }
        let email = claims["email"]?.string
        // JSON `true` only: not the string "true", not 1.
        guard claims["email_verified"] == .bool(true) else {
            return .failure(LoginFailure("email_unverified", email: email))
        }
        guard let email, Self.emailMatches(email, allowed: allowedEmail) else {
            return .failure(LoginFailure("email_not_allowed", email: email))
        }
        return .success(VerifiedLogin(email: allowedEmail))
    }

    /// Exact match after ASCII case folding. Non-ASCII input never matches: a
    /// Unicode-aware `lowercased()` would fold look-alikes (U+212A KELVIN SIGN →
    /// `k`, fullwidth letters stay distinct but others do not) onto ASCII.
    static func emailMatches(_ candidate: String, allowed: String) -> Bool {
        guard candidate.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return false }
        let folded = String(
            decoding: candidate.utf8.map { (0x41 ... 0x5A).contains($0) ? $0 + 0x20 : $0 },
            as: UTF8.self
        )
        return folded == allowed
    }

    static func audienceMatches(_ value: JSONValue?, _ expected: String) -> Bool {
        switch value {
        case let .string(single)?:
            single == expected
        // An array is accepted only when it names us and nobody else.
        case let .array(list)? where list.count == 1:
            list[0] == .string(expected)
        default:
            false
        }
    }
}

/// A JSON document with types kept apart (booleans are never numbers, numbers
/// never strings) — the swift-foundation decoder enforces this on both platforms.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var number: Double? {
        if case let .number(value) = self, value.isFinite {
            return value
        }
        return nil
    }
}
