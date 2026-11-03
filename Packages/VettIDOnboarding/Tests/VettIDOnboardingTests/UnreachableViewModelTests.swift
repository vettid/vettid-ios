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

    /// "Try again" reads through the app's one read at a time when it is given one (a foreground read may be under way), and
    /// never beside it: while one read runs another ask does nothing.
    @Test func tryAgainUsesTheAppsSingleRead() async {
        let vault = FakeVaultRepository(.unreachable(.phoneLocked))
        let reads = SingleFlight()
        let gate = TestDeferred<Void>()
        var started = 0
        let reread: @MainActor () async -> Void = {
            await reads.run {
                started += 1
                try? await gate.value()
            }
        }
        // A foreground read is under way.
        let foreground = Task { await reread() }
        await settle()
        #expect(reads.running && started == 1)
        let vm = UnreachableViewModel(account: vault, reread: reread)
        vm.retry()
        await settle()
        #expect(started == 1 && !vault.calls.contains("refresh"), "no second read beside the first")
        gate.complete(())
        await foreground.value
        await settle()
        #expect(!reads.running && !vm.retrying)
        vm.retry()
        await settle()
        #expect(started == 2)
    }

    @Test func aSingleFlightRunsOneJobAtATime() async {
        let flight = SingleFlight()
        let gate = TestDeferred<Void>()
        let first = Task { await flight.run { try? await gate.value() } }
        await settle()
        let second = await flight.run { Issue.record("ran beside the first") }
        #expect(!second)
        gate.complete(())
        #expect(await first.value)
        #expect(await flight.run {})
    }

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
