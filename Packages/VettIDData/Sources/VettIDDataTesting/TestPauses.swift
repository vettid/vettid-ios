#if DEBUG
import Foundation

/// TEST ONLY. Pauses a test releases: each ``sleep(_:)`` records its length and waits for ``release()`` (or its task's
/// cancellation).
public final class TestPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [TimeInterval] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    private var hold = true

    /// The lengths asked for, in order.
    public var lengths: [TimeInterval] { lock.withLock { asked } }

    /// False: a pause lasts five seconds (``shortMs``, when set) instead of waiting for ``release()`` (its length is
    /// recorded all the same).
    public var holding: Bool {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }

    /// The length of a pause that is not held, in ms (nil: five seconds).
    public var shortMs: UInt64? {
        get { lock.withLock { short } }
        set { lock.withLock { short = newValue } }
    }

    private var short: UInt64?
    private var fail = false

    /// True: every pause fails at once (recorded all the same), as a wait that fails before its end.
    public var failing: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }

    /// What a failing pause throws.
    public struct Failed: Error {}

    func sleep(_ s: TimeInterval) async throws {
        if failing {
            lock.withLock { asked.append(s) }
            throw Failed()
        }
        if !holding {
            lock.withLock { asked.append(s) }
            try await Task.sleep(nanoseconds: (shortMs ?? 5_000) * 1_000_000)
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let cancelled: Bool = lock.withLock {
                    asked.append(s)
                    if Task.isCancelled { return true }
                    waiting[id] = c
                    return false
                }
                if cancelled { c.resume() }
            }
        } onCancel: {
            lock.withLock { waiting.removeValue(forKey: id) }?.resume()
        }
        try Task.checkCancellation()
    }

    /// Ends the pauses waiting now.
    public func release() {
        let ws: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for w in ws { w.resume() }
    }
}
#endif
