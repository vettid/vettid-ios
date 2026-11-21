import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// A provisional vault after a restart (VAULT-MESSAGING §11.3): who confirms it, and when.
extension VaultManagerFailureTests {
    /// Enrolled here, the credential made, its confirmation lost; then a restart.
    func provisionalRestarted() async throws {
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.failNext("vault.enroll.confirm")
        _ = await vaultFailure { try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in } }
        try await phone.restart()
    }

    /// Then a start whose read a lock overtakes: the vault found locked, not confirmed.
    func lockedAtTheStart() async throws {
        try await provisionalRestarted()
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        let heard = m.locksHeard
        service.sendEvent("vault.locking", #"{"reason":"test"}"#)
        #expect(await eventually { m.locksHeard != heard })
        service.releaseStatusReads()
        try await reading.value
        #expect(m.phase == .locked && !service.confirmed)
    }

    /// Then an unlock whose confirmation fails: it opens on "finishing" all the same, not confirmed.
    func finishingUnconfirmed() async throws {
        try await lockedAtTheStart()
        service.failNext("vault.enroll.confirm")
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(m.phase == .setup(.finishing) && !service.confirmed)
    }

    var confirmsSent: Int { service.requestsSeen.filter { $0 == "vault.enroll.confirm" }.count }

    /// A lock asked for before "Finish": the gate would not end the setup, so nothing is confirmed.
    @Test func finishingAfterALockSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        try await m.lock()
        _ = await vaultFailure { try await m.finishSetup() }
        #expect(confirmsSent == sent && !service.confirmed)
    }

    /// Not on the final onboarding screen: the vault open, its session too, and only the gate keeps the confirmation back.
    @Test func finishingOffTheFinishingStepSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        m.phase = .setup(.needsCredential)
        _ = await vaultFailure { try await m.finishSetup() }
        #expect(confirmsSent == sent && !service.confirmed)
        #expect(m.phase == .setup(.needsCredential), "the gate leaves the phase as it is")
    }

    /// Only the phone whose enrollment made the vault confirms it: another is refused, as before.
    @Test func finishingOnAnotherPhoneSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        try m.record.update(since: m.record.generation) { $0.enrolledHere = false }
        let sent = confirmsSent
        #expect(await vaultFailure { try await m.finishSetup() }?.code == VaultManager.codeEnrollUnconfirmed)
        #expect(confirmsSent == sent && !service.confirmed)
    }

    /// A confirmation that fails is said, and the setup stays on "finishing" for another try.
    @Test func aFailedConfirmationAtFinishingKeepsTheStep() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        service.failNext("vault.enroll.confirm")
        #expect(await vaultFailure { try await m.finishSetup() } != nil)
        #expect(m.phase == .setup(.finishing) && !service.confirmed)
        try await m.finishSetup()
        #expect(service.confirmed && m.phase == .unlocked)
    }

    /// A lock heard while the start's confirmation is on its way, which then fails: Locked, not "can't connect".
    @Test func aLockDuringTheStartsConfirmationGivesLocked() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        service.lockBefore("vault.enroll.confirm")
        service.refuse("vault.enroll.confirm", with: "internal", times: 1)
        // The refusal waits until the lock was heard: they reach the main actor by separate hops.
        service.holdAnswers(to: "vault.enroll.confirm")
        let heard = m.locksHeard
        let reading = Task { try await m.refresh() }
        #expect(await eventually { m.locksHeard != heard })
        service.releaseHeldAnswers()
        try await reading.value
        #expect(m.phase == .locked, "\(m.phase)")
        #expect(!service.confirmed)
    }

    /// "Finish" opens the session as it is now: one stopped meanwhile (a background, say) does not leave the vault
    /// unconfirmed.
    @Test func finishingWithoutASessionOpensOneAndConfirms() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        m.stopCollecting()
        #expect(m.session == nil)
        try await m.finishSetup()
        #expect(service.confirmed && m.phase == .unlocked)
    }

    // MARK: - One confirmation at a time

    /// Two status reads that find the vault open and unconfirmed [first] has started confirming: the second joins it.
    func twoReads(_ first: @escaping @MainActor () async throws -> Void) async throws {
        service.holdAnswers(to: "vault.enroll.confirm")
        let one = Task { try await first() }
        #expect(await eventually { service.heldAnswers == 1 })
        let two = Task { try await m.refresh() }
        #expect(await eventually { m.confirmationsJoined == 1 }, "the second read joins the confirmation on its way")
        service.releaseHeldAnswers()
        try await one.value
        try await two.value
    }

    /// The start's read and the return to the foreground's, both finding the vault open: one confirmation.
    @Test func twoReadsAtTheStartSendOneConfirmation() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        let sent = confirmsSent
        try await twoReads { try await m.refresh() }
        #expect(confirmsSent == sent + 1 && service.confirmed)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
    }

    /// A read beside "Finish": one confirmation, and the setup ends.
    @Test func aReadBesideFinishSendsOneConfirmation() async throws {
        defer { phone.close() }
        try await finishingUnconfirmed()
        let sent = confirmsSent
        try await twoReads { try await m.finishSetup() }
        #expect(confirmsSent == sent + 1 && service.confirmed)
        #expect(m.phase == .unlocked, "\(m.phase)")
    }

    /// The shared confirmation fails: both reads say that failure (not one "can't connect" over another's open vault), and
    /// the next read confirms.
    @Test func aSharedConfirmationsFailureIsEachReadsOwn() async throws {
        defer { phone.close() }
        try await provisionalRestarted()
        let sent = confirmsSent
        service.refuse("vault.enroll.confirm", with: "internal", times: 1)
        try await twoReads { try await m.refresh() }
        #expect(confirmsSent == sent + 1 && !service.confirmed)
        guard case .unreachable = m.phase else { Issue.record("\(m.phase)"); return }
        try await m.refresh()
        #expect(confirmsSent == sent + 2 && service.confirmed)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
    }

    /// A vault found locked at the restart, then unlocked: the unlock confirms it, once, and "Finish" sends nothing more.
    @Test func anUnlockConfirmsAProvisionalVault() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        let sent = confirmsSent
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(confirmsSent == sent + 1 && service.confirmed)
        #expect(m.phase == .setup(.finishing), "\(m.phase)")
        try await m.finishSetup()
        #expect(confirmsSent == sent + 1 && m.phase == .unlocked)
    }

    /// Only the phone whose enrollment made the vault confirms it at an unlock.
    @Test func anUnlockOnAnotherPhoneSendsNoConfirmation() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        try m.record.update(since: m.record.generation) { $0.enrolledHere = false }
        let sent = confirmsSent
        #expect(try await m.unlock(pin: "402817") == .success)
        #expect(confirmsSent == sent && !service.confirmed)
    }

    /// A lock heard while the unlock's confirmation is on its way: the vault is not opened over it.
    @Test func aLockDuringTheUnlocksConfirmationGivesLocked() async throws {
        defer { phone.close() }
        try await lockedAtTheStart()
        service.lockBefore("vault.enroll.confirm")
        service.holdAnswers(to: "vault.enroll.confirm")
        let heard = m.locksHeard
        let unlocking = Task { try await m.unlock(pin: "402817") }
        #expect(await eventually { m.locksHeard != heard })
        service.releaseHeldAnswers()
        _ = try await unlocking.value
        #expect(m.phase == .locked, "\(m.phase)")
    }
}
