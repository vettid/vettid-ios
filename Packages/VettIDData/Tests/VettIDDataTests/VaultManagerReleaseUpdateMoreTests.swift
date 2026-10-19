import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The release update's harder paths end to end against ``FakeVaultService``: the way back from a new release that does
/// not open the vault (§11.10.4 abandonment, with `409 vault_busy` first, §11.10.5), the member API still routing to the
/// release the vault left (§11.10.6), and the hold while a PIN or password change is undecided (§11.14.9).
@MainActor
@Suite(.serialized) struct VaultManagerReleaseUpdateMoreTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: 0.4)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        service.listsRelease4 = true
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.offer?.target.number == 4)
    }

    var offer: ReleaseUpdateOffer {
        get throws { try #require(m.releaseUpdate.offer) }
    }

    /// Moved to release 4, which does not open the vault; "Return to release 3": an instance of release 4 holds the
    /// vault (`vault_busy`), so the vault is locked first and the return sent again; the vault answers `abandoned` and
    /// opens on release 3. The approval of the return names release 3 itself.
    @Test func aNewReleaseThatDoesNotOpenTheVaultCanBeLeft() async throws {
        defer { phone.close() }
        try await setUp()
        service.unlockAnswers(.vault, .sealed("retry"))
        _ = m.releaseUpdate.start(pin: pin, offer: try offer)
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .newReleaseFailed && p.canAbandon)
        #expect(service.pendingMove == 4)
        service.holdsLeaseElsewhere = true
        let locksBefore = service.memberLocks + service.relayLocks
        m.releaseUpdate.abandon(pin: pin)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .abandoned)
        #expect(m.releaseUpdate.progress?.vaultOpen == true)
        #expect(service.memberLocks + service.relayLocks > locksBefore, "locked before the return was sent again")
        let back = try #require(service.releaseUpdates.last)
        #expect(back.to == FakeVaultService.pcr0 && back.toRelease == 3)
        #expect(service.pendingMove == nil && service.routedRelease == 3 && service.isOpen)
        let st = try #require(m.session?.device.altState)
        #expect(st.releaseNumber == 3 && st.release == FakeVaultService.pcr0 && st.previousRelease.isEmpty)
        #expect(m.phase == .unlocked)
    }

    /// The member API keeps routing to release 3 for a moment after the move: the unlock that should reach release 4 is
    /// not sent to 3 (a rollback), it waits and tries again, and reaches 4.
    @Test func aRoutingThatLagsBehindTheMoveIsWaitedOut() async throws {
        defer { phone.close() }
        try await setUp()
        service.lagRoutesAfterMove = 2
        _ = m.releaseUpdate.start(pin: pin, offer: try offer)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .done)
        #expect(m.session?.device.altState.releaseNumber == 4)
    }

    /// Still routed to the old release after the tries: a neutral failure, never the rollback's text; the way back is
    /// offered.
    @Test func aRoutingThatNeverCatchesUpIsNoRollback() async throws {
        defer { phone.close() }
        try await setUp()
        service.lagRoutesAfterMove = 10
        _ = m.releaseUpdate.start(pin: pin, offer: try offer)
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .newReleaseFailed)
        #expect(p.failure == .vaultUnavailable && p.failureCode == VaultManager.codeReleaseNotRouted)
        #expect(p.failure != .rollback)
    }

    /// Only the unlock right after a move waits: a later ordinary unlock routed to the release moved from is a rollback
    /// (§11.10.6), said as one, and no PIN is sent.
    @Test func aLaterUnlockRoutedToThePreviousReleaseIsARollback() async throws {
        defer { phone.close() }
        try await setUp()
        _ = m.releaseUpdate.start(pin: pin, offer: try offer)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .done)
        m.releaseUpdate.finish()
        try await m.lock()
        service.routedRelease = 3
        let unlocksBefore = service.unlocks.count
        guard case .failed(let kind, let code, _) = try await m.unlock(pin: pin) else {
            Issue.record("not refused")
            return
        }
        #expect(kind == .rollback && code == "rollback_release")
        #expect(service.unlocks.count == unlocksBefore, "no PIN sent to the older release")
    }

    /// The vault manager says when no approval may go with an unlock: a change is undecided.
    @Test func theVaultSaysWhenAnApprovalIsHeld() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(!m.releaseUpdateHeld)
        service.loseRequests(["pin.change"])
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        #expect(m.releaseUpdateHeld)
    }

    /// The unlock screen's approval waits out the same lag.
    @Test func theUnlockScreensApprovalWaitsOutALag() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        let target = try #require(try await m.preflight().offer)
        service.lagRoutesAfterMove = 1
        #expect(try await m.unlock(pin: pin, approve: target) == .success)
        #expect(m.session?.device.altState.releaseNumber == 4)
    }

    /// (§11.14.9) A PIN change whose answer was lost: the update is held ("still checking"), and neither a lock nor an
    /// unlock is sent for it.
    @Test func anUndecidedPinChangeHoldsTheUpdate() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["pin.change"])
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        try expectHeld()
    }

    /// The same for a password change whose answer was lost.
    @Test func anUndecidedPasswordChangeHoldsTheUpdate() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["credential.password.change"])
        _ = await vaultFailure { try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin) }
        try expectHeld()
    }

    private func expectHeld() throws {
        let hold = m.releaseUpdate.changeHold
        #expect(hold == .changeChecking || hold == .changeCheckingPassword || hold == .changeUnresolved)
        let locks = service.memberLocks + service.relayLocks
        let unlocks = service.unlocks.count
        #expect(!m.releaseUpdate.start(pin: pin, offer: try offer))
        #expect(m.releaseUpdate.progress == nil)
        #expect(service.memberLocks + service.relayLocks == locks && service.unlocks.count == unlocks)
        #expect(m.phase == .unlocked)
    }

    /// The update's own unlock sends nothing while a change is undecided, and never moves the unlock's PIN steps.
    @Test func theUpdatesUnlockSendsNothingWhileHeld() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["pin.change"])
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        let unlocks = service.unlocks.count
        let step = m.unlockPinStep
        let taken = TakenPin(pin: pin, generation: m.phoneSecrets.pinGeneration)
        let r = await m.updateUnlock(pin: taken, approve: try offer.target, abandon: false) {}
        guard case .failed(let kind, let code, _) = r else {
            Issue.record("not refused: \(r)")
            return
        }
        #expect(kind == .changeChecking || kind == .changeUnresolved)
        #expect(code == VaultManager.codeChangeHeld)
        #expect(service.unlocks.count == unlocks && m.unlockPinStep == step && !m.newPinAsked)
    }

    /// What a wipe or a forget runs: no offer, update or dismissal is kept.
    @Test func clearingForgetsTheUpdate() async throws {
        defer { phone.close() }
        try await setUp()
        m.releaseUpdate.dismissBanner(at: Date())
        m.releaseUpdate.clear()
        #expect(m.releaseUpdate.offer == nil && m.releaseUpdate.progress == nil && m.releaseUpdate.dismissal == nil)
        #expect(!m.releaseUpdate.offerKnown)
    }
}
