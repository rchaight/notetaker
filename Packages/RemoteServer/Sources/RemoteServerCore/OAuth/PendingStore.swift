import Foundation

/// A validated `/authorize` request waiting for the Google round trip.
struct PendingAuthorization: Sendable, Equatable {
    /// Our `state` toward Google.
    var gstate: String
    var nonce: String
    /// PKCE verifier toward Google.
    var googleVerifier: String
    /// The client's own `state`, echoed back verbatim.
    var clientState: String
    var redirectURI: String
    var codeChallenge: String
    /// Always `resourceURL` (absent in the request → bound to it anyway).
    var resource: String
    var createdAt: Date
}

/// A logged-in user looking at the consent page.
struct PendingConsent: Sendable, Equatable {
    var authorization: PendingAuthorization
    var sub: String
    var createdAt: Date
}

/// In-memory, single-use, TTL-bound and capped (oldest evicted). Keys are the
/// SHA-256 of the secret handle (`gstate`, `consent_token`), never the handle.
actor PendingStore {
    static let capacity = 100

    private let now: OAuthClock
    private let pendingTTL: TimeInterval
    private let consentTTL: TimeInterval
    private var authorizations: [String: PendingAuthorization] = [:]
    private var consents: [String: PendingConsent] = [:]

    init(now: @escaping OAuthClock, pendingTTL: TimeInterval = 600, consentTTL: TimeInterval = 300) {
        self.now = now
        self.pendingTTL = pendingTTL
        self.consentTTL = consentTTL
    }

    var pendingCount: Int {
        authorizations.count
    }

    var consentCount: Int {
        consents.count
    }

    func insert(_ pending: PendingAuthorization) {
        let moment = now()
        authorizations = authorizations.filter { moment.timeIntervalSince($0.value.createdAt) < pendingTTL }
        while authorizations.count >= Self.capacity,
              let oldest = authorizations.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            authorizations[oldest] = nil
        }
        authorizations[OAuthCrypto.storageHash(pending.gstate)] = pending
    }

    /// Lookup + remove. Expired entries are removed and reported as unknown.
    func take(gstate: String) -> PendingAuthorization? {
        guard let found = authorizations.removeValue(forKey: OAuthCrypto.storageHash(gstate)) else { return nil }
        return now().timeIntervalSince(found.createdAt) < pendingTTL ? found : nil
    }

    /// Stores a consent record and returns its fresh single-use token.
    func insertConsent(_ consent: PendingConsent) -> String {
        let moment = now()
        consents = consents.filter { moment.timeIntervalSince($0.value.createdAt) < consentTTL }
        while consents.count >= Self.capacity,
              let oldest = consents.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            consents[oldest] = nil
        }
        let token = OAuthCrypto.token()
        consents[OAuthCrypto.storageHash(token)] = consent
        return token
    }

    func takeConsent(token: String) -> PendingConsent? {
        guard let found = consents.removeValue(forKey: OAuthCrypto.storageHash(token)) else { return nil }
        return now().timeIntervalSince(found.createdAt) < consentTTL ? found : nil
    }
}
