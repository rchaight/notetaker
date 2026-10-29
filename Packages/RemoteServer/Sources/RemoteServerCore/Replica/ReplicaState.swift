import Foundation
import MCPKit

public enum ReplicaState: Sendable, Equatable {
    case empty
    case disabled
    case inconsistent(since: Date)
    case ready(generatedAt: Date, manifest: ReplicaManifest)

    /// The word `status` prints.
    public var label: String {
        switch self {
        case .empty: "empty"
        case .disabled: "disabled"
        case .inconsistent: "inconsistent"
        case .ready: "ready"
        }
    }
}

/// What every tool call reads: the current state plus, if one is live, the
/// service answering from the last consistent replica and when THAT was generated.
/// (An `.inconsistent` state can still carry the previous service.)
public struct ReplicaSnapshot: Sendable {
    public let state: ReplicaState
    public let service: VaultService?
    public let servedGeneratedAt: Date?

    public init(state: ReplicaState, service: VaultService?, servedGeneratedAt: Date?) {
        self.state = state
        self.service = service
        self.servedGeneratedAt = servedGeneratedAt
    }
}

public protocol ReplicaProviding: Sendable {
    func current() async -> ReplicaSnapshot
}
