import Foundation

/// TEST ONLY. Virtual time for a view model's countdowns and timeouts (kotlinx-coroutines-test's scheduler): every wait of
/// the code under test goes through ``sleep``, and only ``advance(seconds:)`` moves time, waking the sleepers in order and
/// letting what each one starts run. ``now`` follows the same time.
@MainActor
public final class VirtualTime {
    private struct Sleeper {
        let id: Int
        let at: Int64
        let c: CheckedContinuation<Void, any Error>
    }

    private final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: Int64 = 0

        var value: Int64 {
            get { lock.withLock { ms } }
            set { lock.withLock { ms = newValue } }
        }
    }

    private let time = Time()
    private let t0: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    public init(t0: Date = Date(timeIntervalSince1970: 1_791_000_000)) {
        self.t0 = t0
    }

    /// Milliseconds since the clock began.
    public var nowMs: Int64 { time.value }

    /// The date at the virtual time (what a view model's `now` returns).
    public var now: @Sendable () -> Date {
        { [time, t0] in t0.addingTimeInterval(Double(time.value) / 1000) }
    }

    /// The wait a view model sleeps with.
    public var sleep: @Sendable (Duration) async throws -> Void {
        { [weak self] d in
            guard let self else { return }
            try await self.wait(d)
        }
    }

    /// A second's tick, for the view models that count down with ``sleep``.
    public var tick: @Sendable () async throws -> Void {
        { [weak self] in
            guard let self else { return }
            try await self.wait(.seconds(1))
        }
    }

    private func wait(_ d: Duration) async throws {
        let parts = d.components
        let ms = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
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
                    sleepers.append(Sleeper(id: id, at: time.value + ms, c: c))
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
    public func runCurrent() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Moves time on by [ms], waking each sleeper due by then in order and letting what it starts run.
    public func advance(ms: Int64) async {
        let target = time.value + ms
        await runCurrent()
        while let next = sleepers.filter({ $0.at <= target }).min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            sleepers.removeAll { $0.id == next.id }
            time.value = next.at
            next.c.resume()
            await runCurrent()
        }
        time.value = target
        await runCurrent()
    }

    public func advance(seconds: Int64) async { await advance(ms: seconds * 1000) }
}
