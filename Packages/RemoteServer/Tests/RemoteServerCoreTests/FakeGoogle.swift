import _CryptoExtras
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Synchronization
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// A settable clock shared by the server under test and the fake IdP.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var clock: OAuthClock {
        { [self] in now }
    }
}

/// Test RSA keys (fixed PEMs in `TestKeyMaterial`; no keygen at test time).
enum TestKeys {
    static let primary = try! _RSA.Signing.PrivateKey(pemRepresentation: TestKeyMaterial.primary)
    static let secondary = try! _RSA.Signing.PrivateKey(pemRepresentation: TestKeyMaterial.secondary)
    /// Never published in any JWKS.
    static let rogue = try! _RSA.Signing.PrivateKey(pemRepresentation: TestKeyMaterial.rogue)

    static func jwk(_ key: _RSA.Signing.PrivateKey, kid: String) -> [String: Any] {
        let primitives = try! key.publicKey.getKeyPrimitives()
        return [
            "kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid,
            "n": Base64URL.encode(primitives.modulus), "e": Base64URL.encode(primitives.publicExponent),
        ]
    }
}

/// How the fake signs the next ID token.
enum FakeSigner: Sendable {
    case key(kid: String) // "k1" → primary, "k2" → secondary, anything else → rogue key under that kid
    case rogueUnderKnownKid // the rogue key, but claiming kid "k1"
    case pss // RS256 header, but an RSASSA-PSS signature by the primary key
    case none // alg "none", empty signature
    case hs256WithPublicKey // the classic RS→HS confusion: HMAC keyed with the public key
    case raw(String) // a literal id_token
}

/// The in-process stand-in for accounts.google.com: discovery, authorize,
/// token (real RSA-signed ID tokens), and JWKS. Records every hit.
final class FakeGoogle: Sendable {
    struct AuthorizeRecord: Sendable, Equatable {
        var query: [String: String]
        var code: String
    }

    struct Behaviour: Sendable {
        var email = "rchaight@gmail.com"
        var signer = FakeSigner.key(kid: "k1")
        var publishedKids = ["k1"]
        /// Mutates (header, claims) after the defaults are filled in.
        var mutate: @Sendable (inout [String: Any], inout [String: Any]) -> Void = { _, _ in }
        var tokenStatus = 200
    }

    struct Counters: Sendable {
        var certs = 0
        var token = 0
        var discovery = 0
        var authorize: [AuthorizeRecord] = []
        var tokenForms: [[String: String]] = []
    }

    static let clientID = "google-client-123.apps.example"
    static let clientSecret = "GOOGLE-SECRET-do-not-log-7f3c"

    let clock: TestClock
    private let behaviourBox = Mutex(Behaviour())
    private let countersBox = Mutex(Counters())
    private let codes = Mutex([String: [String: String]]())
    private let portBox = Mutex(0)

    init(clock: TestClock) {
        self.clock = clock
    }

    var port: Int {
        portBox.withLock { $0 }
    }

    var issuer: String {
        "http://localhost:\(port)"
    }

    var counters: Counters {
        countersBox.withLock { $0 }
    }

    func configure(_ change: (inout Behaviour) -> Void) {
        behaviourBox.withLock { change(&$0) }
    }

    /// Runs the fake on a loopback port for the duration of `body`.
    func run<T: Sendable>(_ body: @Sendable (FakeGoogle) async throws -> T) async throws -> T {
        let router = Router<BasicRequestContext>()
        router.get("/.well-known/openid-configuration") { _, _ in
            self.countersBox.withLock { $0.discovery += 1 }
            return Self.json([
                "issuer": self.issuer,
                "authorization_endpoint": self.issuer + "/o/oauth2/v2/auth",
                "token_endpoint": self.issuer + "/token",
                "jwks_uri": self.issuer + "/certs",
            ])
        }
        router.get("/o/oauth2/v2/auth") { request, _ in
            let query = Self.parse(request.uri.query ?? "")
            let code = "gcode-" + UUID().uuidString
            self.codes.withLock { $0[code] = query }
            self.countersBox.withLock { $0.authorize.append(AuthorizeRecord(query: query, code: code)) }
            var location = (query["redirect_uri"] ?? "") + "?code=" + code
            location += "&state=" + OAuthText.formEncode(query["state"] ?? "")
            var headers = HTTPFields()
            headers[.location] = location
            return Response(status: .found, headers: headers)
        }
        router.post("/token") { request, _ in
            let body = try await request.body.collect(upTo: 65536)
            let form = Self.parse(String(buffer: body))
            self.countersBox.withLock {
                $0.token += 1
                $0.tokenForms.append(form)
            }
            let behaviour = self.behaviourBox.withLock { $0 }
            guard let code = form["code"], let auth = self.codes.withLock({ $0.removeValue(forKey: code) }),
                  form["client_id"] == Self.clientID, form["client_secret"] == Self.clientSecret,
                  form["grant_type"] == "authorization_code", form["redirect_uri"] == auth["redirect_uri"],
                  let verifier = form["code_verifier"],
                  OAuthCrypto.pkceChallenge(for: verifier) == auth["code_challenge"]
            else {
                return Self.json(["error": "invalid_grant"], status: .badRequest)
            }
            guard behaviour.tokenStatus == 200 else {
                return Self.json(["error": "server_error"], status: HTTPResponse.Status(code: behaviour.tokenStatus))
            }
            let token = self.idToken(nonce: auth["nonce"] ?? "", behaviour: behaviour)
            return Self.json([
                "access_token": "ya29.fake",
                "id_token": token,
                "token_type": "Bearer",
                "expires_in": 3599,
            ])
        }
        router.get("/certs") { _, _ in
            self.countersBox.withLock { $0.certs += 1 }
            let kids = self.behaviourBox.withLock { $0.publishedKids }
            let keys: [[String: Any]] = kids.map { kid in
                TestKeys.jwk(kid == "k2" ? TestKeys.secondary : TestKeys.primary, kid: kid)
            }
            var response = Self.json(["keys": keys])
            response.headers[.cacheControl] = "public, max-age=3600"
            return response
        }
        let app = Application(
            router: router, configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: 0))
        )
        return try await app.test(.live) { client in
            self.portBox.withLock { $0 = client.port ?? 0 }
            return try await body(self)
        }
    }

    /// The ID token the fake would issue: Google's claim set, signed per `behaviour`.
    func idToken(nonce: String, behaviour: Behaviour) -> String {
        let now = clock.now.timeIntervalSince1970
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        var claims: [String: Any] = [
            "iss": issuer, "aud": Self.clientID, "azp": Self.clientID, "sub": "1098765",
            "email": behaviour.email, "email_verified": true, "nonce": nonce,
            "iat": Int(now), "exp": Int(now) + 3600,
        ]
        switch behaviour.signer {
        case let .key(kid): header["kid"] = kid
        case .rogueUnderKnownKid, .pss: header["kid"] = "k1"
        case .none: header["alg"] = "none"
            header["kid"] = "k1"
        case .hs256WithPublicKey: header["alg"] = "HS256"
            header["kid"] = "k1"
        case let .raw(token): return token
        }
        behaviour.mutate(&header, &claims)
        return Self.sign(header: header, claims: claims, signer: behaviour.signer)
    }

    static func sign(header: [String: Any], claims: [String: Any], signer: FakeSigner) -> String {
        let encodedHeader = Base64URL.encode(try! JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        ))
        let encodedClaims = Base64URL.encode(try! JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ))
        let input = Data("\(encodedHeader).\(encodedClaims)".utf8)
        let signature: Data = switch signer {
        case let .key(kid):
            try! (kid == "k1" ? TestKeys.primary : kid == "k2" ? TestKeys.secondary : TestKeys.rogue)
                .signature(for: input, padding: .insecurePKCS1v1_5).rawRepresentation
        case .rogueUnderKnownKid:
            try! TestKeys.rogue.signature(for: input, padding: .insecurePKCS1v1_5).rawRepresentation
        case .pss:
            try! TestKeys.primary.signature(for: input, padding: .PSS).rawRepresentation
        case .none:
            Data()
        case .hs256WithPublicKey:
            Data(HMAC<SHA256>.authenticationCode(
                for: input, using: SymmetricKey(data: Data(TestKeys.primary.publicKey.pemRepresentation.utf8))
            ))
        case .raw:
            Data()
        }
        return "\(encodedHeader).\(encodedClaims).\(Base64URL.encode(signature))"
    }

    static func json(_ object: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status, headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: try! JSONSerialization.data(withJSONObject: object)))
        )
    }

    static func parse(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            let value = parts.count > 1
                ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            out[name] = value
        }
        return out
    }
}
