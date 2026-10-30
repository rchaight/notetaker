import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 test 2 plus redirect-URI / parameter adversarial cases.
struct OAuthAuthorizeTests {
    typealias Request = OAuthHarness.ClientRequest

    /// A 400 page that never redirects and never reflects the attacker's URI.
    private func expectRefusedPage(_ response: TestResponse, notContaining needle: String? = nil) {
        #expect(response.status == .badRequest)
        #expect(response.headers[.location] == nil)
        #expect(response.headers[.contentType] == "text/html; charset=utf-8")
        #expect(response.headers[.cacheControl] == "no-store")
        if let needle {
            #expect(!String(buffer: response.body).contains(needle))
        }
    }

    @Test func wrongOrMissingClientIDIsA400PageWithoutRedirect() async throws {
        try await OAuthHarness.run { harness, client in
            for clientID in [
                "nr-someone-else-0123456789",
                OAuthHarness.clientID.uppercased(),
                OAuthHarness.clientID + "x",
                "",
            ] {
                var request = Request()
                request.clientID = clientID
                try await expectRefusedPage(harness.authorize(client, request))
            }
            // Duplicated client_id (one valid) is refused too.
            var request = Request()
            request.extra = [("client_id", "nr-other-client-00000000")]
            try await expectRefusedPage(harness.authorize(client, request))
            #expect(harness.events("authorize.rejected").count == 5)
            #expect(harness.events("authorize.rejected").allSatisfy { $0["reason"] as? String == "unknown_client" })
        }
    }

    @Test func redirectURIMustMatchExactly() async throws {
        let variants = [
            "https://claude.ai/api/mcp/auth_callback/", // trailing slash
            "https://evil.example/api/mcp/auth_callback", // other host
            "http://127.0.0.1:1/cb", // loopback while off
            "http://claude.ai/api/mcp/auth_callback", // downgrade
            "HTTPS://claude.ai/api/mcp/auth_callback", // case
            "https://CLAUDE.ai/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/auth_callback?next=https://evil.example",
            "https://claude.ai/api/mcp/auth_callback#frag",
            "https://claude.ai.evil.example/api/mcp/auth_callback",
            "https://evil.example@claude.ai/api/mcp/auth_callback",
            "https://claude.ai:443/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/auth%5Fcallback",
            "https://claude.ai/api/mcp/../mcp/auth_callback",
            " https://claude.ai/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/auth_callback\u{0}",
            "https://сlaude.ai/api/mcp/auth_callback", // Cyrillic с
            "//evil.example/cb",
            "javascript:alert(1)",
        ]
        try await OAuthHarness.run { harness, client in
            for uri in variants {
                var request = Request()
                request.redirectURI = uri
                let response = try await harness.authorize(client, request)
                #expect(response.status == .badRequest, "\(uri)")
                #expect(response.headers[.location] == nil, "\(uri)")
                #expect(!String(buffer: response.body).contains("evil"), "\(uri)")
            }
            // Missing, and duplicated (valid + evil) redirect_uri.
            var missing = Request()
            missing.redirectURI = ""
            try await expectRefusedPage(harness.authorize(client, missing))
            var duplicated = Request()
            duplicated.extra = [("redirect_uri", "https://evil.example/cb")]
            try await expectRefusedPage(harness.authorize(client, duplicated), notContaining: "evil")
            #expect(harness.google.counters.authorize.isEmpty)
        }
    }

    @Test func loopbackRedirectsOnlyWhenEnabledAndOnlyRealLoopback() async throws {
        let accepted = ["http://127.0.0.1:8765/cb", "http://localhost:6274/oauth/callback", "http://127.0.0.1/cb"]
        let refused = [
            "http://127.0.0.1.evil.example/cb", "http://127.0.0.1:80@evil.example/cb", "http://localhost@evil.example/",
            "http://localhost:99999/cb", "http://localhost:0/cb", "https://127.0.0.1:8765/cb",
            "http://127.0.0.1:8765/cb?x=1",
            "http://127.0.0.1:8765/cb#x", "http://[::1]:8765/cb", "http://127.0.0.1:8765\\@evil.example/",
            "http://127.0.0.2:8765/cb", "http://LOCALHOST:8765/cb", "http://127.0.0.1:8765/c b",
        ]
        try await OAuthHarness.run(env: ["NR_ALLOW_LOOPBACK": "1"]) { harness, client in
            for uri in accepted {
                var request = Request()
                request.redirectURI = uri
                let response = try await harness.authorize(client, request)
                #expect(response.status == .found, "\(uri)")
                #expect(response.headers[.location]?.hasPrefix(harness.google.issuer + "/o/oauth2/v2/auth?") == true)
            }
            for uri in refused {
                var request = Request()
                request.redirectURI = uri
                let response = try await harness.authorize(client, request)
                #expect(response.status == .badRequest, "\(uri)")
                #expect(response.headers[.location] == nil, "\(uri)")
            }
            // The configured Claude URI still works with loopback on.
            #expect(try await harness.authorize(client, Request()).status == .found)
        }
        #expect(OAuthSettings.isLoopbackRedirect("http://127.0.0.1:8765/cb"))
        #expect(!OAuthSettings.isLoopbackRedirect("http://127.0.0.1:65536/cb"))
    }

    @Test func protocolErrorsRedirectToTheValidatedURIWithState() async throws {
        try await OAuthHarness.run { harness, client in
            func check(
                _ change: (inout Request) -> Void, error: String, echoesState: Bool = true,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws {
                var request = Request()
                change(&request)
                let response = try await harness.authorize(client, request)
                #expect(response.status == .found, sourceLocation: sourceLocation)
                let location = try #require(response.headers[.location], sourceLocation: sourceLocation)
                #expect(location.hasPrefix(OAuthHarness.claudeRedirect + "?"), sourceLocation: sourceLocation)
                let query = OAuthHarness.query(location)
                #expect(query["error"] == error, sourceLocation: sourceLocation)
                #expect(query["iss"] == OAuthHarness.publicURL, sourceLocation: sourceLocation)
                #expect(query["code"] == nil, sourceLocation: sourceLocation)
                #expect(query["state"] == (echoesState ? request.state : nil), sourceLocation: sourceLocation)
            }
            try await check({ $0.method = "plain" }, error: "invalid_request")
            try await check({ $0.method = nil }, error: "invalid_request") // downgrade by omission
            try await check({ $0.method = "s256" }, error: "invalid_request")
            try await check({ $0.challenge = "" }, error: "invalid_request")
            try await check({ $0.challenge = String(repeating: "a", count: 42) }, error: "invalid_request")
            try await check({ $0.challenge = String(repeating: "a", count: 129) }, error: "invalid_request")
            try await check({ $0.challenge = String(repeating: "a", count: 42) + "+" }, error: "invalid_request")
            try await check({ $0.state = "" }, error: "invalid_request", echoesState: false)
            try await check(
                { $0.state = String(repeating: "s", count: 513) },
                error: "invalid_request",
                echoesState: false
            )
            try await check({ $0.extra = [("response_type", "token")] }, error: "invalid_request") // duplicate
            try await check({ $0.scope = "vault:write" }, error: "invalid_scope")
            try await check({ $0.scope = "vault:read admin" }, error: "invalid_scope")
            try await check({ $0.resource = "https://evil/mcp" }, error: "invalid_target")
            try await check({ $0.resource = "https://nr-test.ts.net/mcp/" }, error: "invalid_target")
            try await check(
                { $0.extra = [("code_challenge", String(repeating: "b", count: 43))] },
                error: "invalid_request"
            )
            #expect(harness.google.counters.authorize.isEmpty)
            #expect(harness.events("authorize.rejected").count == 15)
        }
    }

    @Test func responseTypeOtherThanCodeIsUnsupported() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let query = request.query.replacingOccurrences(of: "response_type=code", with: "response_type=token")
            let response = try await client.execute(uri: "/authorize?" + query, method: .get)
            #expect(OAuthHarness.query(response.headers[.location] ?? "")["error"] == "unsupported_response_type")
            _ = harness
        }
    }

    @Test func missingResourceIsAcceptedAndAudited() async throws {
        try await OAuthHarness.run { harness, client in
            var request = Request()
            request.resource = nil
            request.scope = nil
            let response = try await harness.authorize(client, request)
            #expect(response.status == .found)
            #expect(harness.events("authorize.no_resource").count == 1)
            // The token is still bound to the one resource.
            let code = try await harness.code(client, request)
            let tokens = try await harness.exchange(client, code: code, verifier: request.verifier)
            #expect(tokens.status == .ok)
            let access = try #require(try OAuthHarness.json(tokens)["access_token"] as? String)
            #expect(try await harness.mcpStatus(client, access).status == .ok)
        }
    }

    @Test func validRequestRedirectsToGoogleWithOwnStateNoncePKCE() async throws {
        try await OAuthHarness.run { harness, client in
            let request = Request()
            let response = try await harness.authorize(client, request)
            #expect(response.status == .found)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
            let location = try #require(response.headers[.location])
            #expect(location.hasPrefix(harness.google.issuer + "/o/oauth2/v2/auth?"))
            let query = OAuthHarness.query(location)
            #expect(query["client_id"] == FakeGoogle.clientID)
            #expect(query["redirect_uri"] == "https://nr-test.ts.net/auth/google/callback")
            #expect(query["response_type"] == "code")
            #expect(query["scope"] == "openid email")
            #expect(query["code_challenge_method"] == "S256")
            #expect(query["prompt"] == "select_account")
            #expect(query["access_type"] == "online")
            #expect(query["nonce"]?.count == 43)
            #expect(query["state"]?.count == 43)
            #expect(query["code_challenge"]?.count == 43)
            // Our own values toward Google — never the client's.
            #expect(query["state"] != request.state)
            #expect(query["code_challenge"] != OAuthCrypto.pkceChallenge(for: request.verifier))
            #expect(!location.contains(request.state))
            // Two requests never share state or nonce.
            let second = try await OAuthHarness.query(#require(harness.authorize(client, request).headers[.location]))
            #expect(second["state"] != query["state"] && second["nonce"] != query["nonce"])
        }
    }

    @Test func unreachableIdentityProviderIsTemporarilyUnavailable() async throws {
        try await OAuthHarness.run(env: ["NR_GOOGLE_ISSUER": "http://127.0.0.1:1"]) { harness, client in
            let request = Request()
            let response = try await harness.authorize(client, request)
            let query = OAuthHarness.query(response.headers[.location] ?? "")
            #expect(query["error"] == "temporarily_unavailable")
            #expect(query["state"] == request.state)
        }
    }

    @Test func malformedQueriesAreRefusedWithoutRedirect() async throws {
        try await OAuthHarness.run { harness, client in
            let base = Request().query
            for query in [base + "&x=%zz", base + "&%ff=1", base + "&state=%C3%28"] {
                let response = try await client.execute(uri: "/authorize?" + query, method: .get)
                #expect(response.status == .badRequest || response.status == .found)
                if response.status == .found {
                    // Only possible for a duplicated `state`: an error, never a Google hop.
                    #expect(OAuthHarness.query(response.headers[.location] ?? "")["error"] != nil)
                }
            }
            let flood = (0 ..< 70).map { "p\($0)=1" }.joined(separator: "&")
            try await expectRefusedPage(client.execute(uri: "/authorize?" + base + "&" + flood, method: .get))
            #expect(harness.google.counters.authorize.isEmpty)
        }
    }
}
