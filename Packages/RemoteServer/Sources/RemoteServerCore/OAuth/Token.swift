import Foundation
import HTTPTypes
import Hummingbird

extension OAuthServer {
    // MARK: - POST /token

    func token(_ request: Request) async -> Response {
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
        switch authenticateClient(request, form) {
        case let .failure(error):
            await record(
                "token.rejected",
                status: "\(error.response.status.code)",
                reason: "client_auth",
                request: request
            )
            return error.response
        case .success:
            break
        }
        switch form.value("grant_type") {
        case .one("authorization_code"):
            return await exchangeCode(form, request)
        case .one("refresh_token"):
            return await refresh(form, request)
        case .absent:
            return OAuthHTTP.oauthError(.badRequest, "invalid_request", "grant_type is required")
        default:
            return OAuthHTTP.oauthError(.badRequest, "unsupported_grant_type", "unsupported grant_type")
        }
    }

    /// Public client: `client_id` must equal the configured one (constant time).
    /// With the optional secret hook, `client_secret_post` or `_basic` must also
    /// match its SHA-256. Using both methods at once is `invalid_request`.
    func authenticateClient(_ request: Request, _ form: FormData) -> Result<Void, ErrorResponse> {
        var basic: (id: String, secret: String)?
        var usedBasic = false
        if let header = request.headers[.authorization] {
            guard let parsed = Self.parseBasic(header) else {
                return .failure(ErrorResponse(OAuthHTTP.oauthError(
                    .badRequest, "invalid_request", "unsupported Authorization header"
                )))
            }
            basic = parsed
            usedBasic = true
        }
        let formID = form.value("client_id")
        let formSecret = form.value("client_secret")
        if usedBasic, formSecret != .absent {
            return .failure(ErrorResponse(OAuthHTTP.oauthError(
                .badRequest, "invalid_request", "use one client authentication method"
            )))
        }
        var challenge = HTTPFields()
        if usedBasic {
            challenge[.wwwAuthenticate] = "Basic realm=\"notetaker-remote\""
        }
        let invalidClient = ErrorResponse(OAuthHTTP.oauthError(
            .unauthorized, "invalid_client", "client authentication failed", headers: challenge
        ))
        let clientID: String
        switch (basic?.id, formID) {
        case let (basicID?, .one(formValue)):
            guard basicID == formValue else { return .failure(invalidClient) }
            clientID = basicID
        case let (basicID?, .absent):
            clientID = basicID
        case let (nil, .one(formValue)):
            clientID = formValue
        default:
            return .failure(invalidClient)
        }
        guard OAuthCrypto.constantTimeEquals(clientID, settings.clientID) else { return .failure(invalidClient) }
        if let digest = settings.clientSecretDigest {
            let presented: String? = if let basic {
                basic.secret
            } else if case let .one(value) = formSecret {
                value
            } else {
                nil
            }
            guard let presented, !presented.isEmpty,
                  OAuthCrypto.constantTimeEquals(OAuthCrypto.sha256(presented), digest)
            else { return .failure(invalidClient) }
        }
        return .success(())
    }

    struct ErrorResponse: Error {
        let response: Response

        init(_ response: Response) {
            self.response = response
        }
    }

    /// RFC 6749 §2.3.1: `Basic base64(urlencode(id) ":" urlencode(secret))`.
    static func parseBasic(_ header: String) -> (id: String, secret: String)? {
        guard header.count > 6, header.prefix(6).lowercased() == "basic ",
              let decoded = Data(base64Encoded: String(header.dropFirst(6))),
              let text = String(data: decoded, encoding: .utf8),
              let colon = text.firstIndex(of: ":"),
              let id = String(text[..<colon]).removingPercentEncoding,
              let secret = String(text[text.index(after: colon)...]).removingPercentEncoding
        else { return nil }
        return (id, secret)
    }

    // MARK: authorization_code

    private func exchangeCode(_ form: FormData, _ request: Request) async -> Response {
        // Shape checks first: a malformed request never burns a code.
        guard case let .one(code) = form.value("code"), case let .one(redirectURI) = form.value("redirect_uri"),
              case let .one(verifier) = form.value("code_verifier")
        else {
            return OAuthHTTP.oauthError(
                .badRequest,
                "invalid_request",
                "code, redirect_uri and code_verifier are required"
            )
        }
        guard OAuthText.isPKCEValue(verifier) else {
            return OAuthHTTP.oauthError(.badRequest, "invalid_request", "code_verifier is malformed")
        }
        var requestedResource: String?
        if case let .one(value) = form.value("resource") {
            guard value == settings.resourceURL else {
                return OAuthHTTP.oauthError(.badRequest, "invalid_target", "unknown resource")
            }
            requestedResource = value
        }
        let resource = requestedResource
        guard OAuthText.isOurTokenShape(code) else {
            await record("token.rejected", status: "400", reason: "code_unknown", request: request)
            return Self.invalidGrant()
        }

        let moment = now()
        let issued = mintPair()
        let settings = settings
        let challenge = OAuthCrypto.pkceChallenge(for: verifier)
        let outcome: TokenStore.CodeOutcome
        do {
            outcome = try await store.redeemCode(
                hash: OAuthCrypto.storageHash(code), now: moment,
                check: { record in
                    if !OAuthCrypto.constantTimeEquals(record.clientID, settings.clientID) {
                        return "client_mismatch"
                    }
                    if record.redirectURI != redirectURI {
                        return "redirect_uri_mismatch"
                    }
                    if !OAuthCrypto.constantTimeEquals(challenge, record.codeChallenge) {
                        return "pkce_mismatch"
                    }
                    if let resource, resource != record.resource {
                        return "resource_mismatch"
                    }
                    return nil
                },
                family: { record in
                    let absolute = moment.addingTimeInterval(settings.timings.refreshAbsolute)
                    let family = TokenStore.FamilyRecord(
                        id: issued.familyID, clientID: record.clientID, sub: record.sub, aud: record.resource,
                        createdAt: moment, absoluteExpiry: absolute
                    )
                    return (family, issued.hashes(now: moment, absolute: absolute, timings: settings.timings))
                }
            )
        } catch {
            return OAuthHTTP.oauthError(.internalServerError, "server_error", "token store unavailable")
        }
        switch outcome {
        case .issued:
            await record("token.issued", status: "200", family: issued.familyID, request: request)
            let absolute = moment.addingTimeInterval(settings.timings.refreshAbsolute)
            return tokenResponse(issued, now: moment, absolute: absolute)
        case .notFound:
            await record("token.rejected", status: "400", reason: "code_unknown", request: request)
        case .expired:
            await record("token.rejected", status: "400", reason: "code_expired", request: request)
        case let .reused(family):
            await record("code.reuse", status: "400", family: family, request: request)
        case let .rejected(reason):
            await record("token.rejected", status: "400", reason: reason, request: request)
        }
        return Self.invalidGrant()
    }

    // MARK: refresh_token

    private func refresh(_ form: FormData, _ request: Request) async -> Response {
        guard case let .one(refreshToken) = form.value("refresh_token") else {
            return OAuthHTTP.oauthError(.badRequest, "invalid_request", "refresh_token is required")
        }
        if case let .one(scope) = form.value("scope"),
           !scope.split(separator: " ").allSatisfy({ $0 == OAuthSettings.scope }) {
            return OAuthHTTP.oauthError(.badRequest, "invalid_scope", "the only scope is vault:read")
        }
        if case let .one(resource) = form.value("resource"), resource != settings.resourceURL {
            return OAuthHTTP.oauthError(.badRequest, "invalid_target", "unknown resource")
        }
        guard OAuthText.isOurTokenShape(refreshToken) else {
            await record("token.rejected", status: "400", reason: "refresh_unknown", request: request)
            return Self.invalidGrant()
        }
        let moment = now()
        let issued = mintPair()
        let timings = settings.timings
        let outcome: TokenStore.RefreshOutcome
        do {
            outcome = try await store.rotateRefresh(
                hash: OAuthCrypto.storageHash(refreshToken), clientID: settings.clientID, now: moment
            ) { family in
                var tokens = issued.hashes(now: moment, absolute: family.absoluteExpiry, timings: timings)
                tokens.familyID = family.id
                return tokens
            }
        } catch {
            return OAuthHTTP.oauthError(.internalServerError, "server_error", "token store unavailable")
        }
        switch outcome {
        case let .rotated(familyID, absolute):
            await record("refresh.rotated", status: "200", family: familyID, request: request)
            return tokenResponse(issued, now: moment, absolute: absolute)
        case .notFound:
            await record("token.rejected", status: "400", reason: "refresh_unknown", request: request)
        case let .reused(familyID):
            await record("refresh.reuse", status: "400", family: familyID, request: request)
        case let .rejected(reason, familyID):
            await record("token.rejected", status: "400", family: familyID, reason: reason, request: request)
        }
        return Self.invalidGrant()
    }

    // MARK: minting

    struct MintedPair: Sendable {
        let familyID: String
        let accessToken: String
        let refreshToken: String

        func hashes(now: Date, absolute: Date, timings: OAuthSettings.Timings) -> TokenStore.NewTokens {
            TokenStore.NewTokens(
                familyID: familyID,
                accessHash: OAuthCrypto.storageHash(accessToken),
                refreshHash: OAuthCrypto.storageHash(refreshToken),
                accessExpiry: min(now.addingTimeInterval(timings.accessTTL), absolute),
                refreshExpiry: min(now.addingTimeInterval(timings.refreshIdle), absolute)
            )
        }
    }

    func mintPair() -> MintedPair {
        MintedPair(
            familyID: OAuthCrypto.token(bytes: 16), accessToken: OAuthCrypto.token(), refreshToken: OAuthCrypto.token()
        )
    }

    func tokenResponse(_ pair: MintedPair, now: Date, absolute: Date) -> Response {
        let expiry = min(now.addingTimeInterval(settings.timings.accessTTL), absolute)
        return OAuthHTTP.json(.ok, [
            "access_token": pair.accessToken,
            "token_type": "Bearer",
            "expires_in": max(1, Int(expiry.timeIntervalSince(now).rounded(.down))),
            "refresh_token": pair.refreshToken,
            "scope": OAuthSettings.scope,
        ])
    }

    static func invalidGrant() -> Response {
        OAuthHTTP.oauthError(.badRequest, "invalid_grant", "the grant is invalid, expired, or was already used")
    }
}
