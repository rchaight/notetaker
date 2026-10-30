import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 test 4 plus CSRF / double-submit cases on the consent step.
struct OAuthConsentTests {
    @Test func allowRedirectsWithCodeStateAndIss() async throws {
        try await OAuthHarness.run { harness, client in
            let request = OAuthHarness.ClientRequest()
            let page = try await harness.login(client, request)
            let token = try #require(OAuthHarness.consentToken(in: page))
            let response = try await harness.consent(client, token: token)
            #expect(response.status == .found)
            #expect(response.headers[.cacheControl] == "no-store")
            let location = try #require(response.headers[.location])
            #expect(location.hasPrefix(OAuthHarness.claudeRedirect + "?"))
            let query = OAuthHarness.query(location)
            #expect(query["code"]?.count == 43)
            #expect(query["state"] == request.state)
            #expect(query["iss"] == OAuthHarness.publicURL)
            #expect(harness.events("code.issued").count == 1)

            // The same consent token again → 400, and no second code.
            let replay = try await harness.consent(client, token: token)
            #expect(replay.status == .badRequest)
            #expect(replay.headers[.location] == nil)
            #expect(harness.events("code.issued").count == 1)
        }
    }

    @Test func denyRedirectsWithAccessDenied() async throws {
        try await OAuthHarness.run { harness, client in
            let request = OAuthHarness.ClientRequest()
            let token = try #require(try await OAuthHarness.consentToken(in: harness.login(client, request)))
            let response = try await harness.consent(client, token: token, action: "deny")
            let query = OAuthHarness.query(response.headers[.location] ?? "")
            #expect(query["error"] == "access_denied")
            #expect(query["state"] == request.state)
            #expect(query["code"] == nil)
            #expect(harness.events("consent.denied").count == 1)
            #expect(harness.events("code.issued").isEmpty)
            // Deny consumed it: allow afterwards fails.
            #expect(try await harness.consent(client, token: token).status == .badRequest)
        }
    }

    @Test func consentTokenExpiresAfterFiveMinutes() async throws {
        try await OAuthHarness.run { harness, client in
            let token = try #require(try await OAuthHarness.consentToken(in: harness.login(client)))
            harness.clock.advance(5 * 60 + 1)
            #expect(try await harness.consent(client, token: token).status == .badRequest)
        }
    }

    @Test func badActionOrShapeDoesNotConsumeTheToken() async throws {
        try await OAuthHarness.run { harness, client in
            let token = try #require(try await OAuthHarness.consentToken(in: harness.login(client)))
            #expect(try await harness.consent(client, token: token, action: "maybe").status == .badRequest)
            #expect(try await harness.post(client, "/consent", [("consent_token", token)]).status == .badRequest)
            #expect(try await harness.post(
                client, "/consent", [("consent_token", token), ("action", "allow"), ("action", "deny")]
            ).status == .badRequest)
            let json = try await client.execute(
                uri: "/consent", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"consent_token\":\"\(token)\",\"action\":\"allow\"}")
            )
            #expect(json.status == .badRequest)
            #expect(try await harness.consent(client, token: "forged-" + token).status == .badRequest)
            // Still usable after all of that.
            #expect(try await harness.consent(client, token: token).status == .found)
        }
    }

    @Test func crossSiteSubmissionsAreRefused() async throws {
        try await OAuthHarness.run { harness, client in
            let token = try #require(try await OAuthHarness.consentToken(in: harness.login(client)))
            for headers: HTTPFields in [
                [.origin: "https://evil.example"], [.origin: "https://nr-test.ts.net.evil.example"],
                [HTTPField.Name("Sec-Fetch-Site")!: "cross-site"],
            ] {
                let response = try await harness.consent(client, token: token, headers: headers)
                #expect(response.status == .forbidden)
                #expect(response.headers[.location] == nil)
            }
            #expect(harness.events("consent.rejected").count == 3)
            // Same-origin (and the opaque "null" origin no-referrer pages send) work.
            let ok = try await harness.consent(
                client, token: token,
                headers: [.origin: "https://nr-test.ts.net", HTTPField.Name("Sec-Fetch-Site")!: "same-origin"]
            )
            #expect(ok.status == .found)
            let second = try #require(try await OAuthHarness.consentToken(in: harness.login(client)))
            #expect(try await harness.consent(client, token: second, headers: [.origin: "null"]).status == .found)
        }
    }

    @Test func doubleSubmittedAllowIssuesExactlyOneCode() async throws {
        try await OAuthHarness.run { harness, client in
            let token = try #require(try await OAuthHarness.consentToken(in: harness.login(client)))
            let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
                for _ in 0 ..< 2 {
                    group.addTask { try await harness.consent(client, token: token).status }
                }
                var all: [HTTPResponse.Status] = []
                for try await status in group {
                    all.append(status)
                }
                return all
            }
            #expect(statuses.sorted { $0.code < $1.code } == [.found, .badRequest])
            #expect(harness.events("code.issued").count == 1)
        }
    }

    @Test func pendingStoreEvictsTheOldestOnlyWhenFull() async {
        // (Sizing so that the authorization cap can never fill it within one TTL
        // is covered in OAuthFloodTests; this pins the eviction mechanics.)
        // And at the unit level: the 101st insert evicts exactly the oldest.
        let clock = TestClock()
        let store = PendingStore(now: clock.clock, capacity: 100)
        var gstates: [String] = []
        for _ in 0 ..< 101 {
            let gstate = OAuthCrypto.token()
            gstates.append(gstate)
            await store.insert(PendingAuthorization(
                gstate: gstate, nonce: "n", googleVerifier: "v", clientState: "s", redirectURI: "r",
                codeChallenge: "c", resource: "x", createdAt: clock.now
            ))
            clock.advance(1)
        }
        #expect(await store.take(gstate: gstates[0]) == nil)
        #expect(await store.take(gstate: gstates[1]) != nil)
        #expect(await store.take(gstate: gstates[1]) == nil) // single use
        #expect(await store.take(gstate: gstates[100]) != nil)
    }
}
