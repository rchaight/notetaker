import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 tests 5, 6 and 11: the token endpoint.
struct OAuthTokenTests {
    typealias Request = OAuthHarness.ClientRequest

    private func error(_ response: TestResponse) throws -> String? {
        try OAuthHarness.json(response)["error"] as? String
    }

    // MARK: authorization_code (test 5)

    @Test func happyPathReturnsOpaqueTokensWithNoStore() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            let response = try await harness.exchange(client, code: code, verifier: request.verifier)
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[OAuthHTTP.pragma] == "no-cache")
            #expect(response.headers[.contentType] == "application/json")
            let json = try OAuthHarness.json(response)
            #expect(json["token_type"] as? String == "Bearer")
            #expect(json["expires_in"] as? Int == 900)
            #expect(json["scope"] as? String == "vault:read")
            for key in ["access_token", "refresh_token"] {
                let value = try #require(json[key] as? String)
                #expect(value.count == 43)
                #expect(value.unicodeScalars.allSatisfy(Base64URL.isAlphabet))
            }
            #expect(json["access_token"] as? String != json["refresh_token"] as? String)
            #expect(json["id_token"] == nil)
            #expect(harness.events("token.issued").count == 1)
            #expect(harness.events("token.issued").first?["token_family"] as? String != nil)
        }
    }

    @Test func bindingMismatchesAreInvalidGrantAndBurnTheCode() async throws {
        try await OAuthHarness.run { harness, client in
            func burned(
                _ attempt: (String, Request) async throws -> TestResponse,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws {
                let request = Request()
                let code = try await harness.code(client, request)
                let response = try await attempt(code, request)
                #expect(response.status == .badRequest, sourceLocation: sourceLocation)
                #expect(try error(response) == "invalid_grant", sourceLocation: sourceLocation)
                // The right request afterwards fails too: a code gets one attempt.
                let retry = try await harness.exchange(client, code: code, verifier: request.verifier)
                #expect(try error(retry) == "invalid_grant", sourceLocation: sourceLocation)
            }
            // PKCE verifier mismatch.
            try await burned { code, _ in
                try await harness.exchange(client, code: code, verifier: OAuthCrypto.token())
            }
            // "plain" downgrade: the challenge itself presented as the verifier.
            try await burned { code, request in
                try await harness.exchange(
                    client,
                    code: code,
                    verifier: OAuthCrypto.pkceChallenge(for: request.verifier)
                )
            }
            // redirect_uri mismatch (trailing slash).
            try await burned { code, request in
                try await harness.exchange(
                    client, code: code, verifier: request.verifier, redirectURI: OAuthHarness.claudeRedirect + "/"
                )
            }
            #expect(harness.events("token.issued").isEmpty)
            let reasons = harness.events("token.rejected").compactMap { $0["reason"] as? String }
            #expect(reasons.contains("pkce_mismatch"))
            #expect(reasons.contains("redirect_uri_mismatch"))
        }
    }

    @Test func codeInjectionWithAnotherFlowsVerifierFails() async throws {
        try await OAuthHarness.run { harness, client in
            let victim = Request()
            let attacker = Request()
            let victimCode = try await harness.code(client, victim)
            _ = try await harness.code(client, attacker)
            let response = try await harness.exchange(client, code: victimCode, verifier: attacker.verifier)
            #expect(try error(response) == "invalid_grant")
        }
    }

    @Test func missingOrMalformedVerifierIsInvalidRequestAndKeepsTheCode() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            let missing = try await harness.post(client, "/token", [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", OAuthHarness.claudeRedirect),
                ("client_id", OAuthHarness.clientID),
            ])
            #expect(try error(missing) == "invalid_request")
            for bad in ["short", String(repeating: "a", count: 129), String(repeating: "a", count: 42) + "/"] {
                #expect(try await error(harness.exchange(client, code: code, verifier: bad)) == "invalid_request")
            }
            #expect(try await error(harness.exchange(
                client, code: code, verifier: request.verifier, extra: [("resource", "https://evil/mcp")]
            )) == "invalid_target")
            // None of that consumed the code.
            let ok = try await harness.exchange(
                client, code: code, verifier: request.verifier, extra: [("resource", OAuthHarness.resource)]
            )
            #expect(ok.status == .ok)
        }
    }

    @Test func wrongClientIsInvalidClient401() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            for clientID in ["nr-attacker-0123456789abcdef", OAuthHarness.clientID.uppercased(), ""] {
                let response = try await harness.exchange(
                    client,
                    code: code,
                    verifier: request.verifier,
                    clientID: clientID
                )
                #expect(response.status == .unauthorized)
                #expect(try error(response) == "invalid_client")
            }
            // Client auth fails before the code is touched: it still works.
            #expect(try await harness.exchange(client, code: code, verifier: request.verifier).status == .ok)
        }
    }

    @Test func expiredCodeIsInvalidGrant() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            harness.clock.advance(61)
            #expect(try await error(harness.exchange(client, code: code, verifier: request.verifier)) ==
                "invalid_grant")
            #expect(harness.events("token.rejected").last?["reason"] as? String == "code_expired")
        }
    }

    @Test func codeReuseRevokesEverythingTheFirstExchangeProduced() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            let first = try await OAuthHarness.json(harness.exchange(client, code: code, verifier: request.verifier))
            let access = try #require(first["access_token"] as? String)
            let refresh = try #require(first["refresh_token"] as? String)
            #expect(try await harness.mcpStatus(client, access).status == .ok)

            let replay = try await harness.exchange(client, code: code, verifier: request.verifier)
            #expect(try error(replay) == "invalid_grant")
            #expect(harness.events("code.reuse").count == 1)
            #expect(try await harness.mcpStatus(client, access).status == .unauthorized)
            #expect(try await error(harness.refresh(client, refresh)) == "invalid_grant")
        }
    }

    @Test func concurrentRedemptionsOfOneCodeNeverBothSucceed() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
                for _ in 0 ..< 4 {
                    group.addTask { try await harness.exchange(client, code: code, verifier: request.verifier).status }
                }
                var all: [HTTPResponse.Status] = []
                for try await status in group {
                    all.append(status)
                }
                return all
            }
            #expect(statuses.count(where: { $0 == .ok }) <= 1)
            #expect(harness.events("token.issued").count <= 1)
        }
    }

    @Test func malformedTokenRequestsAreRejectedPerRFC6749() async throws {
        try await OAuthHarness.run { harness, client in
            let base = [("client_id", OAuthHarness.clientID)]
            #expect(try await error(harness.post(client, "/token", base)) == "invalid_request")
            #expect(try await error(harness.post(client, "/token", base + [("grant_type", "password")]))
                == "unsupported_grant_type")
            #expect(try await error(harness.post(client, "/token", base + [("grant_type", "client_credentials")]))
                == "unsupported_grant_type")
            #expect(try await error(harness.post(
                client, "/token", base + [("grant_type", "refresh_token"), ("grant_type", "authorization_code")]
            )) == "invalid_request")
            let json = try await client.execute(
                uri: "/token", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"grant_type\":\"authorization_code\"}")
            )
            #expect(json.status == .badRequest)
            #expect(try error(json) == "invalid_request")
            let badEncoding = try await client.execute(
                uri: "/token", method: .post, headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "grant_type=authorization_code&code=%zz")
            )
            #expect(try error(badEncoding) == "invalid_request")
            let notUTF8 = try await client.execute(
                uri: "/token", method: .post, headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(bytes: [0x67, 0x3D, 0xFF, 0xFE])
            )
            #expect(try error(notUTF8) == "invalid_request")
            let huge = try await client.execute(
                uri: "/token", method: .post, headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "code=" + String(repeating: "a", count: 70 * 1024))
            )
            #expect(huge.status == .contentTooLarge)
            // GET is not a token request.
            #expect(try await client.execute(uri: "/token?grant_type=refresh_token", method: .get).status != .ok)
            // A bearer header on /token, or Basic + form secret, is refused.
            #expect(try await error(harness.post(
                client, "/token", base + [("grant_type", "refresh_token")], headers: [.authorization: "Bearer abc"]
            )) == "invalid_request")
            let basic = "Basic " + Data("\(OAuthHarness.clientID):x".utf8).base64EncodedString()
            #expect(try await error(harness.post(
                client, "/token", [("grant_type", "refresh_token"), ("client_secret", "x")],
                headers: [.authorization: basic]
            )) == "invalid_request")
            let mismatched = try await harness.post(
                client, "/token", [("grant_type", "refresh_token"), ("client_id", "nr-other-0123456789abcdef")],
                headers: [.authorization: basic]
            )
            #expect(mismatched.status == .unauthorized)
            #expect(mismatched.headers[.wwwAuthenticate]?.hasPrefix("Basic") == true)
        }
    }

    // MARK: refresh_token (test 6)

    @Test func refreshRotatesAndReuseRevokesTheFamily() async throws {
        try await OAuthHarness.run { harness, client in
            let first = try await harness.tokens(client)
            let rotated = try await harness.refresh(client, first.refresh)
            #expect(rotated.status == .ok)
            #expect(rotated.headers[.cacheControl] == "no-store")
            let json = try OAuthHarness.json(rotated)
            let newAccess = try #require(json["access_token"] as? String)
            let newRefresh = try #require(json["refresh_token"] as? String)
            #expect(newAccess != first.access && newRefresh != first.refresh)
            #expect(json["expires_in"] as? Int == 900)
            #expect(harness.events("refresh.rotated").count == 1)
            let superseded = try await harness.store.withDatabase { db in
                try Double.fetchOne(
                    db, sql: "SELECT superseded_at FROM token WHERE hash = ?",
                    arguments: [OAuthCrypto.storageHash(first.refresh)]
                )
            }
            #expect(superseded != nil)
            #expect(try await harness.mcpStatus(client, newAccess).status == .ok)

            // The old refresh token again: reuse → the whole family dies.
            let reuse = try await harness.refresh(client, first.refresh)
            #expect(try error(reuse) == "invalid_grant")
            #expect(harness.events("refresh.reuse").count == 1)
            #expect(try await harness.mcpStatus(client, newAccess).status == .unauthorized)
            #expect(try await harness.mcpStatus(client, first.access).status == .unauthorized)
            #expect(try await error(harness.refresh(client, newRefresh)) == "invalid_grant")
        }
    }

    @Test func idleExpiryIsFourteenDays() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            harness.clock.advance(14 * 86400 + 1)
            #expect(try await error(harness.refresh(client, tokens.refresh)) == "invalid_grant")
            #expect(harness.events("token.rejected").last?["reason"] as? String == "idle_expired")
        }
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            harness.clock.advance(14 * 86400 - 1)
            #expect(try await harness.refresh(client, tokens.refresh).status == .ok)
        }
    }

    @Test func absoluteExpiryIsThirtyDaysEvenWithDailyUse() async throws {
        try await OAuthHarness.run { harness, client in
            var refresh = try await harness.tokens(client).refresh
            for day in 1 ... 29 {
                harness.clock.advance(86400)
                let response = try await harness.refresh(client, refresh)
                #expect(response.status == .ok, "day \(day)")
                refresh = try #require(try OAuthHarness.json(response)["refresh_token"] as? String)
                if day == 29 {
                    // The access token never outlives the family.
                    #expect(try OAuthHarness.json(response)["expires_in"] as? Int == 900)
                }
            }
            // Five minutes before the absolute end, the access token is cut short.
            harness.clock.advance(86400 - 300)
            let last = try await harness.refresh(client, refresh)
            #expect(try OAuthHarness.json(last)["expires_in"] as? Int == 300)
            refresh = try #require(try OAuthHarness.json(last)["refresh_token"] as? String)
            harness.clock.advance(300)
            #expect(try await error(harness.refresh(client, refresh)) == "invalid_grant")
            #expect(harness.events("token.rejected").last?["reason"] as? String == "absolute_expired")
        }
    }

    @Test func refreshFromAnotherClientIsInvalidGrant() async throws {
        // Tokens minted for one client ID; the server is then reconfigured with a
        // different (rotated) client ID over the same store.
        let clock = TestClock()
        let google = FakeGoogle(clock: clock)
        try await google.run { google in
            let original = try await OAuthHarness.make(google: google, clock: clock, env: [:], authPerMinute: 1000)
            defer { original.fixture.cleanUp() }
            let tokens = try await original.app().test(.router) { client in try await original.tokens(client) }
            let rotatedID = "nr-rotated-client-0123456789ab"
            let rotated = try await OAuthHarness.make(
                google: google, clock: clock, env: ["NR_OAUTH_CLIENT_ID": rotatedID], authPerMinute: 1000,
                fixture: original.fixture
            )
            try await rotated.app().test(.router) { client in
                let response = try await rotated.refresh(client, tokens.refresh, clientID: rotatedID)
                #expect(try error(response) == "invalid_grant")
                #expect(rotated.events("token.rejected").last?["reason"] as? String == "client_mismatch")
                // The old client ID itself is now simply unknown.
                #expect(try await rotated.refresh(client, tokens.refresh).status == .unauthorized)
                // And its access token no longer opens /mcp.
                #expect(try await rotated.mcpStatus(client, tokens.access).status == .unauthorized)
            }
            await original.mcp.stop()
            await rotated.mcp.stop()
        }
    }

    @Test func unknownOrWrongKindRefreshTokensAreInvalidGrant() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            for candidate in [OAuthCrypto.token(), tokens.access, "short", tokens.refresh + "x"] {
                #expect(try await error(harness.refresh(client, candidate)) == "invalid_grant", "\(candidate.count)")
            }
            #expect(try await error(harness.refresh(client, tokens.refresh, extra: [("scope", "admin")])) ==
                "invalid_scope")
            #expect(try await error(harness.refresh(client, tokens.refresh, extra: [("resource", "https://evil/mcp")]))
                == "invalid_target")
            let missing = try await harness.post(client, "/token", [
                ("grant_type", "refresh_token"), ("client_id", OAuthHarness.clientID),
            ])
            #expect(try error(missing) == "invalid_request")
            // None of the above disturbed the real refresh token.
            #expect(try await harness.refresh(client, tokens.refresh, extra: [("scope", "vault:read")]).status == .ok)
        }
    }

    @Test func concurrentRefreshWithOneTokenNeverForksTheFamily() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            let winners = try await withThrowingTaskGroup(of: String?.self) { group in
                for _ in 0 ..< 3 {
                    group.addTask {
                        let response = try await harness.refresh(client, tokens.refresh)
                        guard response.status == .ok else { return nil }
                        return try OAuthHarness.json(response)["access_token"] as? String
                    }
                }
                var all: [String] = []
                for try await result in group {
                    if let result {
                        all.append(result)
                    }
                }
                return all
            }
            // At most one rotation wins; a racing second use counts as reuse and
            // revokes the family (RFC 9700 §4.14.2) — the winner's tokens die too.
            #expect(winners.count <= 1)
            if let access = winners.first, harness.events("refresh.reuse").count > 0 {
                #expect(try await harness.mcpStatus(client, access).status == .unauthorized)
            }
        }
    }

    // MARK: storage (hashing at rest)

    @Test func noTokenOrCodeIsStoredInPlaintext() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let code = try await harness.code(client, request)
            let json = try await OAuthHarness.json(harness.exchange(client, code: code, verifier: request.verifier))
            let access = try #require(json["access_token"] as? String)
            let refresh = try #require(json["refresh_token"] as? String)
            let rotated = try await OAuthHarness.json(harness.refresh(client, refresh))
            let secrets = try [code, access, refresh, #require(rotated["access_token"] as? String),
                               #require(rotated["refresh_token"] as? String), request.verifier]
            var bytes = Data()
            for suffix in ["", "-wal", "-shm"] {
                bytes += (try? Data(contentsOf: URL(fileURLWithPath: harness.config.tokensURL.path + suffix))) ?? Data()
            }
            let haystack = String(decoding: bytes, as: UTF8.self)
            for secret in secrets {
                #expect(!haystack.contains(secret))
            }
            #expect(haystack.contains(OAuthCrypto.storageHash(access)))
        }
    }

    // MARK: client-secret hook (test 11)

    @Test func optionalClientSecretHook() async throws {
        let secret = "s3cret-value-for-the-hook"
        let digest = OAuthCrypto.storageHash(secret)
        try await OAuthHarness.run(env: ["NR_OAUTH_CLIENT_SECRET_SHA256": digest.uppercased()]) { harness, client in
            let metadata = try await OAuthHarness.json(client.execute(
                uri: "/.well-known/oauth-authorization-server", method: .get
            ))
            #expect(metadata["token_endpoint_auth_methods_supported"] as? [String]
                == ["client_secret_post", "client_secret_basic"])

            var request = Request()
            var code = try await harness.code(client, request)
            let without = try await harness.exchange(client, code: code, verifier: request.verifier)
            #expect(without.status == .unauthorized)
            #expect(try error(without) == "invalid_client")
            let wrong = try await harness.exchange(
                client, code: code, verifier: request.verifier, extra: [("client_secret", secret + "x")]
            )
            #expect(try error(wrong) == "invalid_client")
            let post = try await harness.exchange(
                client, code: code, verifier: request.verifier, extra: [("client_secret", secret)]
            )
            #expect(post.status == .ok)

            request = Request()
            code = try await harness.code(client, request)
            let basic = "Basic " + Data("\(OAuthHarness.clientID):\(secret)".utf8).base64EncodedString()
            let viaBasic = try await harness.post(client, "/token", [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", OAuthHarness.claudeRedirect),
                ("code_verifier", request.verifier),
            ], headers: [.authorization: basic])
            #expect(viaBasic.status == .ok)
            // Revocation also needs the secret now.
            let refresh = try #require(try OAuthHarness.json(viaBasic)["refresh_token"] as? String)
            #expect(try await harness.post(client, "/revoke", [("token", refresh)]).status == .unauthorized)
            #expect(try await harness.post(client, "/revoke", [
                ("token", refresh), ("client_id", OAuthHarness.clientID), ("client_secret", secret),
            ]).status == .ok)
        }
    }
}
