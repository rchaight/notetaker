import Foundation
import MCP

/// RFC 9728 protected-resource metadata, encoded with the SDK's own type.
public enum ProtectedResourceMetadata {
    public static func document(for config: RemoteConfig) -> Data {
        let metadata = OAuthProtectedResourceServerMetadata(
            resource: config.resourceURL,
            authorizationServers: [URL(string: config.publicURL)].compactMap(\.self),
            scopesSupported: ["vault:read"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(metadata)) ?? Data("{}".utf8)
    }
}
