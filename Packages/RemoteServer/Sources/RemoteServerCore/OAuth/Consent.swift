import Foundation
import HTTPTypes
import Hummingbird

extension OAuthServer {
    // MARK: - POST /consent

    /// CSRF: the single-use, 5-minute `consent_token` (a synchronizer token only
    /// the logged-in browser has seen) is the defence; as depth, a cross-site
    /// `Origin` or `Sec-Fetch-Site: cross-site` is refused outright.
    func consent(_ request: Request) async -> Response {
        if let limited = await rateLimited("consent", request) {
            return limited
        }
        if let origin = request.headers[.origin], origin != "null", origin != settings.issuer {
            await record("consent.rejected", status: "403", reason: "cross_origin", request: request)
            return OAuthHTTP.html(
                .forbidden,
                title: "Request refused",
                message: "Cross-site requests are not accepted."
            )
        }
        if request.headers[HTTPField.Name("Sec-Fetch-Site")!]?.lowercased() == "cross-site" {
            await record("consent.rejected", status: "403", reason: "cross_site", request: request)
            return OAuthHTTP.html(
                .forbidden,
                title: "Request refused",
                message: "Cross-site requests are not accepted."
            )
        }
        guard let form = await Self.formBody(request),
              case let .one(token) = form.value("consent_token"),
              case let .one(action) = form.value("action"), action == "allow" || action == "deny"
        else {
            await record("consent.rejected", status: "400", reason: "malformed", request: request)
            return Self.expiredPage()
        }
        guard let consent = await pending.takeConsent(token: token) else {
            await record("consent.rejected", status: "400", reason: "unknown_consent_token", request: request)
            return Self.expiredPage()
        }
        let authorization = consent.authorization
        if action == "deny" {
            await record("consent.denied", status: "302", request: request)
            return OAuthHTTP.redirect(to: OAuthHTTP.appendQuery(authorization.redirectURI, [
                ("error", "access_denied"), ("error_description", "the user denied access"),
                ("state", authorization.clientState), ("iss", settings.issuer),
            ]))
        }

        let code = OAuthCrypto.token()
        do {
            try await store.insertCode(
                hash: OAuthCrypto.storageHash(code),
                record: TokenStore.CodeRecord(
                    clientID: settings.clientID, redirectURI: authorization.redirectURI,
                    codeChallenge: authorization.codeChallenge, resource: authorization.resource, sub: consent.sub
                ),
                expiresAt: now().addingTimeInterval(settings.timings.codeTTL)
            )
        } catch {
            await record("code.failed", status: "500", reason: "store", request: request)
            return OAuthHTTP.redirect(to: OAuthHTTP.appendQuery(authorization.redirectURI, [
                ("error", "server_error"), ("state", authorization.clientState), ("iss", settings.issuer),
            ]))
        }
        await record("code.issued", status: "302", request: request)
        return OAuthHTTP.redirect(to: OAuthHTTP.appendQuery(authorization.redirectURI, [
            ("code", code), ("state", authorization.clientState), ("iss", settings.issuer),
        ]))
    }

    static func expiredPage() -> Response {
        OAuthHTTP.html(
            .badRequest, title: "Request expired",
            message: "This approval page has expired or was already used. Start again from Claude."
        )
    }
}
