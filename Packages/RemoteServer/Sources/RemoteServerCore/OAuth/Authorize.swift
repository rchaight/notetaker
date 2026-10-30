import Foundation
import Hummingbird

extension OAuthServer {
    // MARK: - GET /authorize

    /// Validation order is fixed: client, then redirect URI. Until both pass,
    /// failures render a 400 page and NEVER redirect (an unvalidated
    /// `redirect_uri` is never a redirect target). After that, failures go back
    /// to the validated `redirect_uri` with `error`, `state` and `iss`.
    func authorize(_ request: Request) async -> Response {
        guard let form = FormData.parse(request.uri.query ?? "") else {
            await record("authorize.rejected", status: "400", reason: "malformed_query", request: request)
            return Self.badRequestPage()
        }
        guard case let .one(clientID) = form.value("client_id"),
              OAuthCrypto.constantTimeEquals(clientID, settings.clientID)
        else {
            await record("authorize.rejected", status: "400", reason: "unknown_client", request: request)
            return Self.badRequestPage()
        }
        guard case let .one(redirectURI) = form.value("redirect_uri"), settings.isAllowedRedirect(redirectURI) else {
            await record("authorize.rejected", status: "400", reason: "redirect_uri_not_allowed", request: request)
            return Self.badRequestPage()
        }

        var echoState: String?
        if case let .one(state) = form.value("state"), state.utf8.count <= 512 {
            echoState = state
        }
        func fail(_ code: String, _ description: String, _ reason: String) async -> Response {
            await record("authorize.rejected", status: "302", reason: reason, request: request)
            var pairs = [("error", code), ("error_description", description)]
            if let echoState {
                pairs.append(("state", echoState))
            }
            pairs.append(("iss", settings.issuer))
            return OAuthHTTP.redirect(to: OAuthHTTP.appendQuery(redirectURI, pairs))
        }

        let known = ["response_type", "code_challenge", "code_challenge_method", "state", "scope", "resource"]
        if let duplicated = known.first(where: { form.value($0) == .duplicate }) {
            return await fail("invalid_request", "\(duplicated) appears more than once", "duplicate_parameter")
        }
        guard case let .one(state) = form.value("state") else {
            return await fail("invalid_request", "state is required", "missing_state")
        }
        guard state.utf8.count <= 512 else {
            return await fail("invalid_request", "state is too long", "state_too_long")
        }
        guard form.value("response_type") == .one("code") else {
            return await fail("unsupported_response_type", "only response_type=code is supported", "response_type")
        }
        guard form.value("code_challenge_method") == .one("S256") else {
            return await fail("invalid_request", "code_challenge_method must be S256", "pkce_method")
        }
        guard case let .one(challenge) = form.value("code_challenge"), OAuthText.isPKCEValue(challenge) else {
            return await fail("invalid_request", "a valid S256 code_challenge is required", "pkce_challenge")
        }
        if case let .one(scope) = form.value("scope"),
           !scope.split(separator: " ").allSatisfy({ $0 == OAuthSettings.scope }) {
            return await fail("invalid_scope", "the only scope is vault:read", "scope")
        }
        switch form.value("resource") {
        case let .one(resource) where resource != settings.resourceURL:
            return await fail("invalid_target", "unknown resource", "resource")
        case .absent:
            // Tolerated (Claude's behaviour unverified); the token is bound to the one resource regardless.
            await record("authorize.no_resource", request: request)
        default:
            break
        }

        let authorization = PendingAuthorization(
            gstate: OAuthCrypto.token(), nonce: OAuthCrypto.token(), googleVerifier: OAuthCrypto.token(),
            clientState: state, redirectURI: redirectURI, codeChallenge: challenge,
            resource: settings.resourceURL, createdAt: now()
        )
        // Each success creates server state: capped globally (see `guarded`).
        let (admission, firstRefusal) = await limiter.admitAuthorization()
        if case let .limited(retryAfter) = admission {
            return await tooMany("authorizations", retryAfter: retryAfter, audit: firstRefusal, ip: clientIP(request))
        }
        let googleURL: String
        do throws(LoginFailure) {
            googleURL = try await google.authorizationURL(for: authorization)
        } catch {
            return await fail("temporarily_unavailable", "the identity provider is unreachable", error.reason)
        }
        await pending.insert(authorization)
        return OAuthHTTP.redirect(to: googleURL)
    }

    // MARK: - GET /auth/google/callback

    func googleCallback(_ request: Request) async -> Response {
        guard let form = FormData.parse(request.uri.query ?? ""),
              case let .one(gstate) = form.value("state"),
              let authorization = await pending.take(gstate: gstate)
        else {
            await record("callback.rejected", status: "400", reason: "unknown_state", request: request)
            return OAuthHTTP.html(
                .badRequest, title: "Sign-in expired",
                message: "This sign-in link has expired or was already used. Start again from Claude."
            )
        }
        if form.value("error") != .absent {
            // The user cancelled at Google (or Google refused). The redirect URI is validated.
            await record("login.cancelled", status: "302", reason: "google_error", request: request)
            return OAuthHTTP.redirect(to: OAuthHTTP.appendQuery(authorization.redirectURI, [
                ("error", "access_denied"), ("error_description", "sign-in was cancelled"),
                ("state", authorization.clientState), ("iss", settings.issuer),
            ]))
        }

        // Outbound Google work is capped globally: anyone can mint a pending
        // request and present a junk code, and each one would cost a Google call.
        let (exchange, firstRefusal) = await limiter.admitGoogleExchange()
        if case let .limited(retryAfter) = exchange {
            _ = await tooMany("google_exchange", retryAfter: retryAfter, audit: firstRefusal, ip: clientIP(request))
            var page = OAuthHTTP.html(
                .tooManyRequests, title: "Too many sign-in attempts",
                message: "Too many sign-in attempts right now. Wait a minute, then start again from Claude."
            )
            page.headers[.retryAfter] = String(retryAfter)
            return page
        }
        let login: VerifiedLogin
        do throws(LoginFailure) {
            guard case let .one(code) = form.value("code") else { throw LoginFailure("missing_code") }
            let idToken = try await google.exchange(code: code, verifier: authorization.googleVerifier)
            login = try await google.verify(
                idToken: idToken, nonce: authorization.nonce, allowedEmail: settings.allowedEmail
            ).get()
        } catch {
            var args: [String: String] = [:]
            if let email = error.email {
                args = Self.emailDigestArgs(email)
            }
            await record("login.denied", status: "403", reason: error.reason, args: args, request: request)
            return OAuthHTTP.html(
                .forbidden, title: "Not authorised", message: "This vault is not shared with that account."
            )
        }
        await record("login.ok", request: request)

        let consentToken = await pending.insertConsent(
            PendingConsent(authorization: authorization, sub: login.email, createdAt: now())
        )
        return Self.consentPage(token: consentToken, redirectURI: authorization.redirectURI, email: login.email)
    }

    // MARK: - Pages and helpers

    static func badRequestPage() -> Response {
        OAuthHTTP.html(
            .badRequest, title: "Invalid request",
            message: "This authorization request is not valid for this server. Nothing was shared."
        )
    }

    static func consentPage(token: String, redirectURI: String, email: String) -> Response {
        let host = OAuthText.htmlEscape(URLComponents(string: redirectURI)?.host ?? redirectURI)
        let field = "<input type=\"hidden\" name=\"consent_token\" value=\"\(OAuthText.htmlEscape(token))\">"
        let forms = """
        <form method="post" action="/consent">\(field)<input type="hidden" name="action" value="allow">\
        <button class="allow" type="submit">Allow</button></form>
        <form method="post" action="/consent">\(field)<input type="hidden" name="action" value="deny">\
        <button type="submit">Deny</button></form>
        <p class="warn">Signed in as \(OAuthText.htmlEscape(email)). Only allow this if you started connecting \
        Notetaker from Claude yourself in the last few minutes. This page expires in 5 minutes.</p>
        """
        return OAuthHTTP.html(
            .ok, title: "Connect Notetaker",
            message: "Allow <strong>\(host)</strong> (Claude) to read your Notetaker vault? Scope: vault:read.",
            extra: forms
        )
    }

    /// What `login.denied` may say about a foreign address: its domain and the
    /// first 8 hex of SHA-256(lowercased address) — never the address.
    static func emailDigestArgs(_ email: String) -> [String: String] {
        let lowered = email.lowercased()
        let parts = lowered.split(separator: "@", omittingEmptySubsequences: false)
        let domain = parts.count >= 2 ? String(parts[parts.count - 1]) : ""
        let safeDomain = String(domain.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            .prefix(64))
        return ["email_domain": safeDomain, "email_hash8": String(OAuthCrypto.storageHash(lowered).prefix(8))]
    }
}
