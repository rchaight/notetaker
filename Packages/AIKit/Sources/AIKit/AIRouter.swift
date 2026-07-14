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

    public func activeProvider(inputTokens: Int = 0) async -> any AIProvider {
        for provider in providers {
            if let limit = provider.contextLimit, inputTokens > limit {
                continue // input exceeds this provider's window
            }
            if await provider.isAvailable() {
                return provider
            }
        }
        return NoneProvider()
    }

    public func summarize(_ text: String) async throws -> (String, provider: String) {
        let provider = await activeProvider(inputTokens: NoneProvider.estimatedTokens(text))
        return try await (provider.summarize(text), provider.name)
    }

    public func extractActionItems(from text: String) async throws -> ([AITask], provider: String) {
        let provider = await activeProvider(inputTokens: NoneProvider.estimatedTokens(text))
        return try await (provider.extractActionItems(from: text), provider.name)
    }

    public func parseTask(_ input: String) async throws -> AITask {
        let provider = await activeProvider(inputTokens: NoneProvider.estimatedTokens(input))
        return try await provider.parseTask(input)
    }
}
