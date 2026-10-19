import Foundation

public final class AsyncLock: @unchecked Sendable {
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
    public var waiting: Int { lock.withLock { waiters.count } }

    public init() {}
    public func acquire() async {
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
    public func acquire(within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) async -> Bool {
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

    public func release() {
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


public final class AsyncLockDoCatch: @unchecked Sendable {
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
    public var waiting: Int { lock.withLock { waiters.count } }

    public init() {}
    public func acquire() async {
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
    public func acquire(within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) async -> Bool {
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
                    do { try await sleep(timeout) } catch {}
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

    public func release() {
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


public struct Api: Sendable {
    public let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = Api.sleep) { self.sleep = sleep }
    public static func sleep(_ seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1e9)) }
    public static let sleepLet: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1e9)) }
}
