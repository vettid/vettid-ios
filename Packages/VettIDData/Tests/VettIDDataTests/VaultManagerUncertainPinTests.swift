import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// The uncertain PIN and the gate of VAULT-MESSAGING 0.45.0 §11.14.9 against ``FakeVaultService``: a PIN change whose
/// check ends without a decision leaves the PIN uncertain, and until an unlock with the two PIN prompts settles it every
/// operation that carries the PIN is refused before anything is sent (the owner check, the name change, a PIN or
/// password change, a new phone secret, Delete vault); an operation with the password alone goes on. While a change is
/// unresolved, the gate refuses at once with the text of the change (PIN or password).
@MainActor
@Suite(.serialized) struct VaultManagerUncertainPinTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let newPin = "518293"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: 1)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// A PIN change whose answers are lost, then the blob moved [moves] times without the app, and a restart (the request
    /// kept in memory is gone): the check sees another version and ends without a decision.
    func endedPinChange(applied: Bool, moves: Int) async throws {
        if applied {
            service.loseAnswers([VaultApi.typePinChange, "credential.version"], from: VaultApi.typePinChange)
        } else {
            service.loseRequests([VaultApi.typePinChange])
        }
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        for _ in 0..<moves { service.moveCredentialWithoutTheApp() }
        try phone.restart()
        service.loseAnswers([])
        service.loseRequests([])
        await m.checkUnresolvedChange(evenLocked: true)
        #expect(m.changeCheck == ChangeCheck(.pin, .ended))
        #expect(try m.phoneSecrets.unresolvedChange() == nil && m.phoneSecrets.uncertainPin() != nil)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion, "the latest blob kept")
    }

    func expectRefused(_ f: VaultFailure?, _ what: String) {
        #expect(f?.kind == .pinUncertain && f?.code == VaultManager.codePinUncertain, "\(what): \(String(describing: f))")
    }

    /// Every operation that carries the PIN is refused with nothing sent while the PIN is uncertain.
    @Test func everyOperationThatCarriesThePinIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        try await endedPinChange(applied: true, moves: 1)
        let mark = service.requestsSeen.count
        let check = try await m.ownerChecks.check(pin: newPin, password: password, holdOff: nil)
        #expect(check == .failed(.pinUncertain, code: VaultManager.codePinUncertain), "\(check)")
        let name = await m.profiles.changeName(pin: newPin, password: password, firstName: "Ada", lastName: "King")
        #expect(name == .failed(.pinUncertain, code: VaultManager.codePinUncertain), "\(name)")
        expectRefused(await vaultFailure { try await m.changePin(pin: newPin, newPin: pin, password: password) }, "pin.change")
        let newPassword = "another passphrase"
        expectRefused(await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: newPin) }, "password")
        expectRefused(await vaultFailure { try await m.renewPhoneSecret(pin: newPin, password: password) }, "renew")
        expectRefused(await vaultFailure { try await m.deleteVault(pin: newPin, password: password) }, "delete")
        expectRefused(await vaultFailure { try await m.newCredential(pin: newPin, password: password, newPassword: newPassword) }, "reset")
        // "Finish the move" is held too (VAULT-MESSAGING 0.46.0 §11.14.9 step 2): nothing locked or sent.
        let phase = m.phase
        expectRefused(await vaultFailure { _ = try await m.finishMove(pin: newPin) }, "finish the move")
        #expect(m.phase == phase, "not locked")
        #expect(service.requestsSeen.count == mark, "nothing sent: \(service.requestsSeen.dropFirst(mark))")
        #expect(m.changeHold()?.kind == .pinUncertain)
        #expect(service.ownerChecks.isEmpty && service.nameSets.isEmpty && service.renews.isEmpty && service.deletes.isEmpty)
        #expect(service.resets.isEmpty)
        // The password alone is not uncertain: the unlock window opens.
        try await m.openUnlockWindow(password: password)
    }

    /// An applied change whose check ended: the unlock asks for the previous PIN, then (after `device_secret`, nothing
    /// counted) the new one with the candidate, which settles the PIN; the PIN-bearing operations go again.
    @Test func theTwoStepUnlockSettlesItWithTheNewPin() async throws {
        defer { phone.close() }
        try await setUp()
        try await endedPinChange(applied: true, moves: 1)
        try await m.refresh()
        try await m.lock()
        #expect(m.unlockPinStep == .previous)
        #expect(try await m.unlock(pin: pin) == .newPinNeeded)
        #expect(try await m.unlock(pin: newPin) == .success)
        #expect(service.pinFailureCount == 0 && m.unlockPinStep == .pin)
        #expect(try m.phoneSecrets.uncertainPin() == nil && m.changeHold() == nil)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret)
        #expect(try await m.ownerChecks.check(pin: newPin, password: password, holdOff: nil) == .passed)
    }

    /// A change that never arrived, whose check ended (the blob moved twice): `ok` to the previous PIN settles it.
    @Test func okToThePreviousPinSettlesIt() async throws {
        defer { phone.close() }
        try await setUp()
        try await endedPinChange(applied: false, moves: 2)
        try await m.refresh()
        try await m.lock()
        #expect(m.unlockPinStep == .previous)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try m.phoneSecrets.uncertainPin() == nil && m.unlockPinStep == .pin && m.changeHold() == nil)
        #expect(try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil) == .passed)
        #expect(service.currentPin == pin && service.pinFailureCount == 0)
    }

    /// The uncertain PIN survives a restart (it is stored with the records).
    @Test func theUncertainPinSurvivesARestart() async throws {
        defer { phone.close() }
        try await setUp()
        try await endedPinChange(applied: true, moves: 1)
        try phone.restart()
        expectRefused(await vaultFailure { try await m.renewPhoneSecret(pin: newPin, password: password) }, "renew")
        m.refreshPinStep()
        #expect(m.unlockPinStep == .previous)
    }

    /// While a password change is unresolved and the vault answers, the gate refuses at once with the password's text;
    /// a PIN change's has its own. Neither waits for the check.
    @Test func theGateRefusesAtOnceWithTheChangesText() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typePasswordChange])
        _ = await vaultFailure { try await m.changePassword(password, newPassword: "another passphrase", pin: pin) }
        let mark = service.requestsSeen.count
        let check = try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil)
        #expect(check == .failed(.changeCheckingPassword, code: VaultManager.codeChangeChecking), "\(check)")
        #expect(m.changeHold()?.kind == .changeCheckingPassword)
        #expect(await vaultFailure { _ = try await m.finishMove(pin: pin) }?.kind == .changeCheckingPassword && m.phase == .unlocked)
        #expect(!service.requestsSeen.dropFirst(mark).contains(VaultApi.typeOwnerCheck))
        #expect(FailureKind.changeChecking.message != FailureKind.changeCheckingPassword.message)
    }

    /// An uncertain PIN holds the release update and the unlock screen's approval (one hold with the change's,
    /// VAULT-MESSAGING §11.14.9 step 2), said with the uncertain-PIN text; the update's unlock sends nothing.
    @Test func anUncertainPinHoldsTheReleaseUpdate() async throws {
        defer { phone.close() }
        try await setUp()
        try await endedPinChange(applied: true, moves: 1)
        #expect(m.releaseUpdateHeld && m.releaseUpdate.changeHold == .pinUncertain)
        #expect(FailureKind.pinUncertain.message.hasPrefix("VettID couldn't confirm whether your PIN was changed"))
        let unlocks = service.unlocks.count
        let r = await m.updateUnlock(pin: TakenPin(pin: pin, generation: m.phoneSecrets.pinGeneration), approve: nil, abandon: false) {}
        guard case .failed(let kind, let code, _) = r else {
            Issue.record("not refused: \(r)")
            return
        }
        #expect(kind == .pinUncertain && code == VaultManager.codeChangeHeld)
        #expect(service.unlocks.count == unlocks)
    }
}
