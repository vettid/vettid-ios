import Foundation

/// A lock for async code that holds across suspension points, as a coroutine `Mutex` does: the device keeps its state
/// consistent while it deposits (VAULT-MESSAGING §8.3: persist before the relay ack, and in order). FIFO, not reentrant.
/// A waiter may give up after a time (``withLock(within:sleep:_:)``).
final class AsyncLock: @unchecked Sendable {
    private enum Waiter {
        case plain(CheckedContinuation<Void, Never>)
        case timed(UUID, CheckedContinuation<Bool, Never>)

        var id: UUID? {
            if case .timed(let id, _) = self { return id }
            return nil
        }
    }

    private let lock = NSLock()
    private var locked = false
    private var waiters: [Waiter] = []

    /// How many wait for the lock now (the tests' view of who is queued).
    var waiting: Int { lock.withLock { waiters.count } }

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let run: Bool = lock.withLock {
                if !locked {
                    locked = true
                    return true
                }
                waiters.append(.plain(c))
                return false
            }
            if run { c.resume() }
        }
    }

    /// Acquires the lock, or gives up once [sleep] of [timeout] returned first: true when the lock is held. A waiter that
    /// gives up leaves its place in the queue; the lock is never handed to it.
    /// A cancelled caller gives up at once.
    func acquire(within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) async -> Bool {
        let token = UUID()
        let timer = Timer()
        let held = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let run: Bool = lock.withLock {
                    if !locked {
                        locked = true
                        return true
                    }
                    waiters.append(.timed(token, c))
                    return false
                }
                if run {
                    c.resume(returning: true)
                    return
                }
                timer.set(Task {
                    try? await sleep(timeout)
                    self.giveUp(token)
                })
                // Cancelled before the waiter was queued: the handler found nothing to remove.
                if Task.isCancelled { giveUp(token) }
            }
        } onCancel: {
            self.giveUp(token)
        }
        timer.cancel()
        return held
    }

    /// The waiter [token] gives up, unless the lock was handed to it already.
    private func giveUp(_ token: UUID) {
        let mine: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard let i = waiters.firstIndex(where: { $0.id == token }) else { return nil }
            guard case .timed(_, let c) = waiters.remove(at: i) else { return nil }
            return c
        }
        mine?.resume(returning: false)
    }

    func release() {
        let next: Waiter? = lock.withLock {
            if waiters.isEmpty {
                locked = false
                return nil
            }
            return waiters.removeFirst()
        }
        switch next {
        case .plain(let c)?: c.resume()
        case .timed(_, let c)?: c.resume(returning: true)
        case nil: break
        }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// [body] under the lock, or nil with nothing run when the lock was not free within [timeout] (measured by [sleep]).
    func withLock<T>(
        within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void, _ body: () async throws -> T
    ) async rethrows -> T? {
        guard await acquire(within: timeout, sleep: sleep) else { return nil }
        defer { release() }
        return try await body()
    }

    /// The give-up timer of one timed wait: cancelled once the wait ended (set and cancelled from different tasks).
    private final class Timer: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var done = false

        func set(_ t: Task<Void, Never>) {
            let cancelNow: Bool = lock.withLock {
                task = t
                return done
            }
            if cancelNow { t.cancel() }
        }

        func cancel() {
            let t: Task<Void, Never>? = lock.withLock {
                done = true
                return task
            }
            t?.cancel()
        }
    }
}

/// A one-shot value that one side completes and the other awaits with a timeout (a response to a request). Each wait
/// has its own continuation, resumed exactly once: by the completion, or by its own timeout.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var aborted = false
    private var waiters: [UUID: CheckedContinuation<T?, Never>] = [:]

    /// Completes with [v]; later completions are ignored.
    func complete(_ v: T) {
        let ws: [CheckedContinuation<T?, Never>] = lock.withLock {
            guard value == nil, !aborted else { return [] }
            value = v
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for w in ws { w.resume(returning: v) }
    }

    /// Ends every wait without a value, now and from then on (a completion that comes later is ignored), unless it was
    /// completed already.
    func abort() {
        let ws: [CheckedContinuation<T?, Never>] = lock.withLock {
            guard value == nil else { return [] }
            aborted = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for w in ws { w.resume(returning: nil) }
    }

    /// The value, or nil after [timeout] seconds, at once when the waiting task is cancelled, or once aborted.
    func wait(timeout: TimeInterval) async -> T? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
                let (ready, ended): (T?, Bool) = lock.withLock {
                    if let v = value { return (v, false) }
                    if aborted { return (nil, true) }
                    waiters[token] = c
                    return (nil, false)
                }
                if ready != nil || ended {
                    c.resume(returning: ready)
                    return
                }
                if Task.isCancelled { giveUp(token) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1e9))
                    self.giveUp(token)
                }
            }
        } onCancel: {
            self.giveUp(token)
        }
    }

    /// The wait [token] ends without a value, unless it ended already.
    private func giveUp(_ token: UUID) {
        let mine = lock.withLock { waiters.removeValue(forKey: token) }
        mine?.resume(returning: nil)
    }
}

/// A broadcast of values to any number of `AsyncStream` subscribers (Android's `SharedFlow` with a dropping buffer).
final class Broadcast<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<T>.Continuation] = [:]
    private let buffer: Int

    init(buffer: Int = 256) { self.buffer = buffer }

    func stream() -> AsyncStream<T> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(buffer)) { c in
            lock.withLock { subscribers[id] = c }
            c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) } }
        }
    }

    func emit(_ v: T) {
        let cs = lock.withLock { Array(subscribers.values) }
        for c in cs { c.yield(v) }
    }
}
