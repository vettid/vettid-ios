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

    /// Then a start whose read a lock overtakes, and an unlock: on "finishing", not confirmed.
    func finishingUnconfirmed() async throws {
        try await provisionalRestarted()
        service.holdStatusReads()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { service.heldStatusReads == 1 })
        let heard = m.locksHeard
        service.sendEvent("vault.locking", #"{"reason":"test"}"#)
        #expect(await eventually { m.locksHeard != heard })
        service.releaseStatusReads()
        try await reading.value
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
        try await m.refresh()
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
}
