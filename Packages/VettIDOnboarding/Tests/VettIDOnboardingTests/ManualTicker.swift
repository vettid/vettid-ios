import Foundation
import Testing
@testable import VettIDOnboarding

/// The countdowns' seconds, moved on only by the test (kotlinx-coroutines-test's virtual time).
@MainActor
final class ManualTicker {
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    /// The seconds the countdowns have taken: a resumed wait counts once its countdown runs again (it takes the second in the
    /// same turn, with no suspension between).
    private(set) var taken = 0

    /// The most yields a resumed countdown is given to run again; one that does not is a test issue, not a second lost.
    static let maxYields = 100_000

    /// Isolated to the main actor, as the view model's countdowns are: a countdown's waiter is added before it suspends, with
    /// no hop off the main actor between, so a second the test gives right after is never one it was not yet waiting for.
    var tick: @Sendable () async throws -> Void {
        { @MainActor [weak self] in
            guard let self else { return }
            try await wait()
            taken += 1
        }
    }

    private func wait() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// [seconds] pass, one at a time, with what each one starts run.
    func advance(_ seconds: Int, _ vm: UnlockViewModel) async { await advance(seconds) { await vm.settle() } }

    func advance(_ seconds: Int, _ vm: OwnerCheckViewModel) async { await advance(seconds) { await vm.settle() } }

    /// Each second: what is running settles, every countdown waiting is given the second, and each of them has taken it
    /// (however busy the main actor is) before what it starts settles. Not a fixed number of yields: a starved main actor
    /// (a full parallel run) could leave a countdown behind it.
    func advance(_ seconds: Int, settle: () async -> Void) async {
        for _ in 0..<seconds {
            await settle()
            let w = waiters
            waiters = []
            let target = taken + w.count
            for c in w { c.resume() }
            var yields = 0
            while taken < target, yields < Self.maxYields {
                await Task.yield()
                yields += 1
            }
            if taken < target { Issue.record("a countdown did not take its second within \(Self.maxYields) yields") }
            await settle()
        }
    }
}

/// The ticker itself: a second is taken by a countdown that runs late, behind other work on the main actor.
@MainActor
@Suite struct ManualTickerTests {
    @Test func aSecondIsTakenEvenBehindABusyMainActor() async {
        let ticker = ManualTicker()
        let tick = ticker.tick
        var counted = 0
        let countdown = Task { @MainActor in
            while counted < 3 {
                try? await tick()
                counted += 1
            }
        }
        for _ in 0..<10 { await Task.yield() }
        // Work that keeps the main actor busy while the seconds are given.
        let busy = Task { @MainActor in for _ in 0..<5_000 { await Task.yield() } }
        for n in 1...3 {
            await ticker.advance(1) {}
            #expect(counted == n, "the second is taken before advance returns")
        }
        // Not awaited: with a second lost the countdown would wait for one forever (the expectations above say so instead).
        countdown.cancel()
        busy.cancel()
    }
}
