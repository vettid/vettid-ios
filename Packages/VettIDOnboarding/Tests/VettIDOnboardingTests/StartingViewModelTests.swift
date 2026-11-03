import Foundation
import Testing
@testable import VettIDOnboarding

/// "Opening VettID" that stays: after the bound, in the foreground, "Try again" is offered, once at a time.
@MainActor
@Suite struct StartingViewModelTests {
    /// A sleep the test ends by hand.
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var opened = false
        /// Returns at once when opened already (an `open()` before the `wait()` is remembered).
        func wait() async throws {
            if opened { return }
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @Test func itIsStuckOnlyAfterTheBound() async {
        let gate = Gate()
        let vm = StartingViewModel(stuckAfter: .seconds(20), sleep: { _ in try await gate.wait() }, reread: {})
        let watching = Task { await vm.watch() }
        await Task.yield()
        #expect(!vm.stuck)
        await gate.open()
        await watching.value
        #expect(vm.stuck)
    }

    /// The app leaving the foreground cancels the wait: the time in the background does not count.
    @Test func aCancelledWaitIsNotStuck() async {
        let vm = StartingViewModel(stuckAfter: .seconds(20), sleep: { try await Task.sleep(for: $0) }, reread: {})
        let watching = Task { await vm.watch() }
        await Task.yield()
        watching.cancel()
        await watching.value
        #expect(!vm.stuck)
    }

    @Test func tryAgainIsOneReadAtATime() async {
        let gate = Gate()
        let reads = Counter()
        let vm = StartingViewModel(stuckAfter: .zero, sleep: { _ in }, reread: {
            reads.count += 1
            try? await gate.wait()
        })
        await vm.watch()
        #expect(vm.stuck)
        vm.retry()
        vm.retry()
        await Task.yield()
        #expect(vm.retrying && reads.count == 1)
        await gate.open()
        await vm.settle()
        #expect(!vm.retrying)
        vm.retry()
        await Task.yield()
        #expect(reads.count == 2)
        await gate.open()
        await vm.settle()
    }

    @MainActor final class Counter { var count = 0 }
}
