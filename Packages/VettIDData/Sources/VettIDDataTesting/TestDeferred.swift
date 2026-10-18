import Foundation

/// TEST ONLY. A value a test completes later, awaited by the fake's suspending calls (a transfer's approval, the old
/// phone's pending transfer). Completed once; later completions are ignored. Mirrors the use of kotlinx
/// `CompletableDeferred` in vettid-android `FakeVault`.
@MainActor
public final class TestDeferred<T: Sendable> {
    private var result: Result<T, any Error>?
    private var waiters: [UUID: CheckedContinuation<T, any Error>] = [:]

    public init() {}

    public var isCompleted: Bool { result != nil }

    public func complete(_ value: T) { finish(.success(value)) }

    public func fail(_ error: any Error) { finish(.failure(error)) }

    /// The value, once a test completes it. A cancelled task stops waiting with `CancellationError`, also one cancelled
    /// before it began to wait, as kotlinx `await()` does.
    public func value() async throws -> T {
        if let result { return try result.get() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters[id] = c
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finish(_ r: Result<T, any Error>) {
        guard result == nil else { return }
        result = r
        let w = waiters.values
        waiters = [:]
        for c in w { c.resume(with: r) }
    }
}

public extension TestDeferred where T == Void {
    func complete() { complete(()) }
}
