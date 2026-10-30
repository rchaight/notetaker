import Foundation

/// Validates `Authorization: Bearer <token>` for `/mcp` (spec 07; replaces 06's
/// `DenyAllAuthenticator`). Runs in 06's middleware position — before the body
/// is parsed. Fails closed: any store error is a denial.
public struct TokenAuthenticator: BearerAuthenticator {
    let store: TokenStore
    let audience: String
    let clientID: String
    let now: OAuthClock

    public init(store: TokenStore, audience: String, clientID: String, now: @escaping OAuthClock = { Date() }) {
        self.store = store
        self.audience = audience
        self.clientID = clientID
        self.now = now
    }

    public func authenticate(authorizationHeader: String?) async -> AuthResult {
        guard let header = authorizationHeader, !header.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .missing
        }
        // `Bearer` (scheme case-insensitive, RFC 7235), exactly one space, then
        // one of our tokens: exactly 43 base64url characters, nothing after.
        let scheme = header.prefix(7)
        let token = header.dropFirst(7)
        guard scheme.lowercased() == "bearer ", OAuthText.isOurTokenShape(token) else {
            return .denied(description: "The access token is invalid")
        }
        guard let grant = try? await store.validateAccess(
            hash: OAuthCrypto.storageHash(String(token)), audience: audience, clientID: clientID, now: now()
        ) else {
            return .denied(description: "The access token is invalid or expired")
        }
        return .authenticated(AuthenticatedPrincipal(clientID: grant.clientID, tokenFamily: grant.familyID))
    }
}
