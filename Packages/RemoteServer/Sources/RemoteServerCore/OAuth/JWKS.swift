import _CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The only outbound HTTP this server makes: Google discovery, JWKS and the
/// token exchange. A seam so tests can count calls; production uses URLSession.
public protocol OIDCHTTPClient: Sendable {
    func get(_ url: URL) async throws -> OIDCHTTPResult
    func postForm(_ url: URL, _ pairs: [(String, String)]) async throws -> OIDCHTTPResult
}

public struct OIDCHTTPResult: Sendable {
    public var status: Int
    /// Lowercased header names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// URLSession (FoundationNetworking on Linux): ephemeral, no cookies, no cache,
/// 10 s timeout, redirects refused (a redirected POST would re-send the client
/// secret to wherever it points), 1 MB response cap.
public final class URLSessionOIDCClient: OIDCHTTPClient, @unchecked Sendable {
    static let maxBytes = 1 << 20
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    public func get(_ url: URL) async throws -> OIDCHTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    public func postForm(_ url: URL, _ pairs: [(String, String)]) async throws -> OIDCHTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(OAuthText.formEncode(pairs).utf8)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> OIDCHTTPResult {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let body = data ?? Data()
                guard body.count <= Self.maxBytes else {
                    continuation.resume(throwing: URLError(.dataLengthExceedsMaximum))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String {
                        headers[key.lowercased()] = value
                    }
                }
                continuation.resume(returning: OIDCHTTPResult(status: http.statusCode, headers: headers, body: body))
            }
            task.resume()
        }
    }
}

/// A parsed JWKS: RSA signing keys by `kid`. Keys that are not RSA, not for
/// signatures, not RS256, malformed, or under 2048 bits are skipped; a `kid`
/// that appears twice is dropped entirely (ambiguous → unusable).
struct JWKSet: Sendable {
    var keys: [String: _RSA.Signing.PublicKey]

    static func parse(_ data: Data) -> JWKSet? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["keys"] as? [[String: Any]]
        else { return nil }
        var keys: [String: _RSA.Signing.PublicKey] = [:]
        var duplicated: Set<String> = []
        for entry in list {
            guard entry["kty"] as? String == "RSA", let kid = entry["kid"] as? String, !kid.isEmpty else { continue }
            if let use = entry["use"], use as? String != "sig" {
                continue
            }
            if let alg = entry["alg"], alg as? String != "RS256" {
                continue
            }
            guard let n = (entry["n"] as? String).flatMap(Base64URL.decode),
                  let e = (entry["e"] as? String).flatMap(Base64URL.decode),
                  let key = try? _RSA.Signing.PublicKey(n: n, e: e) // rejects < 2048 bits
            else { continue }
            if keys[kid] != nil {
                duplicated.insert(kid)
            }
            keys[kid] = key
        }
        for kid in duplicated {
            keys[kid] = nil
        }
        return JWKSet(keys: keys)
    }
}

/// JWKS cache: honours `Cache-Control: max-age` clamped to [5 min, 24 h]; an
/// unknown `kid` forces at most one refetch, and forced refetches are spaced
/// at least 30 s apart so a stream of bad tokens cannot hammer Google.
actor JWKSCache {
    static let minAge: TimeInterval = 300
    static let maxAge: TimeInterval = 86400
    static let forcedRefetchSpacing: TimeInterval = 30

    private let client: any OIDCHTTPClient
    private let now: OAuthClock
    private var cached: JWKSet?
    private var expiresAt: Date = .distantPast
    private var lastForced: Date = .distantPast

    init(client: any OIDCHTTPClient, now: @escaping OAuthClock) {
        self.client = client
        self.now = now
    }

    func key(kid: String, jwksURI: URL) async -> _RSA.Signing.PublicKey? {
        if cached == nil || now() >= expiresAt {
            await refresh(jwksURI)
        }
        if let key = cached?.keys[kid] {
            return key
        }
        guard now().timeIntervalSince(lastForced) >= Self.forcedRefetchSpacing else { return nil }
        lastForced = now()
        await refresh(jwksURI)
        return cached?.keys[kid]
    }

    private func refresh(_ uri: URL) async {
        guard let result = try? await client.get(uri), result.status == 200, let set = JWKSet.parse(result.body) else {
            return
        }
        cached = set
        expiresAt = now().addingTimeInterval(Self.maxAge(from: result.headers["cache-control"]))
    }

    static func maxAge(from header: String?) -> TimeInterval {
        var age = minAge
        if let header {
            for directive in header.split(separator: ",") {
                let parts = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "max-age", let value = TimeInterval(parts[1]) {
                    age = value
                }
            }
        }
        return min(max(age, minAge), maxAge)
    }
}
