import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The update screen and the update's own screens (owner decision 2026-10-09), and What's new on the unlock screen.
/// Mirrors vettid-android `ReleaseUpdateViewModelTest` and `UnlockViewModelTest.whatsNewIsLookedUpForTheOfferOnly`.
@MainActor
@Suite struct ReleaseUpdateViewModelTests {
    let vault = FakeVaultRepository(.unlocked)

    func rel(_ n: UInt64) -> ReleaseView { FakeVaultRepository.release(n) }

    var offer: ReleaseUpdateOffer { ReleaseUpdateOffer(current: rel(4), target: rel(5)) }

    let available = ReleaseNotes.available(
        host: "vettid.org",
        entry: ReleaseLogEntry(
            release: 5, summary: "Faster unlocks.", changes: ["Unlock takes one round trip."], security: .none, securityText: nil
        ),
        earlier: []
    )

    @Test func theUpdateStartsOnlyWithTheMembersApprovalAndPin() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await vm.settle()
        #expect(updates.refreshed == 1)
        #expect(updates.calls.isEmpty)
        #expect(!vm.state.submitAllowed(pinTyped: 0))
        #expect(!vm.approve(pin: ""))
        #expect(updates.calls.isEmpty)
        #expect(vm.state.submitAllowed(pinTyped: 6))
        #expect(vm.approve(pin: "246802"))
        #expect(updates.calls == ["start:246802:5"])
    }

    @Test func whatsNewLoadsForTheOfferAndNeverHoldsTheApprovalUp() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let notes = FakeReleaseNotes(available)
        let gate = TestDeferred<ReleaseNotes>()
        notes.gate = gate
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: notes)
        await vm.settle(refreshOnly: true)
        // Still loading: approving is possible all the same.
        #expect(vm.state.notes == nil)
        #expect(vm.state.submitAllowed(pinTyped: 6))
        gate.complete(available)
        await vm.settle()
        #expect(vm.state.notes == available)
        #expect(notes.asked == [5])
    }

    @Test func unavailableNotesStillAllowTheUpdate() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes(.unavailable))
        await vm.settle()
        #expect(vm.state.notes == .unavailable)
        vm.approve(pin: "246802")
        #expect(updates.calls == ["start:246802:5"])
    }

    @Test func aNewerOfferLoadsItsOwnNotes() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let notes = FakeReleaseNotes(available)
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: notes)
        await vm.settle()
        updates.offer = ReleaseUpdateOffer(current: rel(4), target: rel(5)) // the same release again: nothing new
        await vm.settle()
        notes.answer = .unavailable
        updates.offer = ReleaseUpdateOffer(current: rel(4), target: rel(6))
        await vm.settle()
        #expect(notes.asked == [5, 6])
        #expect(vm.state.notes == .unavailable)
    }

    @Test func theOwnerCheckComesFirst() async {
        let updates = FakeReleaseUpdates(offer: offer)
        vault.ownerCheck = OwnerCheckView(state: .held, deadline: Date().addingTimeInterval(-60))
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await vm.settle()
        #expect(vm.state.checkDue)
        vm.approve(pin: "246802")
        #expect(updates.calls.isEmpty)
    }

    /// (§11.14.9) A PIN or password change undecided: the PIN waits, with the gate's words, and nothing starts.
    @Test func anUndecidedChangeHoldsTheApproval() async {
        let updates = FakeReleaseUpdates(offer: offer)
        updates.changeHold = .changeChecking
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await vm.settle()
        #expect(vm.state.changeHold == .changeChecking && !vm.state.pinAllowed)
        #expect(!vm.approve(pin: "246802"))
        #expect(updates.calls.isEmpty)
        updates.changeHold = nil
        await vm.settle()
        #expect(vm.state.pinAllowed)
    }

    @Test func noOfferNothingToApprove() async {
        let updates = FakeReleaseUpdates(offer: nil)
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await vm.settle()
        #expect(!vm.state.loading)
        vm.approve(pin: "246802")
        #expect(updates.calls.isEmpty)
    }

    @Test func aWrongPinWaitsOutTheBackoffBeforeTryingAgain() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let ticker = StepTicker()
        let vm = ReleaseUpdateFlowViewModel(updates: updates, tick: ticker.tick)
        updates.progress = UpdateProgress(step: .badPin, from: rel(4), to: rel(5), failure: .backoff, waitSeconds: 3)
        await ticker.settle()
        #expect(vm.state.waitSeconds == 3)
        #expect(!vm.retry(pin: "246802"))
        #expect(updates.calls.isEmpty)
        for _ in 0..<3 { await ticker.advance() }
        #expect(vm.state.waitSeconds == 0)
        #expect(vm.retry(pin: "246802"))
        #expect(updates.calls == ["retry:246802"])
    }

    @Test func returningToTheOldReleaseAsksFirst() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateFlowViewModel(updates: updates)
        updates.progress = UpdateProgress(step: .newReleaseFailed, from: rel(4), to: rel(5), failure: .noResponse, canAbandon: true)
        await vm.settle()
        vm.askAbandon()
        #expect(vm.state.abandonConfirm)
        #expect(updates.calls.isEmpty)
        #expect(vm.confirmAbandon(pin: "246802"))
        #expect(!vm.state.abandonConfirm)
        #expect(updates.calls == ["abandon:246802"])
    }

    @Test func noWayBackIsAskedWhereThereIsNone() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateFlowViewModel(updates: updates)
        updates.progress = UpdateProgress(step: .newReleaseFailed, from: rel(4), to: rel(5), failure: .noResponse, canAbandon: false)
        await vm.settle()
        vm.askAbandon()
        #expect(!vm.state.abandonConfirm)
    }

    @Test func finishingLeavesTheOutcome() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateFlowViewModel(updates: updates)
        updates.progress = UpdateProgress(step: .failed, from: rel(4), to: rel(5), failure: .network)
        await vm.settle()
        vm.finish()
        #expect(updates.calls == ["finish"])
        #expect(updates.progress == nil)
    }

    /// (VAULT-MESSAGING §11.14.9 step 2; chosen; not in the spec) Which PIN the vault expects is read when the keypad
    /// becomes usable: at once when it is, else when the hold lifts; not when the PIN is handed over.
    @Test func thePinsGenerationIsReadWhenTheKeypadOpens() async {
        let first = FakeReleaseUpdates(offer: offer)
        first.pinGeneration = 3
        let open = ReleaseUpdateViewModel(updates: first, ownerCheck: vault, notes: FakeReleaseNotes())
        await open.settle()
        first.pinGeneration = 4
        #expect(open.approve(pin: "246802"))
        #expect(first.generations == [3])
        let updates = FakeReleaseUpdates(offer: offer)
        updates.pinGeneration = 3
        updates.changeHold = .changeChecking
        let held = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await held.settle()
        #expect(!held.state.pinAllowed)
        updates.pinGeneration = 4
        updates.changeHold = nil
        await held.settle()
        #expect(held.state.pinAllowed)
        #expect(held.approve(pin: "135791"))
        #expect(updates.generations == [4] && updates.calls == ["start:135791:5"])
    }

    /// A change decided while the member types the PIN on the update screen: nothing is sent with it, and the update's
    /// screen asks for the PIN again, read anew when its keypad opens.
    @Test func aChangeWhileThePinIsTypedSendsNothingAndAsksAgain() async throws {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateViewModel(updates: updates, ownerCheck: vault, notes: FakeReleaseNotes())
        await vm.settle()
        updates.pinGeneration = 1
        #expect(vm.approve(pin: "246802"))
        #expect(updates.calls == ["refused:246802"])
        let p = try #require(updates.progress)
        #expect(p.step == .failed && p.failureCode == VaultManager.codePinTakenBefore)
        let flow = ReleaseUpdateFlowViewModel(updates: updates)
        await flow.settle()
        #expect(flow.state.pinAllowed)
        #expect(flow.retry(pin: "135791"))
        #expect(updates.calls == ["refused:246802", "retry:135791"])
        #expect(updates.generations == [0, 1])
    }

    /// The update's own keypad: read when a step waits for the PIN; a change while the member types it there is refused
    /// too, for "Try again" and for "Return to release N".
    @Test func theUpdatesKeypadIsReadWhenAStepWaitsForThePin() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateFlowViewModel(updates: updates)
        updates.progress = UpdateProgress(step: .approving, from: rel(4), to: rel(5))
        await vm.settle()
        #expect(!vm.state.pinAllowed)
        updates.pinGeneration = 2
        updates.progress = UpdateProgress(step: .newReleaseFailed, from: rel(4), to: rel(5), failure: .noResponse, canAbandon: true)
        await vm.settle()
        updates.pinGeneration = 3
        #expect(vm.retry(pin: "246802"))
        // Read again as the keypad empties; another change while the PIN is typed for the return.
        updates.pinGeneration = 4
        vm.askAbandon()
        #expect(vm.confirmAbandon(pin: "246802"))
        #expect(updates.generations == [2, 3])
        #expect(updates.calls == ["refused:246802", "refused:246802"])
    }

    /// A reading is used once: after a PIN taken before a change is refused without the keypad ever closing (the step
    /// fails at once), the PIN typed again on the same screen goes with a fresh reading.
    @Test func aReadingIsUsedOnce() async {
        let updates = FakeReleaseUpdates(offer: offer)
        let vm = ReleaseUpdateFlowViewModel(updates: updates)
        updates.progress = UpdateProgress(step: .failed, from: rel(4), to: rel(5), failure: .network)
        await vm.settle()
        updates.pinGeneration = 1
        #expect(vm.retry(pin: "246802"))
        #expect(vm.retry(pin: "246802"))
        #expect(updates.calls == ["refused:246802", "retry:246802"])
        #expect(updates.generations == [0, 1])
    }

    /// (§11.14.9; chosen; not in the spec) While a PIN or password change is undecided the unlock screen does not offer
    /// the approval and none goes with the unlock, even one turned on before.
    @Test func noApprovalWithTheUnlockWhileAChangeIsUndecided() async {
        let locked = FakeVaultRepository(.locked)
        locked.preflightInfo = PreflightInfo(routed: rel(4), lastNumber: 4, softwareUpdated: false, rollback: false, offer: rel(5))
        let vm = UnlockViewModel(vault: locked, account: locked)
        await vm.settle()
        vm.setApproveOffer(true)
        locked.releaseUpdateHeld = true
        await vm.settle()
        #expect(vm.state.updateHeld)
        vm.setPin("40281795")
        vm.submit()
        await vm.settle()
        #expect(locked.lastApproved == nil)
        // Without the hold the approval goes.
        locked.releaseUpdateHeld = false
        try? await locked.lock()
        let again = UnlockViewModel(vault: locked, account: locked)
        await again.settle()
        again.setApproveOffer(true)
        again.setPin("40281795")
        again.submit()
        await again.settle()
        #expect(locked.lastApproved == rel(5))
    }

    @Test func whatsNewIsLookedUpForTheUnlockOfferOnly() async {
        let notes = FakeReleaseNotes(.unavailable)
        let locked = FakeVaultRepository(.locked)
        let first = UnlockViewModel(vault: locked, account: locked, releaseNotes: notes)
        await first.settle()
        #expect(notes.asked.isEmpty) // no offer
        locked.preflightInfo = PreflightInfo(
            routed: rel(4), lastNumber: 4, softwareUpdated: false, rollback: false, offer: rel(6), between: [rel(5)]
        )
        let vm = UnlockViewModel(vault: locked, account: locked, releaseNotes: notes)
        await vm.settle()
        #expect(notes.asked == [6])
        #expect(vm.state.notes == .unavailable)
        // An older release: the PIN is not sent, and nothing is offered.
        locked.preflightInfo = PreflightInfo(routed: rel(2), lastNumber: 4, softwareUpdated: false, rollback: true, offer: rel(6))
        let rollback = UnlockViewModel(vault: locked, account: locked, releaseNotes: notes)
        await rollback.settle()
        #expect(notes.asked == [6])
    }
}

/// One second of a countdown at a time, moved on only by the test.
@MainActor
final class StepTicker {
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    var tick: @Sendable () async throws -> Void {
        { [weak self] in try await self?.wait() }
    }

    private func wait() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// One second passes.
    func advance() async {
        await settle()
        let w = waiters
        waiters = []
        for c in w { c.resume() }
        await settle()
    }
}
