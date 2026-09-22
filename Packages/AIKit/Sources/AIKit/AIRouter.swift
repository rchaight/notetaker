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
        try await firstSucceeding(inputTokens: NoneProvider.estimatedTokens(text)) { try await $0.summarize(text) }
    }

    public func extractActionItems(from text: String) async throws -> ([AITask], provider: String) {
        try await firstSucceeding(inputTokens: NoneProvider.estimatedTokens(text)) {
            try await $0.extractActionItems(from: text)
        }
    }

    public func parseTask(_ input: String) async throws -> AITask {
        try await firstSucceeding(inputTokens: NoneProvider.estimatedTokens(input)) { try await $0.parseTask(input) }.0
    }

    /// The first provider in preference order that is available AND
    /// succeeds. A provider that answers its availability probe but then
    /// fails the real request (a slow homelab model timing out, a bad
    /// response) hands off to the next one instead of surfacing the error
    /// while a working fallback sits idle. With no provider available at
    /// all, the deterministic None provider answers, as before; if every
    /// available provider failed, the last error is rethrown.
    private func firstSucceeding<T>(
        inputTokens: Int, _ operation: (any AIProvider) async throws -> T
    ) async throws -> (T, provider: String) {
        var lastError: Error?
        for provider in providers {
            if let limit = provider.contextLimit, inputTokens > limit {
                continue
            }
            guard await provider.isAvailable() else { continue }
            do {
                return try await (operation(provider), provider.name)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        let none = NoneProvider()
        return try await (operation(none), none.name)
    }
}
