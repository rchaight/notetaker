import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 test 3: the Google callback and ID-token verification, plus
/// algorithm/kid confusion and email look-alike adversarial cases.
struct OAuthCallbackTests {
    typealias Behaviour = FakeGoogle.Behaviour

    /// Logs in with the fake configured by `change`, expects the 403 page and
    /// a `login.denied` line with `reason`. Restores the default behaviour.
    private func expectDenied(
        _ harness: OAuthHarness, _ client: any TestClientProtocol, reason: String,
        sourceLocation: SourceLocation = #_sourceLocation, _ change: @escaping (inout Behaviour) -> Void
    ) async throws {
        harness.google.configure { change(&$0) }
        defer { harness.google.configure { $0 = Behaviour() } }
        let before = harness.events("login.denied").count
        let response = try await harness.login(client)
        #expect(response.status == .forbidden, "\(reason)", sourceLocation: sourceLocation)
        #expect(String(buffer: response.body).contains("This vault is not shared with that account."),
                sourceLocation: sourceLocation)
        #expect(OAuthHarness.consentToken(in: response) == nil, sourceLocation: sourceLocation)
        let denied = harness.events("login.denied")
        #expect(denied.count == before + 1, sourceLocation: sourceLocation)
        #expect(denied.last?["reason"] as? String == reason, sourceLocation: sourceLocation)
    }

    private func expectConsent(
        _ harness: OAuthHarness, _ client: any TestClientProtocol,
        sourceLocation: SourceLocation = #_sourceLocation, _ change: @escaping (inout Behaviour) -> Void = { _ in }
    ) async throws {
        harness.google.configure { change(&$0) }
        defer { harness.google.configure { $0 = Behaviour() } }
        let response = try await harness.login(client)
        #expect(response.status == .ok, sourceLocation: sourceLocation)
        #expect(OAuthHarness.consentToken(in: response)?.count == 43, sourceLocation: sourceLocation)
    }

    @Test func unknownMissingOrExpiredStateIs400() async throws {
        try await OAuthHarness.run { harness, client in
            for uri in [
                "/auth/google/callback?code=x&state=nope", "/auth/google/callback?code=x",
                "/auth/google/callback", "/auth/google/callback?state=%zz",
            ] {
                let response = try await client.execute(uri: uri, method: .get)
                #expect(response.status == .badRequest, "\(uri)")
                #expect(response.headers[.location] == nil)
            }
            // A real pending request that outlives its 10-minute TTL.
            let authorize = try await harness.authorize(client, .init())
            let callback = try await harness.googleApprove(#require(authorize.headers[.location]))
            harness.clock.advance(11 * 60)
            #expect(try await client.execute(uri: callback, method: .get).status == .badRequest)
            #expect(harness.google.counters.token == 0) // nothing was exchanged
        }
    }

    @Test func callbackIsSingleUse() async throws {
        try await OAuthHarness.run { harness, client in
            let authorize = try await harness.authorize(client, .init())
            let callback = try await harness.googleApprove(#require(authorize.headers[.location]))
            #expect(try await client.execute(uri: callback, method: .get).status == .ok)
            #expect(try await client.execute(uri: callback, method: .get).status == .badRequest)
        }
    }

    @Test func foreignAccountIsDeniedAndNeverLoggedInFull() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectDenied(harness, client, reason: "email_not_allowed") { $0.email = "other@example.com" }
            let line = try #require(harness.events("login.denied").last)
            let args = try #require(line["args"] as? [String: String])
            #expect(args["email_domain"] == "example.com")
            #expect(args["email_hash8"]?.count == 8)
            #expect(!harness.auditText.contains("other@example.com"))
            #expect(!harness.auditText.contains("other@"))
        }
    }

    @Test func everyClaimIsChecked() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectDenied(harness, client, reason: "email_unverified") {
                $0.mutate = { _, claims in claims["email_verified"] = false }
            }
            try await expectDenied(harness, client, reason: "email_unverified") {
                $0.mutate = { _, claims in claims["email_verified"] = "true" }
            }
            try await expectDenied(harness, client, reason: "email_unverified") {
                $0.mutate = { _, claims in claims["email_verified"] = 1 }
            }
            try await expectDenied(harness, client, reason: "email_unverified") {
                $0.mutate = { _, claims in claims["email_verified"] = nil }
            }
            try await expectDenied(harness, client, reason: "bad_nonce") {
                $0.mutate = { _, claims in claims["nonce"] = "not-the-nonce" }
            }
            try await expectDenied(harness, client, reason: "bad_nonce") {
                $0.mutate = { _, claims in claims["nonce"] = nil }
            }
            try await expectDenied(harness, client, reason: "bad_aud") {
                $0.mutate = { _, claims in claims["aud"] = "someone-else.apps.example" }
            }
            try await expectDenied(harness, client, reason: "bad_aud") {
                $0.mutate = { _, claims in claims["aud"] = [FakeGoogle.clientID, "someone-else"] }
            }
            try await expectDenied(harness, client, reason: "bad_aud") {
                $0.mutate = { _, claims in claims["aud"] = nil }
            }
            try await expectDenied(harness, client, reason: "bad_azp") {
                $0.mutate = { _, claims in claims["azp"] = "someone-else" }
            }
            let issuer = harness.google.issuer
            try await expectDenied(harness, client, reason: "bad_iss") {
                $0.mutate = { _, claims in claims["iss"] = "https://accounts.google.com" }
            }
            try await expectDenied(harness, client, reason: "bad_iss") {
                $0.mutate = { _, claims in claims["iss"] = issuer + "/" }
            }
            let now = Int(harness.clock.now.timeIntervalSince1970)
            try await expectDenied(harness, client, reason: "expired") {
                $0.mutate = { _, claims in claims["exp"] = now - 1 }
            }
            try await expectDenied(harness, client, reason: "expired") {
                $0.mutate = { _, claims in claims["exp"] = now }
            }
            try await expectDenied(harness, client, reason: "no_exp") {
                $0.mutate = { _, claims in claims["exp"] = "\(now + 3600)" }
            }
            try await expectDenied(harness, client, reason: "bad_iat") {
                $0.mutate = { _, claims in claims["iat"] = now + 301 }
            }
            try await expectDenied(harness, client, reason: "bad_iat") {
                $0.mutate = { _, claims in claims["iat"] = nil }
            }
            try await expectDenied(harness, client, reason: "not_yet_valid") {
                $0.mutate = { _, claims in claims["nbf"] = now + 301 }
            }
            // Tolerated: issuer without scheme, single-element aud array, small skew.
            let bare = issuer.replacingOccurrences(of: "http://", with: "")
            try await expectConsent(harness, client) { $0.mutate = { _, claims in claims["iss"] = bare } }
            try await expectConsent(harness, client) {
                $0.mutate = { _, claims in claims["aud"] = [FakeGoogle.clientID] }
            }
            try await expectConsent(harness, client) {
                $0.mutate = { _, claims in
                    claims["iat"] = now + 299
                    claims["nbf"] = now + 299
                }
            }
        }
    }

    @Test func algorithmAndKeyConfusionAreRejected() async throws {
        try await OAuthHarness.run { harness, client in
            // alg=none carries an empty signature segment: refused as malformed before alg is read.
            try await expectDenied(harness, client, reason: "malformed") { $0.signer = .none }
            try await expectDenied(harness, client, reason: "bad_alg") {
                $0.signer = .key(kid: "k1")
                $0.mutate = { header, _ in header["alg"] = "none" } // signed, but claims alg=none
            }
            try await expectDenied(harness, client, reason: "bad_alg") { $0.signer = .hs256WithPublicKey }
            try await expectDenied(harness, client, reason: "bad_alg") {
                $0.mutate = { header, _ in header["alg"] = "rs256" }
            }
            try await expectDenied(harness, client, reason: "bad_alg") {
                $0.mutate = { header, _ in header["alg"] = "PS256" }
            }
            try await expectDenied(harness, client, reason: "bad_signature") { $0.signer = .pss }
            try await expectDenied(harness, client, reason: "bad_signature") { $0.signer = .rogueUnderKnownKid }
            try await expectDenied(harness, client, reason: "bad_header") {
                $0.signer = .rogueUnderKnownKid
                $0.mutate = { header, _ in header["jwk"] = TestKeys.jwk(TestKeys.rogue, kid: "k1") }
            }
            try await expectDenied(harness, client, reason: "bad_header") {
                $0.mutate = { header, _ in header["jku"] = "https://evil.example/jwks" }
            }
            try await expectDenied(harness, client, reason: "bad_header") {
                $0.mutate = { header, _ in header["crit"] = ["exp"] }
            }
            try await expectDenied(harness, client, reason: "no_kid") {
                $0.mutate = { header, _ in header["kid"] = nil }
            }
            try await expectDenied(harness, client, reason: "malformed") { $0.signer = .raw("abc.def") }
            try await expectDenied(harness, client, reason: "malformed") { $0.signer = .raw("a.b.c.d") }
            try await expectDenied(harness, client, reason: "malformed") { $0.signer = .raw("e30=.e30=.AA==") }
            try await expectDenied(harness, client, reason: "malformed") {
                $0.signer = .raw(String(repeating: "A", count: 20000) + ".e30.AA")
            }
            // A valid token with its payload swapped for another account's.
            let valid = FakeGoogle.sign(
                header: ["alg": "RS256", "kid": "k1"], claims: ["email": "rchaight@gmail.com"], signer: .key(kid: "k1")
            )
            let parts = valid.split(separator: ".")
            let swapped = Base64URL.encode(Data("{\"email\":\"other@example.com\"}".utf8))
            try await expectDenied(harness, client, reason: "bad_signature") {
                $0.signer = .raw("\(parts[0]).\(swapped).\(parts[2])")
            }
        }
    }

    @Test func unknownKidForcesExactlyOneJWKSRefetch() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectDenied(harness, client, reason: "unknown_kid") { $0.signer = .key(kid: "k9") }
            #expect(harness.google.counters.certs == 2)
        }
    }

    @Test func keyRotationIsPickedUpByTheForcedRefetch() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectConsent(harness, client) // caches {k1}
            #expect(harness.google.counters.certs == 1)
            try await expectConsent(harness, client) // cached
            #expect(harness.google.counters.certs == 1)
            harness.clock.advance(31) // past the forced-refetch spacing
            try await expectConsent(harness, client) {
                $0.publishedKids = ["k1", "k2"]
                $0.signer = .key(kid: "k2")
            }
            #expect(harness.google.counters.certs == 2)
            // A second unknown kid right away does not hammer Google again.
            try await expectDenied(harness, client, reason: "unknown_kid") { $0.signer = .key(kid: "k7") }
            #expect(harness.google.counters.certs == 2)
        }
    }

    @Test func emailIsExactAfterASCIICaseFolding() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectConsent(harness, client) { $0.email = "RCHAIGHT@Gmail.com" }
            for lookalike in [
                "rchaight+claude@gmail.com", "r.chaight@gmail.com", "rchaight@gmail.com ", " rchaight@gmail.com",
                "rchaight@gmail.com\u{0}", "rchaight@gmail.com.evil.example", "rchaight@googlemail.com",
                "rchaight@gmail.co", "rсhaight@gmail.com", /* Cyrillic с */ "ｒchaight@gmail.com", /* fullwidth */
                "rchaight@gmaıl.com", /* dotless ı */ "RCHAİGHT@gmail.com", /* dotted İ */ "rchaight@gmail.com\n",
                "evil@example.com,rchaight@gmail.com", "",
            ] {
                try await expectDenied(harness, client, reason: "email_not_allowed") { $0.email = lookalike }
            }
            try await expectDenied(harness, client, reason: "email_not_allowed") {
                $0.mutate = { _, claims in claims["email"] = ["rchaight@gmail.com"] }
            }
        }
    }

    @Test func unicodeCaseFoldingCannotSmuggleAKelvinSign() async throws {
        // U+212A KELVIN SIGN lowercases to ASCII "k" under Unicode rules.
        #expect("\u{212A}ate@example.com".lowercased() == "kate@example.com")
        try await OAuthHarness.run(env: ["NR_ALLOWED_EMAIL": "kate@example.com"]) { harness, client in
            try await expectDenied(harness, client, reason: "email_not_allowed") { $0.email = "\u{212A}ate@example.com"
            }
            try await expectConsent(harness, client) { $0.email = "KATE@example.com" }
        }
        #expect(!IDTokenVerifier.emailMatches("\u{212A}ate@example.com", allowed: "kate@example.com"))
    }

    @Test func consentPageNamesTheRedirectHostAndIsHardened() async throws {
        try await OAuthHarness.run { harness, client in
            let page = try await harness.login(client)
            let html = String(buffer: page.body)
            #expect(html.contains("<strong>claude.ai</strong>"))
            #expect(html.contains("vault:read"))
            #expect(page.headers[.contentSecurityPolicy]?.contains("frame-ancestors 'none'") == true)
            #expect(page.headers[HTTPField.Name("X-Frame-Options")!] == "DENY")
            #expect(page.headers[.cacheControl] == "no-store")
            #expect(page.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
            #expect(page.headers[.setCookie] == nil)
            #expect(!html.contains("<script"))
            #expect(harness.events("login.ok").count == 1)
        }
        try await OAuthHarness.run(env: ["NR_ALLOW_LOOPBACK": "1"]) { harness, client in
            var request = OAuthHarness.ClientRequest()
            request.redirectURI = "http://127.0.0.1:8765/cb"
            let html = try await String(buffer: harness.login(client, request).body)
            #expect(html.contains("<strong>127.0.0.1</strong>"))
        }
    }

    @Test func googleSideCancellationReturnsAccessDeniedToTheClient() async throws {
        try await OAuthHarness.run { harness, client in
            let request = OAuthHarness.ClientRequest()
            let authorize = try await harness.authorize(client, request)
            let googleURL = try #require(authorize.headers[.location])
            let gstate = try #require(OAuthHarness.query(googleURL)["state"])
            let response = try await client.execute(
                uri: "/auth/google/callback?error=access_denied&state=" + gstate, method: .get
            )
            #expect(response.status == .found)
            let query = OAuthHarness.query(response.headers[.location] ?? "")
            #expect(query["error"] == "access_denied")
            #expect(query["state"] == request.state)
            #expect(harness.events("login.cancelled").count == 1)
            #expect(harness.events("login.denied").isEmpty)
        }
    }

    @Test func googleTokenEndpointFailureIsDenied() async throws {
        try await OAuthHarness.run { harness, client in
            try await expectDenied(harness, client, reason: "token_exchange_failed") { $0.tokenStatus = 500 }
            // The exchange carried our confidential credentials and PKCE verifier.
            let form = try #require(harness.google.counters.tokenForms.last)
            #expect(form["client_secret"] == FakeGoogle.clientSecret)
            #expect(form["code_verifier"]?.count == 43)
            #expect(form["redirect_uri"] == "https://nr-test.ts.net/auth/google/callback")
        }
    }

    @Test func missingCodeIsDenied() async throws {
        try await OAuthHarness.run { harness, client in
            let authorize = try await harness.authorize(client, .init())
            let googleURL = try #require(authorize.headers[.location])
            let gstate = try #require(OAuthHarness.query(googleURL)["state"])
            let response = try await client.execute(uri: "/auth/google/callback?state=" + gstate, method: .get)
            #expect(response.status == .forbidden)
            #expect(harness.events("login.denied").last?["reason"] as? String == "missing_code")
        }
    }
}
