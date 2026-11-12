import Foundation

/// Drives a fake's ``FakeVaultRepository/transferInRelayBusyUpdates()``: each stream gets the current value first, then every
/// ``send(_:)``.
public final class RelayBusyFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false
    private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init() {}

    public func send(_ v: Bool) {
        let cs: [AsyncStream<Bool>.Continuation] = lock.withLock {
            current = v
            return Array(subscribers.values)
        }
        for c in cs { c.yield(v) }
    }

    /// Streams that have not ended.
    public var subscriberCount: Int { lock.withLock { subscribers.count } }

    public func stream() -> AsyncStream<Bool> {
        AsyncStream { c in
            let id = UUID()
            lock.withLock {
                subscribers[id] = c
                c.yield(current)
            }
            c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) } }
        }
    }
}
