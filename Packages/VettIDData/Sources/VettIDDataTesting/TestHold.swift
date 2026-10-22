import Foundation

/// TEST ONLY. Holds callers until a test releases them one by one, in any order, whatever happens to the waiting task: unlike
/// ``TestDeferred`` a cancelled waiter keeps waiting, as a request already on its way does.
@MainActor
public final class TestHold {
    private var waiters: [CheckedContinuation<Void, Never>?] = []

    public init() {}

    /// How many callers have waited here so far.
    public var count: Int { waiters.count }

    public func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Lets the [index]th caller (from 0, in the order they came) go on.
    public func release(_ index: Int) {
        guard waiters.indices.contains(index), let c = waiters[index] else { return }
        waiters[index] = nil
        c.resume()
    }

    public func releaseAll() {
        for i in waiters.indices { release(i) }
    }
}
