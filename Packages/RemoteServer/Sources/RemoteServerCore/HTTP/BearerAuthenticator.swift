import Foundation

/// The identity a validated bearer token resolves to. Only audit-safe fields.
public struct AuthenticatedPrincipal: Sendable, Equatable {
    public var clientID: String?
    public var tokenFamily: String?

    public init(clientID: String? = nil, tokenFamily: String? = nil) {
        self.clientID = clientID
        self.tokenFamily = tokenFamily
    }
}

public enum AuthResult: Sendable, Equatable {
    case authenticated(AuthenticatedPrincipal)
    /// No usable `Authorization: Bearer` header.
    case missing
    /// A token was presented and rejected. `description` is shown to the client
    /// in `error_description`; it must never echo the token.
    case denied(description: String)
}

/// Spec 07 implements this; the router never changes. The router passes the raw
/// `Authorization` header value (or nil) and never logs it.
public protocol BearerAuthenticator: Sendable {
    func authenticate(authorizationHeader: String?) async -> AuthResult
}

/// The default: nobody is ever authenticated. With this wired in (stage 1,
/// before spec 07), every `/mcp` request is answered 401.
public struct DenyAllAuthenticator: BearerAuthenticator {
    public init() {}

    public func authenticate(authorizationHeader: String?) async -> AuthResult {
        guard let header = authorizationHeader, !header.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .missing
        }
        return .denied(description: "The access token is invalid")
    }
}

/// The RFC 9728 / RFC 6750 challenge.
public enum UnauthorizedChallenge {
    public static func wwwAuthenticate(metadataURL: String, description: String?) -> String {
        var value = "Bearer resource_metadata=\"\(metadataURL)\""
        if let description {
            let safe = description.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }
            value += ", error=\"invalid_token\", error_description=\"\(safe)\""
        }
        return value
    }

    public static let body = Data("{\"error\":\"unauthorized\"}".utf8)
}
