import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A PIN typed on a flow's own screen (the release update, "Finish the move") goes through the member API's unlock, not
/// the credential lock, so the count of secrets sent does not protect it (VAULT-MESSAGING §11.14.9 step 2). Taken
/// before a change moved which PIN the vault expects (sent, or decided after its answer was lost), it is sent nothing:
/// the step fails with ``VaultManager/codePinTakenBefore`` and the PIN is asked for again, so no PIN attempt is spent on
/// the PIN from before the change. Against ``FakeVaultService``.
@MainActor
@Suite(.serialized) struct VaultManagerPinTakenTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let newPin = "518293"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
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

    var target: ReleaseView {
        get throws { try #require(m.releaseUpdate.offer?.target) }
    }

    /// The PIN as a screen hands it over now.
    func taken(_ p: String) -> TakenPin { TakenPin(pin: p, generation: m.phoneSecrets.pinGeneration) }

    /// The update's unlock with [old] (taken before the change) sends nothing and counts no wrong PIN; the PIN asked for
    /// again moves the vault.
    func expectAskedAgain(_ old: TakenPin) async throws {
        try await m.lockForUpdate()
        let unlocks = service.unlocks.count
        let r = await m.updateUnlock(pin: old, approve: try target, abandon: false) {}
        #expect(r == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect(service.unlocks.count == unlocks && service.pinFailureCount == 0)
        #expect(await m.updateUnlock(pin: taken(newPin), approve: try target, abandon: false) {} == .moved)
        #expect(service.pinFailureCount == 0)
    }

    /// The PIN is typed on the update's screen; a PIN change goes out and is answered before the update's unlock.
    @Test func anUpdateWithAPinTakenBeforeAPinChangeSendsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let old = taken(pin)
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(service.currentPin == newPin && !m.releaseUpdateHeld)
        try await expectAskedAgain(old)
    }

    /// The PIN is typed on the update's screen; a PIN change whose answer was lost is decided as applied (the check after
    /// a late answer) before the update's unlock: no hold is left, and the PIN typed before is the old one.
    @Test func anUpdateWithAPinTakenBeforeALateDecisionSendsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let old = taken(pin)
        service.loseAnswers([VaultApi.typePinChange, "credential.version"], from: VaultApi.typePinChange)
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(m.releaseUpdateHeld)
        service.loseAnswers([])
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.pin, .applied) && !m.releaseUpdateHeld)
        try await expectAskedAgain(old)
    }

    /// The check right before the request is posted, whatever came before it: nothing goes out.
    @Test func theUnlockRequestIsNotPostedWithAPinTakenBefore() async throws {
        defer { phone.close() }
        try await setUp()
        let old = m.phoneSecrets.pinGeneration
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        try await m.lock()
        let unlocks = service.unlocks.count
        var route = UnlockRoute(followMove: false, pinSteps: false)
        route.pinTaken = old
        let o = await m.unlockOutcome(pin: pin, options: UnlockOptions(), route: route)
        #expect(o.attempt == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect(service.unlocks.count == unlocks && service.pinFailureCount == 0)
        // Refused before the request was built: no pending unlock kept, no standing token recorded as issued.
        #expect(m.session?.device.pendingUnlock == nil)
    }

    /// "Finish the move" with a PIN taken before a PIN change: the vault is not locked, no unlock is sent, and the PIN
    /// asked for again opens it.
    @Test func finishTheMoveWithAPinTakenBeforeAPinChangeSendsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let old = m.phoneSecrets.pinGeneration
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        let unlocks = service.unlocks.count
        let locks = (service.memberLocks, service.relayLocks)
        let r = try await m.finishMove(pin: pin, taken: old)
        #expect(r == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect(service.unlocks.count == unlocks && service.pinFailureCount == 0)
        #expect(service.memberLocks == locks.0 && service.relayLocks == locks.1 && service.isOpen && m.phase == .unlocked)
        #expect(try await m.finishMove(pin: newPin) == .success)
        #expect(service.unlocks.count == unlocks + 1 && m.phase == .unlocked)
    }

    /// The update's keypad read before a PIN change: "Update" fails at once, with the vault neither locked nor sent an
    /// unlock, and the PIN is asked for again.
    @Test func anUpdateWithAStaleReadingNeverLocksTheVault() async throws {
        defer { phone.close() }
        try await setUp()
        let old = m.phoneSecrets.pinGeneration
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        let unlocks = service.unlocks.count
        let locks = (service.memberLocks, service.relayLocks)
        #expect(m.releaseUpdate.start(pin: pin, offer: try #require(m.releaseUpdate.offer), generation: old))
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .failed && p.failureCode == VaultManager.codePinTakenBefore && p.vaultOpen)
        #expect(service.unlocks.count == unlocks && service.memberLocks == locks.0 && service.relayLocks == locks.1)
        #expect(service.isOpen && m.phase == .unlocked)
    }

    /// The normal path: "Finish the move" locks and unlocks with the PIN.
    @Test func finishTheMoveOpensTheVault() async throws {
        defer { phone.close() }
        try await setUp()
        let unlocks = service.unlocks.count
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(service.unlocks.count == unlocks + 1 && service.pinFailureCount == 0 && m.phase == .unlocked)
    }

    // MARK: - A change decided after the PIN was taken (a password change: the unlock's PIN step never moves)

    /// A password change whose answer was lost ([lose]: its request or its answer), and the generation read while it is
    /// undecided (its marker stored).
    func passwordChangeUndecided(losingTheRequest lose: Bool) async -> Int {
        let type = "credential.password.change"
        if lose {
            service.loseRequests([type])
        } else {
            service.loseAnswers([type, "credential.version"], from: type)
        }
        _ = await vaultFailure { try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin) }
        #expect((try? m.phoneSecrets.unresolvedChange())??.type == .password)
        service.loseRequests([])
        service.loseAnswers([])
        return m.phoneSecrets.pinGeneration
    }

    /// Decided applied after the PIN was taken: the update's unlock sends nothing.
    @Test func aChangeDecidedAppliedMovesIt() async throws {
        defer { phone.close() }
        try await setUp()
        let taken = await passwordChangeUndecided(losingTheRequest: false)
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.password, .applied))
        try await m.lockForUpdate()
        let unlocks = service.unlocks.count
        let r = await m.updateUnlock(pin: TakenPin(pin: pin, generation: taken), approve: try target, abandon: false) {}
        #expect(r == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect(service.unlocks.count == unlocks)
    }

    /// Decided not applied (the same version past `exp`).
    @Test func aChangeDecidedNotAppliedMovesIt() async throws {
        defer { phone.close() }
        try await setUp()
        let taken = await passwordChangeUndecided(losingTheRequest: true)
        let past = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        service.advanceVaultClock(past)
        phone.clockAhead = past
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.password, .notApplied))
        #expect(m.phoneSecrets.pinGeneration != taken)
    }

    /// Ended without a decision (another version, after a restart: the generation is read on the new start).
    @Test func aCheckThatEndsMovesIt() async throws {
        defer { phone.close() }
        try await setUp()
        _ = await passwordChangeUndecided(losingTheRequest: false)
        service.moveCredentialWithoutTheApp()
        try phone.restart()
        let taken = m.phoneSecrets.pinGeneration
        await m.checkUnresolvedChange(evenLocked: true)
        #expect(m.changeCheck == ChangeCheck(.password, .ended))
        #expect(m.phoneSecrets.pinGeneration != taken)
    }

    /// The unlock's PIN step moving alone (the previous PIN answered `device_secret`: the new one is asked for) moves it.
    @Test func theUnlocksPinStepMovesIt() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typePinChange, "credential.version"], from: VaultApi.typePinChange)
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        try await m.lock()
        service.loseAnswers([])
        #expect(m.unlockPinStep == .previous)
        let taken = m.phoneSecrets.pinGeneration
        #expect(try await m.unlock(pin: pin) == .newPinNeeded)
        #expect(m.unlockPinStep == .new && m.phoneSecrets.pinGeneration != taken)
    }

    /// What moves the generation: a password change and a new phone secret going out, as well as a PIN change.
    @Test func everySecretSentMovesIt() async throws {
        defer { phone.close() }
        try await setUp()
        var last = m.phoneSecrets.pinGeneration
        try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin)
        #expect(m.phoneSecrets.pinGeneration > last)
        last = m.phoneSecrets.pinGeneration
        try await m.renewPhoneSecret(pin: pin, password: "a brand new passphrase")
        #expect(m.phoneSecrets.pinGeneration > last)
        last = m.phoneSecrets.pinGeneration
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phoneSecrets.pinGeneration == last, "an unlock with nothing to settle leaves it")
    }
}
