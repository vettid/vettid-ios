import Foundation

/// How the lock and its retries wait: real time in the app (`Task.sleep`), a virtual clock in the tests.
public typealias LockSleep = @Sendable (Duration) async throws -> Void

/// The real wait.
public let realLockSleep: LockSleep = { try await Task.sleep(for: $0) }

/// Mutual exclusion across suspension points, on the main actor, first come first served (Kotlin's `Mutex`). Holding
/// it across an `await` is the point: a lock attempt and an unlock never overlap.
@MainActor
final class AsyncGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the next waiter, or opens it.
    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A wait that ends after a time or at a kick, whichever comes first, or when the waiting task is cancelled. A kick
/// while nobody waits is kept for the next wait (Kotlin's conflated channel): the member's "Try again" is never lost.
@MainActor
final class KickableWait {
    private var kicked = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitID = 0
    private var timer: Task<Void, Never>?

    func kick() {
        if waiter != nil {
            finish(waitID)
        } else {
            kicked = true
        }
    }

    /// Forgets a kick nobody waited for.
    func reset() { kicked = false }

    func wait(_ d: Duration, sleep: @escaping LockSleep) async {
        if kicked {
            kicked = false
            return
        }
        if Task.isCancelled { return }
        waitID += 1
        let id = waitID
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter = c
                timer = Task { @MainActor [weak self] in
                    try? await sleep(d)
                    self?.finish(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id) }
        }
    }

    private func finish(_ id: Int) {
        guard id == waitID, let w = waiter else { return }
        waiter = nil
        timer?.cancel()
        timer = nil
        w.resume()
    }
}

extension Duration {
    /// Whole milliseconds (rounded down).
    var milliseconds: Int64 {
        let (s, atto) = components
        return s * 1000 + atto / 1_000_000_000_000_000
    }
}
