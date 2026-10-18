import Foundation

/// A lock for async code that holds across suspension points, as a coroutine `Mutex` does: the device keeps its state
/// consistent while it deposits (VAULT-MESSAGING §8.3: persist before the relay ack, and in order). FIFO, not reentrant.
final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let run: Bool = lock.withLock {
                if !locked {
                    locked = true
                    return true
                }
                waiters.append(c)
                return false
            }
            if run { c.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                locked = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// A one-shot value that one side completes and the other awaits with a timeout (a response to a request). Each wait
/// has its own continuation, resumed exactly once: by the completion, or by its own timeout.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var waiters: [UUID: CheckedContinuation<T?, Never>] = [:]

    /// Completes with [v]; later completions are ignored.
    func complete(_ v: T) {
        let ws: [CheckedContinuation<T?, Never>] = lock.withLock {
            guard value == nil else { return [] }
            value = v
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for w in ws { w.resume(returning: v) }
    }

    /// The value, or nil after [timeout] seconds.
    func wait(timeout: TimeInterval) async -> T? {
        let token = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let ready: T? = lock.withLock {
                if let v = value { return v }
                waiters[token] = c
                return nil
            }
            if let ready {
                c.resume(returning: ready)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1e9))
                let mine = self.lock.withLock { self.waiters.removeValue(forKey: token) }
                mine?.resume(returning: nil)
            }
        }
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
