import Foundation
import Hummingbird

extension OAuthServer {
    // MARK: - POST /revoke (RFC 7009)

    /// A refresh token revokes its whole family; an access token only itself;
    /// an unknown token still gets 200 (RFC 7009 §2.2). `token_type_hint` is
    /// ignored — both kinds are searched.
    func revoke(_ request: Request) async -> Response {
        guard let form = await Self.formBody(request) else {
            return OAuthHTTP.oauthError(
                .badRequest,
                "invalid_request",
                "expected an application/x-www-form-urlencoded body"
            )
        }
        if let duplicated = form.values.first(where: { $0.value.count > 1 })?.key {
            return OAuthHTTP.oauthError(.badRequest, "invalid_request", "\(duplicated) appears more than once")
        }
        guard case let .one(token) = form.value("token") else {
            return OAuthHTTP.oauthError(.badRequest, "invalid_request", "token is required")
        }
        // Public client: client_id is optional here, but must match when sent.
        // With the secret hook on, full client authentication is required.
        if settings.clientSecretDigest != nil || form.value("client_id") != .absent
            || request.headers[.authorization] != nil {
            if case let .failure(error) = authenticateClient(request, form) {
                await record("revoke", status: "\(error.response.status.code)", reason: "client_auth", request: request)
                return error.response
            }
        }
        var outcome = TokenStore.RevokeOutcome.unknown
        if OAuthText.isOurTokenShape(token) {
            do {
                outcome = try await store.revoke(hash: OAuthCrypto.storageHash(token), now: now())
            } catch {
                return OAuthHTTP.oauthError(.serviceUnavailable, "temporarily_unavailable", "token store unavailable")
            }
        }
        switch outcome {
        case let .family(id):
            await record("revoke", status: "200", family: id, reason: "refresh", request: request)
        case let .access(familyID):
            await record("revoke", status: "200", family: familyID, reason: "access", request: request)
        case .unknown:
            await record("revoke", status: "200", reason: "unknown", request: request)
        }
        var headers = OAuthHTTP.securityHeaders()
        headers[.contentLength] = "0"
        return Response(status: .ok, headers: headers)
    }
}
