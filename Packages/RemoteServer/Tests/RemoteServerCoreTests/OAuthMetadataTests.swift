import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 test 1.
struct OAuthMetadataTests {
    @Test func bothDiscoveryPathsServeTheSameDocument() async throws {
        try await OAuthHarness.run { _, client in
            var bodies: [String] = []
            for path in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "max-age=3600")
                    #expect(response.headers[.contentType] == "application/json")
                    bodies.append(String(buffer: response.body))
                    let document = try OAuthHarness.json(response)
                    #expect(document["issuer"] as? String == "https://nr-test.ts.net")
                    #expect(document["authorization_endpoint"] as? String == "https://nr-test.ts.net/authorize")
                    #expect(document["token_endpoint"] as? String == "https://nr-test.ts.net/token")
                    #expect(document["revocation_endpoint"] as? String == "https://nr-test.ts.net/revoke")
                    #expect(document["response_types_supported"] as? [String] == ["code"])
                    #expect(document["grant_types_supported"] as? [String] == ["authorization_code", "refresh_token"])
                    #expect(document["code_challenge_methods_supported"] as? [String] == ["S256"])
                    #expect(document["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
                    #expect(document["revocation_endpoint_auth_methods_supported"] as? [String] == ["none"])
                    #expect(document["scopes_supported"] as? [String] == ["vault:read"])
                    #expect(document["authorization_response_iss_parameter_supported"] as? Bool == true)
                    #expect(document["registration_endpoint"] == nil)
                    #expect(document["client_id_metadata_document_supported"] == nil)
                    #expect(document["jwks_uri"] == nil)
                    #expect(document.count == 11)
                }
            }
            #expect(bodies.count == 2 && bodies[0] == bodies[1])
        }
    }

    @Test func protectedResourceMetadataNamesThisIssuer() async throws {
        try await OAuthHarness.run { _, client in
            try await client.execute(uri: "/.well-known/oauth-protected-resource/mcp", method: .get) { response in
                let document = try OAuthHarness.json(response)
                #expect(document["authorization_servers"] as? [String] == ["https://nr-test.ts.net"])
                #expect(document["resource"] as? String == OAuthHarness.resource)
            }
        }
    }

    @Test func thereIsNoRegistrationEndpoint() async throws {
        try await OAuthHarness.run { harness, client in
            for method in [HTTPRequest.Method.get, .post] {
                try await client.execute(uri: "/register", method: method) { response in
                    #expect(response.status == .notFound)
                }
            }
            _ = harness
        }
    }
}
