import Foundation
import Testing
@testable import VettIDData

/// The re-reads of a vault being deleted (IOS-PLAN §4.2 points 3 and 4) on a virtual clock: after 5, 10 and 30 s, then
/// every 60 s, the last wait cut to the bound; "still finishing" at the bound; `gone` once; reads never overlap.
@MainActor
@Suite struct DeletionWatchTests {
    /// A virtual clock that each sleep moves on, and the reads' scripted answers.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        private var waited: [TimeInterval] = []
        var answers: [DeletionRead] = []
        var reads = 0
        var gone = 0
        var slow = 0

        var now: Date { lock.withLock { t } }
        var waits: [TimeInterval] { lock.withLock { waited } }

        func sleep(_ d: Duration) {
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            lock.withLock {
                waited.append(s)
                t = t.addingTimeInterval(s)
            }
        }
    }

    func watch(_ s: Script) -> DeletionWatch {
        DeletionWatch(
            now: { s.now }, sleep: { d in s.sleep(d) },
            read: {
                s.reads += 1
                return s.answers.isEmpty ? .listed : s.answers.removeFirst()
            },
            onGone: { s.gone += 1 }, onSlow: { s.slow += 1 }
        )
    }

    /// Still listed for the whole bound (10 minutes): 5, 10, 30, then 60 s waits, the last one cut to land on the bound;
    /// a read after each; then "still finishing", and no timer after it.
    @Test func theScheduleUpToTheBound() async {
        let s = Script()
        let w = watch(s)
        w.start(until: s.now.addingTimeInterval(600), readFirst: false)
        await w.settle()
        #expect(s.waits == [5, 10, 30, 60, 60, 60, 60, 60, 60, 60, 60, 60, 15])
        #expect(s.reads == 13 && s.slow == 1 && s.gone == 0)
    }

    /// A later bound (a `vault.delete`'s `exp` plus 2 minutes) keeps the schedule going until it.
    @Test func aLaterBound() async {
        let s = Script()
        let w = watch(s)
        w.start(until: s.now.addingTimeInterval(700), readFirst: false)
        await w.settle()
        #expect(s.waits.reduce(0, +) == 700 && s.slow == 1)
    }

    /// Listed (unlocked), unreachable, listed (locked), then gone: `gone` once, and nothing after it.
    @Test func goneEndsTheSchedule() async {
        let s = Script()
        s.answers = [.listed, .unreachable, .listed, .gone]
        let w = watch(s)
        w.start(until: s.now.addingTimeInterval(600), readFirst: false)
        await w.settle()
        #expect(s.waits == [5, 10, 30, 60] && s.reads == 4 && s.gone == 1 && s.slow == 0)
        #expect(await w.readOnce() == .listed && s.gone == 1, "said once")
    }

    /// A start reads at once; past the bound, it reads once and is "still finishing" without a new timer.
    @Test func aStartPastTheBound() async {
        let s = Script()
        let w = watch(s)
        w.start(until: s.now.addingTimeInterval(-1), readFirst: true)
        await w.settle()
        #expect(s.reads == 1 && s.waits.isEmpty && s.slow == 1)
    }

    /// Check again twice at once: one read, the second tap waits for the first.
    @Test func readsNeverOverlap() async {
        let s = Script()
        var release: CheckedContinuation<Void, Never>?
        let w = DeletionWatch(
            now: { s.now }, sleep: { _ in },
            read: {
                s.reads += 1
                await withCheckedContinuation { release = $0 }
                return .listed
            },
            onGone: {}, onSlow: {}
        )
        async let a = w.readOnce()
        async let b = w.readOnce()
        for _ in 0..<50 where release == nil { await Task.yield() }
        release?.resume()
        let ra = await a
        let rb = await b
        #expect(ra == .listed && rb == .listed)
        #expect(s.reads == 1)
    }
}
