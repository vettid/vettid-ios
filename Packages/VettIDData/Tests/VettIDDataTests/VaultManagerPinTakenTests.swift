import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

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

    /// The check right before the request is built, whatever came before it: nothing goes out.
    @Test func theUnlockRequestIsNotBuiltWithAPinTakenBefore() async throws {
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
    }

    /// "Finish the move" with a PIN taken before a PIN change: the vault is locked, no unlock is sent, and the PIN asked
    /// for again opens it.
    @Test func finishTheMoveWithAPinTakenBeforeAPinChangeSendsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let old = m.phoneSecrets.pinGeneration
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        let unlocks = service.unlocks.count
        let r = try await m.finishMove(pin: pin, taken: old)
        #expect(r == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect(service.unlocks.count == unlocks && service.pinFailureCount == 0)
        #expect(try await m.finishMove(pin: newPin) == .success)
        #expect(service.unlocks.count == unlocks + 1 && m.phase == .unlocked)
    }

    /// The normal path: "Finish the move" locks and unlocks with the PIN.
    @Test func finishTheMoveOpensTheVault() async throws {
        defer { phone.close() }
        try await setUp()
        let unlocks = service.unlocks.count
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(service.unlocks.count == unlocks + 1 && service.pinFailureCount == 0 && m.phase == .unlocked)
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
