import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The root's stuck screens: "Try again" reads the phase again; a way out acts only when the member confirmed the one the
/// phase still offers, and a failure reads the phase again. Mirrors vettid-android `RootViewModel.retry` and `startOver`.
@MainActor
@Suite struct UnreachableViewModelTests {
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func tryAgainReadsThePhaseAgainOnce() async {
        let vault = FakeVaultRepository(.unreachable(.network))
        let vm = UnreachableViewModel(account: vault)
        vm.retry()
        vm.retry() // a double tap
        #expect(vm.retrying)
        await settle()
        #expect(vault.calls == ["refresh"] && !vm.retrying)
    }

    /// "Try again" reads through the app's one read at a time when it is given one (a foreground read may be under way): it
    /// does not read beside it, and stays busy until that read ends.
    @Test func tryAgainUsesTheAppsSingleRead() async {
        let vault = FakeVaultRepository(.unreachable(.phoneLocked))
        let reads = SingleFlight()
        let gate = TestDeferred<Void>()
        let started = Counter()
        let reread: @MainActor () async -> Void = {
            await reads.run {
                started.count += 1
                try? await gate.value()
            }
        }
        // A foreground read is under way.
        let foreground = Task { await reread() }
        await settle()
        #expect(reads.running && started.count == 1)
        let vm = UnreachableViewModel(account: vault, reread: reread)
        vm.retry()
        await settle()
        #expect(vm.retrying, "busy while the read it joined runs")
        #expect(started.count == 1 && !vault.calls.contains("refresh"), "no second read beside the first")
        gate.complete(())
        await foreground.value
        await settle()
        // The ask made during the read is answered by one more read after it.
        #expect(started.count == 2 && !reads.running && !vm.retrying)
        vm.retry()
        await settle()
        #expect(started.count == 3)
    }

    @Test func aSingleFlightRunsOneJobAtATime() async {
        let flight = SingleFlight()
        let gate = TestDeferred<Void>()
        let ran = Counter()
        let done = Counter()
        let first = Task { await flight.run { ran.count += 1; try? await gate.value() } }
        await settle()
        let second = Task {
            let result = await flight.run { Issue.record("an ask does not run beside the run under way") }
            done.count += 1
            return result
        }
        await settle()
        #expect(done.count == 0 && ran.count == 1, "the second ask waits for the run under way")
        gate.complete(())
        #expect(await first.value)
        #expect(await second.value == false && done.count == 1)
        #expect(ran.count == 2, "and the job ran once more for it")
        #expect(!flight.running)
    }

    /// Many asks during one run give one more run, not many; no ask gives none; the waiters return after the extra run.
    @Test func manyAsksDuringARunGiveOneExtraRun() async {
        let flight = SingleFlight()
        let gate = TestDeferred<Void>()
        let ran = Counter()
        let returned = Counter()
        let first = Task { await flight.run { ran.count += 1; try? await gate.value() } }
        await settle()
        let asks = (0..<5).map { _ in
            Task {
                await flight.run { Issue.record("ran beside") }
                returned.count += 1
            }
        }
        await settle()
        #expect(ran.count == 1 && returned.count == 0)
        gate.complete(())
        _ = await first.value
        for ask in asks { await ask.value }
        #expect(ran.count == 2 && returned.count == 5)
        // Nothing asked during a run: one run only.
        let quiet = Counter()
        await flight.run { quiet.count += 1 }
        #expect(quiet.count == 1 && !flight.running)
    }

    /// A cold start whose first read ends on a phase that needs no more reading (locked) is not read again for the asks made
    /// during it; a member's own "Try again" is always answered.
    @Test func theExtraReadIsMadeOnlyWhileItIsStillNeeded() async {
        let flight = SingleFlight()
        let gate = TestDeferred<Void>()
        let ran = Counter()
        let phaseIsLocked = Counter() // 1: the first read ended on .locked
        let first = Task {
            await flight.run(stillNeeded: { phaseIsLocked.count == 0 }) { ran.count += 1; try? await gate.value() }
        }
        await settle()
        let asked = Task { await flight.run { Issue.record("ran beside") } }
        await settle()
        phaseIsLocked.count = 1
        gate.complete(())
        _ = await first.value
        _ = await asked.value
        #expect(ran.count == 1 && !flight.running, "no second read of a phase that is already known")
        // A member's ask is answered whatever the phase became.
        let again = TestDeferred<Void>()
        let second = Task {
            await flight.run(stillNeeded: { false }) { ran.count += 1; try? await again.value() }
        }
        await settle()
        let forced = Task { await flight.run(forced: true) { Issue.record("ran beside") } }
        await settle()
        again.complete(())
        _ = await second.value
        _ = await forced.value
        #expect(ran.count == 3)
    }

    /// A cancelled caller leaves nothing set.
    @Test func aCancelledCallerLeavesTheFlightClear() async {
        let flight = SingleFlight()
        let gate = TestDeferred<Void>()
        let caller = Task { await flight.run { try? await gate.value() } }
        await settle()
        caller.cancel()
        gate.complete(())
        _ = await caller.value
        await settle()
        #expect(!flight.running)
    }

    @MainActor final class Counter { var count = 0 }

    /// A wipe that did not finish offers "Erase VettID's data on this phone": local only; when it cannot finish the member
    /// is told to remove the app.
    @Test func aFailedWipeOffersToEraseTheData() async {
        #expect(WayOut.of(.eraseFailed) == .clearData)
        let vault = FakeVaultRepository(.unreachable(.eraseFailed))
        vault.clearAppDataResult = false
        let vm = UnreachableViewModel(account: vault)
        vm.startOver(.clearData)
        await settle()
        #expect(vault.calls == ["clearAppData"] && vm.clearDataFailed)
        vault.clearAppDataResult = true
        vm.startOver(.clearData)
        await settle()
        #expect(vault.phase == .signedOut)
    }

    @Test func aWayOutActsOnlyWhileThePhaseOffersIt() async {
        let vault = FakeVaultRepository(.unreachable(.noVault))
        let vm = UnreachableViewModel(account: vault)
        vm.startOver(.erase) // not the way this phase offers
        await settle()
        #expect(vault.calls.isEmpty)
        vm.startOver(.startOver)
        await settle()
        #expect(vault.calls == ["forgetMissingVault"] && vault.phase == .signedOut)

        let gone = FakeVaultRepository(.unreachable(.network, longUnreachable: true))
        let long = UnreachableViewModel(account: gone)
        long.startOver(.eraseOrRecover)
        await settle()
        #expect(gone.calls == ["eraseThisPhone"])
    }

    @Test func aFailedWayOutReadsThePhaseAgain() async {
        let vault = FakeVaultRepository(.unreachable(.localState))
        vault.fail["eraseThisPhone"] = FakeVaultRepository.failure(.notSupported)
        let vm = UnreachableViewModel(account: vault)
        vm.startOver(.erase)
        await settle()
        #expect(vault.calls == ["eraseThisPhone", "refresh"] && !vm.retrying)
    }
}
