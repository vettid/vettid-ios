import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// A lost answer to `credential.reset` (VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to `credential.reset`", ANDROID-PLAN
/// 0.1.51 "A lost answer to New credential", IOS-PLAN 0.1.9 §6.3) end to end against ``FakeVaultService``, which drops an
/// expired request unanswered and answers a request it saw already from its response cache, as vettid-vault does. A
/// reset that applied without its answer is decided by the credential key, never sent again, so the phone holds the new
/// credential's blob and its next operation raises no clone alarm.
@MainActor
@Suite(.serialized) struct VaultManagerResetLostAnswerTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let newPassword = "another long passphrase"
    /// Past the reset's `exp` by more than a minute (§11.14.9 step 3).
    let pastExp = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp

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
    }

    func reset() async -> VaultFailure? {
        await vaultFailure { try await m.newCredential(pin: pin, password: password, newPassword: newPassword) }
    }

    func count(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    /// Applied: no marker, the new credential's blob kept, the new password current, no alarm, and the next owner check
    /// (sent with the fetched blob) passes with the new password.
    func expectApplied() async throws {
        #expect(m.changeCheck == ChangeCheck(.reset, .applied))
        #expect(try m.phoneSecrets.unresolvedChange() == nil && m.heldChange == nil)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion)
        #expect(service.resets.count == 1 && service.currentPassword == newPassword)
        #expect(try await m.ownerChecks.check(pin: pin, password: newPassword, holdOff: nil) == .passed)
        #expect(service.alarmState == nil && m.alarm == nil && service.ownerCheckFailures == 0)
    }

    /// The reset's answer lost, from version 1: the vault's version is 1 again, so only the new `key` shows that it applied.
    /// The blob is fetched, acknowledged and UTKs topped up; the reset returns as a success.
    @Test func aLostResetFromVersionOneIsDecidedByTheKey() async throws {
        defer { phone.close() }
        try await setUp()
        let oldKey = service.credentialKey
        service.loseAnswers(["credential.reset"])
        try await m.newCredential(pin: pin, password: password, newPassword: newPassword)
        #expect(service.vaultCredentialVersion == 1 && service.credentialKey != oldKey)
        let after = service.requestsSeen.drop { $0 != "credential.reset" }
        #expect(["credential.get", "credential.ack", "credential.utk.get"].allSatisfy(after.contains))
        try await expectApplied()
    }

    /// From version 2 (the unlock window rotated the CEK): the lower version decides it applied, with the new key.
    @Test func aLostResetIsDecidedByTheLowerVersion() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.openUnlockWindow(password: password)
        #expect(service.vaultCredentialVersion == 2)
        service.loseAnswers(["credential.reset"])
        try await m.newCredential(pin: pin, password: password, newPassword: newPassword)
        try await expectApplied()
    }

    /// The answer and the version's lost: no failure, the reset undecided and its marker stored with the held key. The
    /// resend of the same request within `exp` gets the vault's cached answer: applied, the reset run once.
    @Test func theResendGetsTheCachedAnswer() async throws {
        defer { phone.close() }
        try await setUp()
        let oldKey = service.credentialKey
        service.loseAnswers(["credential.reset", "credential.version"], from: "credential.reset")
        let f = await reset()
        #expect(f?.kind == .changeUnresolved && f?.code == VaultManager.codeChangeUnresolved)
        #expect(m.changeCheck == ChangeCheck(.reset, .unreachable))
        let marker = try #require(try m.phoneSecrets.unresolvedChange())
        #expect(marker.type == .reset && marker.version == 1 && marker.heldKey == oldKey && marker.id == m.heldChange?.id)
        #expect(service.resets.count == 1)
        let sent = count("credential.reset")
        service.loseAnswers([])
        await m.checkUnresolvedChange()
        #expect(count("credential.reset") == sent + 1, "the same request once more")
        try await expectApplied()
    }

    /// The request never reached the vault: the same key and version before `exp` is undecided (still checking); once the
    /// vault's clock is past `exp` by more than a minute the expired resend is dropped and the same key and version
    /// decide it not applied. The old password is still the credential's.
    @Test func aResetThatNeverArrivedIsNotApplied() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["credential.reset"])
        #expect(await reset()?.kind == .changeUnresolved)
        #expect(m.changeCheck == ChangeCheck(.reset, .checking))
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.reset, .checking))
        service.advanceVaultClock(pastExp)
        phone.clockAhead = pastExp
        service.loseRequests([])
        await m.checkUnresolvedChange()
        #expect(m.changeCheck == ChangeCheck(.reset, .notApplied))
        #expect(try m.phoneSecrets.unresolvedChange() == nil && service.resets.isEmpty && service.currentPassword == password)
        #expect(try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil) == .passed)
    }

    /// While the reset is undecided every other credential operation is refused at once with the reset's "still
    /// checking" text, nothing sent; the unlock is not affected (a reset changes neither the PIN nor the phone secret).
    @Test func theGateRefusesEveryOtherOperation() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["credential.reset"])
        _ = await reset()
        let before = service.requestsSeen.count
        let kind = FailureKind.changeCheckingReset
        let check = try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil)
        #expect(check == .failed(kind, code: VaultManager.codeChangeChecking))
        #expect(await vaultFailure { try await m.rotate(password: password) }?.kind == kind)
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: pin) }?.kind == kind)
        #expect(await vaultFailure { try await m.openUnlockWindow(password: password) }?.kind == kind)
        #expect(await reset()?.kind == kind)
        let after = Set(service.requestsSeen.dropFirst(before))
        #expect(after.isSubset(of: ["credential.version", "credential.reset"]), "only the checks: \(after)")
        #expect(kind.message != FailureKind.changeCheckingPassword.message)
        try await m.lock()
        #expect(m.unlockPinStep == .pin)
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// The version pre-check: an earlier operation moved the vault's blob without its answer. The latest blob is fetched
    /// and the reset goes with it, so the vault applies it (no `stale_credential`, no alarm).
    @Test func thePreCheckSendsWithTheVaultsBlob() async throws {
        defer { phone.close() }
        try await setUp()
        service.moveCredentialWithoutTheApp()
        try await m.newCredential(pin: pin, password: password, newPassword: newPassword)
        #expect(service.resets.count == 1 && service.currentPassword == newPassword && service.alarmState == nil)
        #expect(m.session?.device.credentialVersion == 1 && m.changeCheck == nil)
    }

    /// A pre-check answer without a `key` refuses the reset with nothing sent and nothing stored ("earlier request").
    @Test func aPreCheckWithoutAKeySendsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        service.versionWithoutKey = true
        #expect(await reset()?.kind == .credentialUnsettled)
        #expect(count("credential.reset") == 0 && service.resets.isEmpty)
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
    }

    /// `stale_credential` to the reset itself: not applied, the latest blob fetched and the typed secrets not sent again;
    /// a new try goes with the latest blob.
    @Test func aStaleResetIsNotRetried() async throws {
        defer { phone.close() }
        try await setUp()
        service.moveCredential(on: "credential.reset")
        let f = await reset()
        #expect(f?.code == VaultManager.codeChangeNotApplied)
        #expect(service.resets.count == 1 && service.currentPassword == password && service.ownerCheckFailures == 0)
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion, "the latest blob kept")
        try await m.newCredential(pin: pin, password: password, newPassword: newPassword)
        #expect(service.resets.count == 2 && service.currentPassword == newPassword)
    }

    /// A restart while undecided: the marker and its held key survive (the request does not); the start decides by the
    /// key alone, with no second reset.
    @Test func aRestartWhileUndecided() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers(["credential.reset", "credential.version"], from: "credential.reset")
        _ = await reset()
        let sent = count("credential.reset")
        try phone.restart()
        #expect(try m.phoneSecrets.unresolvedChange()?.type == .reset && m.heldChange == nil)
        service.loseAnswers([])
        try await m.refresh()
        #expect(await eventually { m.changeCheck == ChangeCheck(.reset, .applied) })
        #expect(count("credential.reset") == sent)
        try await expectApplied()
    }

    /// The reset's marker round-trips in the records file with its held key.
    @Test func theMarkerKeepsTheHeldKey() throws {
        let marker = UnresolvedChange(
            type: .reset, id: "01J000", version: 3, exp: Date(timeIntervalSince1970: 1_800_000_000), heldKey: "ck-1"
        )
        let recs = PhoneRecords(unresolved: marker)
        #expect(try PhoneRecords.parse(recs.marshal()).unresolved == marker)
        #expect(try PhoneRecords.parse(recs.marshal()).unresolved?.heldKey == "ck-1")
    }
}
