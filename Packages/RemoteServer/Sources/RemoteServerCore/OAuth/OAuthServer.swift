import Foundation
import HTTPTypes
import Hummingbird
import Synchronization

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
        router.get("/authorize") { request, _ in
            await self.guarded("authorize", request) { await self.authorize(request) }
        }
        router.get("/auth/google/callback") { request, _ in
            await self.guarded("callback", request) { await self.googleCallback(request) }
        }
        router.post("/consent") { request, _ in
            await self.guarded("consent", request) { await self.consent(request) }
        }
        router.post("/token") { request, _ in
            await self.guarded("token", request) { await self.token(request) }
        }
        router.post("/revoke") { request, _ in
            await self.guarded("revoke", request) { await self.revoke(request) }
        }
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

    /// Marks the current request as failed (set by `record` for failure events,
    /// which also covers error redirects and RFC 7009's 200-for-unknown).
    final class FailureMark: Sendable {
        let failed = Mutex(false)
    }

    @TaskLocal static var failureMark: FailureMark?
    /// Set once an endpoint's failure budget is spent: failure events are not
    /// audited individually (one `auth.ratelimited` line covers the streak).
    @TaskLocal static var quietFailures = false

    /// Audit events that mean "this request failed". `login.denied` is always
    /// written (it is the anomaly cue, and Google exchanges are capped anyway).
    static let failureEvents: Set<String> = [
        "authorize.rejected", "callback.rejected", "consent.rejected", "token.rejected", "login.denied",
    ]

    /// Rate limiting for every AS endpoint (spec 07, revised after critique).
    ///
    /// - Trusted client IP (`NR_TRUST_FORWARDED_FOR=1`): 10/min per endpoint per
    ///   IP, checked before anything else.
    /// - No trusted IP (one global key — assume this until stage 2 proves what
    ///   Funnel forwards): nothing is gated up front. Requests are validated
    ///   (cheap: parsing, constant-time compares, one primary-key lookup) and only
    ///   FAILED ones spend the endpoint's 10/min budget; once it is spent, failures
    ///   become a quiet 429. A request carrying a valid code, refresh token or
    ///   consent token is therefore never blocked by internet junk. The steps that
    ///   cost real work are capped separately in both modes: new pending
    ///   authorizations (30/min) and Google code exchanges (20/min), so junk can at
    ///   worst delay the interactive login, never refresh or `/mcp`.
    func guarded(_ endpoint: String, _ request: Request, _ handle: () async -> Response) async -> Response {
        let ip = clientIP(request)
        if let ip {
            let (decision, first) = await limiter.admitAuth(endpoint: endpoint, key: ip)
            if case let .limited(retryAfter) = decision {
                return await tooMany(endpoint, retryAfter: retryAfter, audit: first, ip: ip)
            }
            return await handle()
        }
        let mark = FailureMark()
        let quiet = await limiter.authFailuresExhausted(endpoint: endpoint)
        let response = await Self.$failureMark.withValue(mark) {
            await Self.$quietFailures.withValue(quiet) { await handle() }
        }
        // A 429 from a work cap is already a refusal: it does not also spend the failure budget.
        let failed = mark.failed.withLock { $0 } || (response.status.code >= 400 && response.status != .tooManyRequests)
        guard failed else { return response }
        let (decision, first) = await limiter.spendAuthFailure(endpoint: endpoint)
        if case let .limited(retryAfter) = decision {
            return await tooMany(endpoint, retryAfter: retryAfter, audit: first, ip: nil)
        }
        return response
    }

    func tooMany(_ reason: String, retryAfter: Int, audit shouldAudit: Bool, ip: String?) async -> Response {
        if shouldAudit {
            await audit?.record(AuditEvent(event: "auth.ratelimited", status: "429", ip: ip, reason: reason))
        }
        var response = MCPEndpoint.tooManyRequests(retryAfter: retryAfter)
        response.headers[OAuthHTTP.pragma] = "no-cache"
        return response
    }

    func record(
        _ event: String, status: String? = nil, family: String? = nil, reason: String? = nil,
        args: [String: String] = [:], request: Request
    ) async {
        let failure = Self.failureEvents.contains(event) || (event == "revoke" && status != "200")
            || (event == "revoke" && reason == "unknown")
        if failure {
            Self.failureMark?.failed.withLock { $0 = true }
            if Self.quietFailures, event != "login.denied" {
                return
            }
        }
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
