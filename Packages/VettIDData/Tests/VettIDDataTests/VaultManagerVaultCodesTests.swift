import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The root screen "This phone can't use your vault" and `forbidden` over ``FakeVaultService`` (IOS-PLAN §4.4 (1), (3),
/// §4.5 (3)): raised by the member's requests only, never by an answer from before a lock; no erase; "Try again" and
/// "Lock vault".
@MainActor
@Suite(.serialized) struct VaultManagerVaultCodesTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let noHolder = #"{"reason":"no_holder"}"#

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// `credential_required{no_holder}` to the daily check: the root screen, nothing erased; "Try again" leaves it (the
    /// check asks for the PIN and password again), and a vault that has a holder again answers the next check; "Lock
    /// vault" sends `vault.lock`, and the unlock opens the vault.
    @Test func credentialRequiredShowsTheRootScreenAndErasesNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        let vaultID = m.record.value.vaultID
        service.refuseNext("vault.owner-check", code: "credential_required", message: "no holder", body: noHolder)
        let r = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(r == .failed(.credentialRequired, code: "credential_required"))
        #expect(m.credentialRequired && m.credentialRequiredResend == nil && m.phase == .unlocked)
        #expect(phone.phoneKeys.count == keys && m.record.value.vaultID == vaultID && m.usesPhoneSecret)
        m.credentialRequiredTryAgain()
        #expect(!m.credentialRequired)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)

        service.refuseNext("vault.owner-check", code: "credential_required")
        _ = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(m.credentialRequired)
        let locks = service.relayLocks
        try await m.lock()
        #expect(!m.credentialRequired && m.phase == .locked)
        #expect(await eventually { service.relayLocks == locks + 1 })
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// From a PIN change, a name change and a credential unlock.
    @Test func credentialRequiredFromEachOwnerRequest() async throws {
        defer { phone.close() }
        try await setUp()
        service.refuseNext("pin.change", code: "credential_required", body: noHolder)
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: "975310", password: password) }?.kind == .credentialRequired)
        #expect(m.credentialRequired)
        m.credentialRequiredTryAgain()

        service.refuseNext("account.name.set", code: "credential_required", body: noHolder)
        let name = await m.profiles.changeName(pin: pin, password: password, firstName: "Ada", lastName: "Byron")
        #expect(name == .failed(.credentialRequired, code: "credential_required") && m.credentialRequired)
        m.credentialRequiredTryAgain()

        service.refuseNext("credential.unlock", code: "credential_required", body: noHolder)
        #expect(await vaultFailure { try await m.openUnlockWindow(password: password) }?.kind == .credentialRequired)
        #expect(m.credentialRequired && m.phase == .unlocked)
    }

    /// VAULT-MESSAGING 0.54.0 §3.5.9, §10.2: a vault with a credential but no holder answers `vault.delete`
    /// `credential_required{reason: "no_holder"}`, before the PIN or the password is tested. The root screen, as
    /// vettid-android's `vaultGuard` raises it; the vault is not deleted, nothing on this phone is erased, and no "being
    /// deleted" opens. "Try again" leaves the screen with nothing kept to resend (the request carries the PIN); once the
    /// vault has a holder again, the member's new try deletes it.
    @Test func credentialRequiredToADeletion() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        let vaultID = m.record.value.vaultID
        let pinFailures = service.pinFailureCount
        service.noHolder = true
        let f = await vaultFailure { try await m.deleteVault(pin: pin, password: password) }
        #expect(f?.kind == .credentialRequired && f?.code == "credential_required", "\(String(describing: f))")
        #expect(m.credentialRequired && m.credentialRequiredResend == nil)
        #expect(!service.vaultDeleted && service.deletes.isEmpty && service.pinFailureCount == pinFailures)
        #expect(m.phase == .unlocked && m.usesPhoneSecret)
        #expect(phone.phoneKeys.count == keys && m.record.value.vaultID == vaultID)
        m.credentialRequiredTryAgain()
        #expect(!m.credentialRequired && m.phase == .unlocked)

        service.noHolder = false
        #expect(await vaultFailure { try await m.deleteVault(pin: pin, password: password) } == nil)
        #expect(service.vaultDeleted && m.phase == .deleting)
    }

    /// A request without a secret that sets the same value again (`settings.set`) is sent again by "Try again"; it is the
    /// only kind of request ever kept (``Resend``).
    @Test func tryAgainResendsASettingsChange() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(service.backupSetting)
        service.refuseNext("settings.set", code: "credential_required", body: noHolder)
        #expect(await vaultFailure { try await m.setBackup(false) }?.kind == .credentialRequired)
        #expect(m.credentialRequired && m.credentialRequiredResend == .setting(key: VaultManager.keyBackup, json: "false"))
        #expect(service.backupSetting)
        m.credentialRequiredTryAgain()
        #expect(!m.credentialRequired && m.credentialRequiredResend == nil)
        #expect(await eventually { !service.backupSetting })
    }

    /// `forbidden` to the resend of a setting (``Resend/setting(key:json:)``, the request "Try again" sends again by
    /// itself, as ``tryAgainResendsASettingsChange()`` shows): `settings.set` is not holder-only, so it is the code
    /// (IOS-PLAN §4.4 (2), (3)), not "Your vault moved to a new phone"; the root screen is not raised, nothing is kept for
    /// another "Try again", the setting is unchanged, no change ends and nothing is erased.
    @Test func forbiddenToTheResentSettingIsTheCode() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        service.refuseNext("settings.set", code: "forbidden")
        let resend = Resend.setting(key: VaultManager.keyBackup, json: "false")
        #expect(await vaultFailure { try await m.resend(resend) }?.kind == .vaultCode("forbidden"))
        #expect(!m.credentialRequired && m.credentialRequiredResend == nil && m.changeCheck == nil)
        #expect(service.backupSetting && phone.phoneKeys.count == keys && m.phase == .unlocked && m.usesPhoneSecret)
    }

    /// `forbidden` to the credential screen's `credential.version` outside a change: not a holder-only type (VAULT-MESSAGING
    /// §3.5.9), so the code (IOS-PLAN §4.4 (2)); no root screen, no change, nothing erased.
    @Test func forbiddenToTheCredentialVersionIsTheCode() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        service.refuseNext("credential.version", code: "forbidden")
        #expect(await vaultFailure { _ = try await m.status() }?.kind == .vaultCode("forbidden"))
        #expect(!m.credentialRequired && m.changeCheck == nil && phone.phoneKeys.count == keys && m.phase == .unlocked)
    }

    /// A refusal of the daily check that an unlock includes (the vault past its deadline) shows the screen, the phase still
    /// locked; it ends with "Lock vault", not with the phase.
    @Test func aRefusalDuringAnUnlockWithTheCheckShowsTheScreen() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        service.advanceVaultClock(86_401)
        service.refuseNext("vault.owner-check", code: "credential_required", body: noHolder)
        _ = try await m.unlockWithCheck(pin: pin, password: password)
        #expect(m.ownerChecks.unlockCheckOutcome == .failed(.credentialRequired, code: "credential_required"))
        #expect(m.credentialRequired)
        try await m.lock()
        #expect(!m.credentialRequired)
    }

    /// The reads the app sends by itself (the owner check's status, the account) never raise the screen.
    @Test func automaticRequestsDoNotRaiseTheScreen() async throws {
        defer { phone.close() }
        try await setUp()
        service.refuseNext("vault.status", code: "credential_required", body: noHolder)
        #expect(await vaultFailure { try await m.ownerChecks.refreshOwnerCheck() }?.kind == .credentialRequired)
        service.refuseNext("account.get", code: "credential_required", body: noHolder)
        await m.refreshAccount()
        #expect(!m.credentialRequired)
    }

    /// An answer to a request sent before a lock does not raise the screen over the unlock screen.
    @Test func anAnswerFromBeforeALockDoesNotRaiseTheScreen() async throws {
        defer { phone.close() }
        try await setUp()
        let since = m.lockGeneration
        let op = VaultOpError(type: "vault.owner-check", code: "credential_required", detail: "", body: Array(noHolder.utf8))
        let f = VaultFailure(.credentialRequired, code: "credential_required", cause: op)
        try await m.lock()
        _ = m.noted(f, since: since)
        #expect(!m.credentialRequired && m.phase == .locked)
        _ = m.noted(f, since: m.lockGeneration)
        #expect(m.credentialRequired)
    }

    /// `forbidden` to `pin.change`: the change ends (IOS-PLAN §6.3, 0.1.13) and its failure is ``FailureKind/notHolder``,
    /// "Your vault moved to a new phone"; no root screen, no erase.
    @Test func forbiddenOnAPinChangeIsNotTheHolder() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        service.refuseNext("pin.change", code: "forbidden", message: "not the holder")
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: "975310", password: password) }
        #expect(f?.kind == .notHolder && f?.code == "forbidden")
        #expect(!m.credentialRequired && m.phase == .unlocked && m.changeCheck?.status == .notHolder)
        // Nothing erased: the current phone key stays (the PIN change's candidate shares it), and the vault opens.
        #expect(phone.phoneKeys.count == keys && m.usesPhoneSecret)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }
}
