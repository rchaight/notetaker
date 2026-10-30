import Foundation
import HTTPTypes
import Hummingbird

/// The authorization server (spec 07): one pre-registered public client
/// (claude.ai, PKCE S256), one human (the allowlisted Google account). There is
/// deliberately no client registration endpoint. No cookies or sessions: every
/// step is carried by single-use, short-lived, unguessable handles.
///
/// Never logged anywhere: tokens, codes, verifiers, nonces, states, the Google
/// secret, or a foreign email address (only its domain and an 8-hex hash).
public final class OAuthServer: Sendable {
    let settings: OAuthSettings
    let store: TokenStore
    let pending: PendingStore
    let google: GoogleOIDC
    let limiter: RateLimiter
    let audit: AuditLog?
    let now: OAuthClock
    let trustForwardedFor: Bool

    public init(
        config: RemoteConfig,
        settings: OAuthSettings,
        store: TokenStore,
        limiter: RateLimiter,
        audit: AuditLog?,
        httpClient: any OIDCHTTPClient = URLSessionOIDCClient(),
        now: @escaping OAuthClock = { Date() }
    ) {
        self.settings = settings
        self.store = store
        self.limiter = limiter
        self.audit = audit
        self.now = now
        trustForwardedFor = config.trustForwardedFor
        pending = PendingStore(
            now: now, pendingTTL: settings.timings.pendingTTL, consentTTL: settings.timings.consentTTL
        )
        google = GoogleOIDC(
            settings: settings.google, client: httpClient, now: now, discoveryTTL: settings.timings.discoveryTTL
        )
    }

    /// The bearer validator `/mcp` uses (replaces spec 06's deny-all).
    public var authenticator: TokenAuthenticator {
        TokenAuthenticator(store: store, audience: settings.resourceURL, clientID: settings.clientID, now: now)
    }

    /// Adds the AS routes (passed to `RemoteApp.build(extraRoutes:)`).
    public func register(on router: Router<BasicRequestContext>) {
        let metadata = metadataResponseBody()
        for path in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            router.get(RouterPath(path)) { _, _ in
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.cacheControl] = "max-age=3600"
                return Response(
                    status: .ok,
                    headers: headers,
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: metadata))
                )
            }
        }
        router.get("/authorize") { request, _ in await self.authorize(request) }
        router.get("/auth/google/callback") { request, _ in await self.googleCallback(request) }
        router.post("/consent") { request, _ in await self.consent(request) }
        router.post("/token") { request, _ in await self.token(request) }
        router.post("/revoke") { request, _ in await self.revoke(request) }
    }

    /// Hourly: drop rows whose lifetime ended more than a day ago.
    public func housekeepingLoop() async {
        while !Task.isCancelled {
            _ = try? await store.housekeep(now: now())
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: - Shared plumbing

    func clientIP(_ request: Request) -> String? {
        MCPEndpoint.clientIP(of: request, trustForwardedFor: trustForwardedFor)
    }

    /// 10/min per endpoint per client IP (one global bucket without a trusted IP).
    func rateLimited(_ endpoint: String, _ request: Request) async -> Response? {
        let ip = clientIP(request)
        let (decision, firstRefusal) = await limiter.admitAuth(endpoint: endpoint, key: ip ?? "global")
        guard case let .limited(retryAfter) = decision else { return nil }
        if firstRefusal {
            await audit?.record(AuditEvent(event: "auth.ratelimited", status: "429", ip: ip, reason: endpoint))
        }
        var response = MCPEndpoint.tooManyRequests(retryAfter: retryAfter)
        response.headers[OAuthHTTP.pragma] = "no-cache"
        return response
    }

    func record(
        _ event: String, status: String? = nil, family: String? = nil, reason: String? = nil,
        args: [String: String] = [:], request: Request
    ) async {
        await audit?.record(AuditEvent(
            event: event, args: args, status: status, clientID: settings.clientID, tokenFamily: family,
            ip: clientIP(request), reason: reason
        ))
    }

    /// The collected body (06's middleware already bounded it at 64 KB) as a form.
    /// nil for a non-form content type, invalid UTF-8 or malformed encoding.
    static func formBody(_ request: Request) async -> FormData? {
        let type = request.headers[.contentType]?.lowercased() ?? ""
        guard type == "application/x-www-form-urlencoded" || type.hasPrefix("application/x-www-form-urlencoded;")
        else { return nil }
        guard let buffer = try? await request.body.collect(upTo: RemoteApp.maxBodyBytes) else { return nil }
        guard let text = String(validating: buffer.readableBytesView, as: UTF8.self) else { return nil }
        return FormData.parse(text)
    }

    func metadataResponseBody() -> Data {
        (try? JSONSerialization.data(
            withJSONObject: settings.metadataDocument, options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
    }
}
