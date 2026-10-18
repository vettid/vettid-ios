import Foundation
@testable import VettIDData

/// A clock any thread can read: the virtual clock's time.
final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 0
    let t0: Date

    init(t0: Date) { self.t0 = t0 }

    var nowMs: Int64 {
        get { lock.withLock { ms } }
        set { lock.withLock { ms = newValue } }
    }

    var now: Date { t0.addingTimeInterval(Double(nowMs) / 1000) }
}

/// Virtual time for the lock's tests (kotlinx-coroutines-test's scheduler): every wait of the code under test goes
/// through ``sleep``, and only ``advance(by:)`` moves time, waking the sleepers in order.
@MainActor
final class VirtualClock {
    private struct Sleeper {
        let id: Int
        let at: Int64
        let c: CheckedContinuation<Void, any Error>
    }

    let time: TestTime
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    init(t0: Date = Date(timeIntervalSince1970: 1_791_000_000)) {
        time = TestTime(t0: t0)
    }

    var t0: Date { time.t0 }
    var nowMs: Int64 { time.nowMs }
    var now: @Sendable () -> Date { { [time] in time.now } }

    var sleep: LockSleep {
        { [weak self] d in
            guard let self else { return }
            try await self.wait(d)
        }
    }

    private func wait(_ d: Duration) async throws {
        let ms = d.milliseconds
        guard ms > 0 else {
            await Task.yield()
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, at: time.nowMs + ms, c: c))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).c.resume(throwing: CancellationError())
    }

    /// Runs what is ready now (kotlinx `runCurrent`).
    func runCurrent() async {
        for _ in 0..<300 { await Task.yield() }
    }

    /// Moves time on by [ms], waking each sleeper due by then in order and letting what it starts run.
    func advance(by ms: Int64) async {
        let target = time.nowMs + ms
        await runCurrent()
        while let next = sleepers.filter({ $0.at <= target }).min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            sleepers.removeAll { $0.id == next.id }
            time.nowMs = next.at
            next.c.resume()
            await runCurrent()
        }
        time.nowMs = target
        await runCurrent()
    }
}

/// The lock's record in memory: every write recorded.
@MainActor
final class MemoryLockStore: LockRecordStore {
    var record: LockRecord
    private(set) var writes: [LockRecord] = []

    init(_ record: LockRecord = LockRecord()) { self.record = record }

    func load() -> LockRecord { record }

    func save(_ record: LockRecord) throws {
        self.record = record
        writes.append(record)
    }
}

/// A store whose saves all fail (a full phone, a failed rename).
@MainActor
final class FailingLockStore: LockRecordStore {
    struct Full: Error {}

    func load() -> LockRecord { LockRecord() }
    func save(_ record: LockRecord) throws { throw Full() }
}

extension Date {
    var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}
