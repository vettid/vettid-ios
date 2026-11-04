import Foundation
import Testing
import VettIDDataTesting
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

    /// "Try again" joined to a read already under way stays busy until that read ends.
    @Test func tryAgainStaysBusyWhileAReadAlreadyRuns() async {
        let reads = SingleFlight()
        let gate = TestDeferred<Void>()
        let reread: @MainActor () async -> Void = { await reads.run { try? await gate.value() } }
        let foreground = Task { await reread() }
        await Task.yield()
        let vm = StartingViewModel(stuckAfter: .zero, sleep: { _ in }, reread: reread)
        await vm.watch()
        vm.retry()
        await Task.yield()
        await Task.yield()
        #expect(vm.retrying)
        gate.complete(())
        await foreground.value
        await vm.settle()
        #expect(!vm.retrying)
    }

    @MainActor final class Counter { var count = 0 }
}
