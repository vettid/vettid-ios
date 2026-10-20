import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// The rotation (`credential.rotate`), a new credential (`credential.reset`) and the clone alarm
/// (`credential.alarm.confirm`) end to end against ``FakeVaultService``, which answers them as vettid-vault does
/// (VAULT-MESSAGING §3.5.5, §3.5.9, §10.6), and the offer to rotate after a PIN or password change (ANDROID-PLAN
/// "Transfer"). Mirrors vettid-android's `rotate`, `newCredential` and `confirmAlarm` tests.
@MainActor
@Suite(.serialized) struct VaultManagerRotateTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let newPassword = "another long passphrase"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        // A rotation is followed by the vault's identity rotation and its rekey (§3.4, §6.5), whose key work runs on the
        // phone's receiving side while the next answers wait behind it: a wait long enough for a loaded test run.
        phone = try TestVaultPhone(service: service, requestTimeout: 2)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    // MARK: - The rotation

    /// The password beside the blob: a new key, the CEK rotated and the new blob kept, the unlock window over.
    @Test func aRotationMakesANewKey() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.openUnlockWindow(password: password)
        let before = service.vaultCredentialVersion
        try await m.rotate(password: password)
        #expect(service.rotations == [password])
        #expect(service.vaultCredentialVersion == before + 1 && service.credentialKey != FakeVaultService.credentialKeyID)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion, "the new blob kept")
        #expect(m.unlockWindow == nil)
        let st = try await m.status()
        #expect(st.keyFingerprint == String(service.credentialKey.prefix(VaultManager.keyFingerprintChars)))
    }

    /// The vault rotates its `ik` and `kem` with the rotation (§3.4): the phone follows `identity.rotate` and answers the
    /// rekey (§6.5), and the session goes on in the new epoch: further requests, a credential operation included.
    @Test func aRotationThenFurtherRequests() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.rotate(password: password)
        #expect(service.identityRotations == 1)
        _ = try await m.status()
        #expect(await eventually { !service.rekeyPending }, "the phone answered the rekey")
        try await m.openUnlockWindow(password: password)
        try await m.rotate(password: password)
        #expect(service.identityRotations == 2 && service.rotations.count == 2)
        #expect(try await m.status().version == service.vaultCredentialVersion)
    }

    /// The answer lost after the vault rotated: no answer is reported, and the member's next try meets
    /// `stale_credential` (the holder's own retry), fetches the latest blob and rotates again; the session goes on.
    @Test func aLostAnswerThenATryAgain() async throws {
        defer { phone.close() }
        try await setUp()
        let before = service.vaultCredentialVersion
        service.loseAnswers([VaultApi.typeRotate])
        #expect(await vaultFailure { try await m.rotate(password: password) }?.kind == .noResponse)
        #expect(service.vaultCredentialVersion == before + 1 && service.alarmState == nil)
        service.loseAnswers([])
        try await m.rotate(password: password)
        #expect(service.rotations.count == 3, "the lost one, the stale one and its retry")
        #expect(service.vaultCredentialVersion == before + 2 && service.alarmState == nil)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion)
        try await m.openUnlockWindow(password: password)
    }

    /// The forced rotation with a blob older than the vault's (a phone restored from a backup, §3.5.9): presenting it
    /// raises the alarm; after "that was me" the rotation first fetches the latest blob, then resolves the alarm.
    @Test func theForcedRotationFetchesTheLatestBlob() async throws {
        defer { phone.close() }
        try await setUp()
        service.moveCredentialWithoutTheApp()
        service.moveCredentialWithoutTheApp()
        #expect(await vaultFailure { try await m.openUnlockWindow(password: password) }?.kind == .credentialFrozen)
        #expect(await eventually { m.alarm?.frozen == true })
        try await m.confirmAlarm(mine: true)
        try await m.rotate(password: password)
        #expect(m.alarm == nil && service.alarmState == nil)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion)
        try await m.openUnlockWindow(password: password)
    }

    /// The same when the phone did not hear of the alarm: the rotation is answered `rotation_required`, the latest blob is
    /// fetched, and the rotation sent once more.
    @Test func aRotationRefusedForAnOldBlobIsSentOnceMore() async throws {
        defer { phone.close() }
        try await setUp()
        service.moveCredentialWithoutTheApp()
        service.moveCredentialWithoutTheApp()
        service.raiseCloneAlarm(presenter: "holder", told: false)
        service.requireRotation()
        #expect(m.alarm == nil)
        try await m.rotate(password: password)
        #expect(service.rotations.count == 2 && service.alarmState == nil && m.alarm == nil)
        try await m.openUnlockWindow(password: password)
    }

    /// A wrong password is refused as it is, and is not a failed owner check (§3.6.1: the password backoff only).
    @Test func aWrongPasswordIsNotAFailedCheck() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await vaultFailure { try await m.rotate(password: "wrong") }?.kind == .badPassword)
        #expect(service.ownerCheckFailures == 0 && service.passwordFailureCount == 1)
    }

    /// A credential operation (§11.14.9 step 2): refused at once, nothing sent, while a change is unresolved.
    @Test func aRotationWaitsForAnUnresolvedChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typePasswordChange])
        _ = await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: pin) }
        #expect(await vaultFailure { try await m.rotate(password: password) }?.kind == .changeCheckingPassword)
        #expect(service.rotations.isEmpty)
    }

    // MARK: - The rotate offer

    /// A password change offers the rotation; the rotation takes the offer up. Kept in the account record.
    @Test func aPasswordChangeOffersTheRotation() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(!m.rotateOffered)
        try await m.changePassword(password, newPassword: newPassword, pin: pin)
        #expect(m.rotateOffered && m.record.value.rotateOffer)
        try phone.restart()
        try await m.refresh()
        #expect(m.rotateOffered, "a restart keeps the offer")
        try await m.rotate(password: newPassword)
        #expect(!m.rotateOffered && !m.record.value.rotateOffer)
    }

    /// A PIN change offers it too; putting it away ends it. A refused change offers nothing.
    @Test func aPinChangeOffersTheRotationUntilItIsPutAway() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await vaultFailure { try await m.changePin(pin: "999999", newPin: "518293", password: password) }?.kind == .badPin)
        #expect(!m.rotateOffered)
        try await m.changePin(pin: pin, newPin: "518293", password: password)
        #expect(m.rotateOffered)
        m.dismissRotateOffer()
        #expect(!m.rotateOffered && !m.record.value.rotateOffer)
    }

    // MARK: - A new credential

    /// The PIN, the current password and the new one: version 1 of a new credential under a new key, the new password
    /// current, the blob kept, and the owner-check clock started afresh.
    @Test func aNewCredentialReplacesTheOldOne() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.rotate(password: password)
        try await m.newCredential(pin: pin, password: password, newPassword: newPassword)
        let seen = try #require(service.resets.first)
        #expect(seen.pin == pin && seen.password == password && seen.newPassword == newPassword)
        #expect(service.vaultCredentialVersion == 1 && service.currentPassword == newPassword)
        #expect(m.session?.device.credentialVersion == 1)
        // The new password opens the new credential.
        try await m.openUnlockWindow(password: newPassword)
    }

    /// A wrong PIN or password is a failed owner check (§3.6.1); nothing is replaced.
    @Test func aWrongPinIsAFailedCheck() async throws {
        defer { phone.close() }
        try await setUp()
        let badPin = await vaultFailure { try await m.newCredential(pin: "999999", password: password, newPassword: newPassword) }
        #expect(badPin?.kind == .badPin)
        let badPassword = await vaultFailure { try await m.newCredential(pin: pin, password: "wrong", newPassword: newPassword) }
        #expect(badPassword?.kind == .badPassword)
        #expect(service.ownerCheckFailures == 2 && service.currentPassword == password)
    }

    // MARK: - The clone alarm

    /// The alarm freezes the credential; "not me" moves it to `rotation_required`, and the rotation resolves it.
    @Test func theAlarmIsAnsweredThenResolvedByTheRotation() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.openUnlockWindow(password: password)
        service.raiseCloneAlarm(presenter: "other")
        #expect(await eventually { m.alarm?.frozen == true })
        #expect(m.alarm?.presenter == "other" && m.unlockWindow == nil)
        #expect(await vaultFailure { try await m.rotate(password: password) }?.kind == .credentialFrozen)
        try await m.confirmAlarm(mine: false)
        #expect(service.alarmConfirms == [false] && service.alarmState == CredentialAlarm.stateRotationRequired)
        #expect(m.alarm?.rotationRequired == true)
        #expect(await vaultFailure { try await m.openUnlockWindow(password: password) }?.kind == .rotationRequired)
        try await m.rotate(password: password)
        #expect(m.alarm == nil && service.alarmState == nil)
        try await m.openUnlockWindow(password: password)
    }

    /// The answer needs an open alarm; it is not a credential operation, so it goes while a change is unresolved.
    @Test func theAnswerNeedsAnOpenAlarm() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await vaultFailure { try await m.confirmAlarm(mine: true) }?.kind == .notFound)
        service.raiseCloneAlarm()
        _ = try await m.status()
        service.loseRequests([VaultApi.typePasswordChange])
        _ = await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: pin) }
        try await m.confirmAlarm(mine: true)
        #expect(service.alarmConfirms == [true] && m.alarm?.rotationRequired == true)
    }
}
