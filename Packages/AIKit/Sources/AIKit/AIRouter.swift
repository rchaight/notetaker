import Foundation

/// Picks the best available provider per request. Private by default:
/// on-device first, homelab Ollama for what exceeds it, deterministic
/// None so every feature works with no AI at all.
public struct AIRouter: Sendable {
    let providers: [any AIProvider]

    /// Providers in preference order.
    public init(providers: [any AIProvider]) {
        self.providers = providers
    }

    public func activeProvider() async -> any AIProvider {
        for provider in providers where await provider.isAvailable() {
            return provider
        }
        return NoneProvider()
    }

    public func summarize(_ text: String) async throws -> (String, provider: String) {
        let provider = await activeProvider()
        return try await (provider.summarize(text), provider.name)
    }

    public func extractActionItems(from text: String) async throws -> ([AITask], provider: String) {
        let provider = await activeProvider()
        return try await (provider.extractActionItems(from: text), provider.name)
    }
}
