import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 tests 7 (bearer validation on /mcp) and 8 (revocation).
struct OAuthBearerTests {
    @Test func missingHeaderGetsTheExactChallenge() async throws {
        try await OAuthHarness.run { harness, client in
            let response = try await harness.mcpStatus(client, nil)
            #expect(response.status == .unauthorized)
            #expect(response.headers[.wwwAuthenticate]
                == "Bearer resource_metadata=\"https://nr-test.ts.net/.well-known/oauth-protected-resource/mcp\"")
        }
    }

    @Test func malformedHeadersAreInvalidToken() async throws {
        try await OAuthHarness.run { harness, client in
            let good = try await harness.tokens(client).access
            for header in [
                // (Trailing whitespace is optional whitespace in HTTP and is trimmed by the parser.)
                "Bearer garbage", "Bearer  \(good)", "Bearer \(good)x", "Basic \(good)", "\(good)",
                "Bearer\t\(good)", "Bearer \(good),Bearer \(good)", "Bearer " + String(good.dropLast()),
                "Bearer " + good.replacingOccurrences(of: String(good.first!), with: "+"),
            ] {
                var headers: HTTPFields = [.contentType: "application/json", .accept: "application/json"]
                headers[.authorization] = header
                let response = try await client.execute(
                    uri: "/mcp", method: .post, headers: headers, body: ByteBuffer(string: "{}")
                )
                #expect(response.status == .unauthorized, "\(header.count)")
                let challenge = response.headers[.wwwAuthenticate] ?? ""
                #expect(challenge.contains("error=\"invalid_token\""))
                #expect(!challenge.contains(good))
            }
            // The scheme is case-insensitive (RFC 7235).
            var headers: HTTPFields = [.contentType: "application/json", .accept: "application/json"]
            headers[.authorization] = "bearer \(good)"
            let lower = try await client.execute(
                uri: "/mcp", method: .post, headers: headers,
                body: ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")
            )
            #expect(lower.status == .ok)
        }
    }

    @Test func validTokenReadsTheVaultAndRecordsLastUse() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            harness.clock.advance(5)
            #expect(try await harness.mcpStatus(client, tokens.access).status == .ok)
            var headers: HTTPFields = [.contentType: "application/json", .accept: "application/json"]
            headers[.authorization] = "Bearer \(tokens.access)"
            let read = try await client.execute(
                uri: "/mcp", method: .post, headers: headers,
                body: ByteBuffer(
                    string: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"read_note\",\"arguments\":{\"path\":\"Inbox.md\"}}}"
                )
            )
            #expect(read.status == .ok)
            let result = try #require(try OAuthHarness.json(read)["result"] as? [String: Any])
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect((structured["content"] as? String)?.contains("accreditation") == true)
            let lastUsed = try await harness.store.withDatabase { db in
                try Double.fetchOne(
                    db, sql: "SELECT last_used_at FROM token WHERE hash = ?",
                    arguments: [OAuthCrypto.storageHash(tokens.access)]
                )
            }
            #expect(lastUsed == harness.clock.now.timeIntervalSince1970)
            // The refresh token is not a bearer credential.
            #expect(try await harness.mcpStatus(client, tokens.refresh).status == .unauthorized)
        }
    }

    @Test func expiredAccessTokenIs401() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            harness.clock.advance(14 * 60)
            #expect(try await harness.mcpStatus(client, tokens.access).status == .ok)
            harness.clock.advance(2 * 60)
            #expect(try await harness.mcpStatus(client, tokens.access).status == .unauthorized)
        }
    }

    @Test func plantedTokensWithWrongBindingsAre401() async throws {
        let store = try TokenStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let authenticator = TokenAuthenticator(
            store: store, audience: OAuthHarness.resource, clientID: OAuthHarness.clientID, now: { now }
        )
        func plant(aud: String, client: String, familyRevoked: Bool = false, tokenRevoked: Bool = false) async throws
            -> String {
            let token = OAuthCrypto.token()
            let family = OAuthCrypto.token(bytes: 16)
            try await store.withDatabase { db in
                try TokenStore.insertFamily(db, .init(
                    id: family, clientID: client, sub: "rchaight@gmail.com", aud: aud, createdAt: now,
                    absoluteExpiry: now.addingTimeInterval(86400), revokedAt: familyRevoked ? now : nil
                ))
                try TokenStore.insertTokens(db, .init(
                    familyID: family, accessHash: OAuthCrypto.storageHash(token),
                    refreshHash: OAuthCrypto.storageHash(OAuthCrypto.token()),
                    accessExpiry: now.addingTimeInterval(900), refreshExpiry: now.addingTimeInterval(86400)
                ), now: now)
                if tokenRevoked {
                    try db.execute(
                        sql: "UPDATE token SET revoked_at = ? WHERE hash = ?",
                        arguments: [now.timeIntervalSince1970, OAuthCrypto.storageHash(token)]
                    )
                }
            }
            return token
        }
        let valid = try await plant(aud: OAuthHarness.resource, client: OAuthHarness.clientID)
        #expect(await authenticator.authenticate(authorizationHeader: "Bearer \(valid)") != .missing)
        if case .authenticated = await authenticator.authenticate(authorizationHeader: "Bearer \(valid)") {} else {
            Issue.record("a correctly bound token must authenticate")
        }
        var wrong: [String] = []
        try await wrong.append(plant(aud: "https://evil.example/mcp", client: OAuthHarness.clientID))
        try await wrong.append(plant(aud: OAuthHarness.resource + "/", client: OAuthHarness.clientID))
        try await wrong.append(plant(aud: OAuthHarness.resource, client: "nr-other-client-0123456789"))
        try await wrong.append(plant(aud: OAuthHarness.resource, client: OAuthHarness.clientID, familyRevoked: true))
        try await wrong.append(plant(aud: OAuthHarness.resource, client: OAuthHarness.clientID, tokenRevoked: true))
        for token in wrong {
            #expect(await authenticator.authenticate(authorizationHeader: "Bearer \(token)")
                == .denied(description: "The access token is invalid or expired"))
        }
        #expect(await authenticator.authenticate(authorizationHeader: nil) == .missing)
        #expect(await authenticator.authenticate(authorizationHeader: "  ") == .missing)
    }

    // MARK: revocation (test 8)

    @Test func revokingTheRefreshTokenKillsTheFamily() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            let response = try await harness.post(client, "/revoke", [
                ("token", tokens.refresh), ("token_type_hint", "refresh_token"),
            ])
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(try await harness.mcpStatus(client, tokens.access).status == .unauthorized)
            #expect(try await OAuthHarness
                .json(harness.refresh(client, tokens.refresh))["error"] as? String == "invalid_grant")
            #expect(harness.events("revoke").last?["reason"] as? String == "refresh")
        }
    }

    @Test func revokingTheAccessTokenKillsOnlyIt() async throws {
        try await OAuthHarness.run { harness, client in
            let tokens = try await harness.tokens(client)
            // A wrong hint does not matter: both kinds are searched.
            #expect(try await harness.post(client, "/revoke", [
                ("token", tokens.access), ("token_type_hint", "refresh_token"), ("client_id", OAuthHarness.clientID),
            ]).status == .ok)
            #expect(try await harness.mcpStatus(client, tokens.access).status == .unauthorized)
            let rotated = try await harness.refresh(client, tokens.refresh)
            #expect(rotated.status == .ok)
            let access = try #require(try OAuthHarness.json(rotated)["access_token"] as? String)
            #expect(try await harness.mcpStatus(client, access).status == .ok)
        }
    }

    @Test func unknownTokensStillGet200AndBadRequestsDoNot() async throws {
        try await OAuthHarness.run { harness, client in
            for token in [OAuthCrypto.token(), "short", String(repeating: "x", count: 4000)] {
                #expect(try await harness.post(client, "/revoke", [("token", token)]).status == .ok)
            }
            #expect(try await harness.post(client, "/revoke", []).status == .badRequest)
            #expect(try await harness.post(client, "/revoke", [("token", "a"), ("token", "b")]).status == .badRequest)
            let foreign = try await harness.post(client, "/revoke", [
                ("token", OAuthCrypto.token()), ("client_id", "nr-other-client-0123456789"),
            ])
            #expect(foreign.status == .unauthorized)
            #expect(try OAuthHarness.json(foreign)["error"] as? String == "invalid_client")
            #expect(harness.events("revoke").filter { $0["reason"] as? String == "unknown" }.count == 3)
        }
    }
}
