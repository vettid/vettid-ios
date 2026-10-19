import Foundation
import Testing
@testable import VettIDVault

/// ``AsyncLock``'s timed waits: a waiter that gives up leaves the queue and is never handed the lock; plain and timed
/// waiters keep their order; a release racing a give-up never loses the lock; a cancelled waiter gives up at once.
@Suite struct AsyncLockTests {
    /// A sleep that ends when the test says so.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var count = 0

        var asked: Int { lock.withLock { count } }

        func sleep(_: TimeInterval) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    count += 1
                    waiting.append(c)
                }
            }
        }

        func open() {
            let ws: [CheckedContinuation<Void, Never>] = lock.withLock {
                defer { waiting.removeAll() }
                return waiting
            }
            for w in ws { w.resume() }
        }
    }

    /// Records the order the lock was held in.
    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        var all: [String] { lock.withLock { names } }
        func add(_ n: String) { lock.withLock { names.append(n) } }
    }

    func until(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    @Test func aWaiterThatGivesUpLeavesTheQueue() async {
        let l = AsyncLock()
        let gate = Gate()
        await l.acquire()
        let waiter = Task { await l.acquire(within: 30, sleep: { await gate.sleep($0) }) }
        #expect(await until { gate.asked == 1 })
        gate.open()
        #expect(await waiter.value == false)
        l.release()
        // Free again: a new waiter gets it at once, without waiting.
        #expect(await l.acquire(within: 0, sleep: { _ in }) == true)
        l.release()
    }

    @Test func theLockIsNeverHandedToAWaiterThatGaveUp() async {
        let l = AsyncLock()
        let gate = Gate()
        let order = Order()
        await l.acquire()
        let gaveUp = Task { await l.acquire(within: 30, sleep: { await gate.sleep($0) }) }
        #expect(await until { gate.asked == 1 })
        let plain = Task {
            await l.acquire()
            order.add("plain")
            l.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        gate.open()
        #expect(await gaveUp.value == false)
        l.release()
        await plain.value
        #expect(order.all == ["plain"])
    }

    @Test func plainAndTimedWaitersKeepTheirOrder() async {
        let l = AsyncLock()
        let order = Order()
        await l.acquire()
        let a = Task {
            await l.acquire()
            order.add("a")
            l.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let b = Task {
            if await l.acquire(within: 30, sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
                order.add("b")
                l.release()
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let c = Task {
            await l.acquire()
            order.add("c")
            l.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        l.release()
        await a.value
        await b.value
        await c.value
        #expect(order.all == ["a", "b", "c"])
    }

    /// A release and a give-up at the same moment: the lock is held by exactly one side, and is free at the end.
    @Test func aReleaseRacingAGiveUpNeverLosesTheLock() async {
        for _ in 0..<300 {
            let l = AsyncLock()
            await l.acquire()
            let waiter = Task {
                let held = await l.acquire(within: 0, sleep: { _ in await Task.yield() })
                if held { l.release() }
                return held
            }
            await Task.yield()
            l.release()
            _ = await waiter.value
            #expect(await l.acquire(within: 0, sleep: { _ in }) == true, "free at the end")
            l.release()
        }
    }

    @Test func aCancelledWaiterGivesUpAtOnce() async {
        let l = AsyncLock()
        await l.acquire()
        let started = Date()
        let waiter = Task { await l.acquire(within: 60, sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(Date().timeIntervalSince(started) < 5)
        l.release()
        #expect(await l.acquire(within: 0, sleep: { _ in }) == true)
        l.release()
    }
}
