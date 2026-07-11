import Foundation

/// Trailing-edge debouncer: collects submitted values and yields them as one
/// batch once `quiet` elapses with no new submissions. Used to coalesce
/// bursts of file-change notifications before expensive reindexing.
public actor Debouncer<Value: Sendable> {
    public nonisolated let batches: AsyncStream<[Value]>

    private let quiet: Duration
    private let continuation: AsyncStream<[Value]>.Continuation
    private var pending: [Value] = []
    private var flushTask: Task<Void, Never>?

    public init(quiet: Duration) {
        self.quiet = quiet
        (batches, continuation) = AsyncStream.makeStream()
    }

    public func submit(_ value: Value) {
        pending.append(value)
        flushTask?.cancel()
        flushTask = Task { [quiet] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    public func finish() {
        flushTask?.cancel()
        pending.removeAll()
        continuation.finish()
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        continuation.yield(pending)
        pending.removeAll()
    }
}
