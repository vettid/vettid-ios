import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Settings end to end against ``FakeVaultService``, which answers as vettid-vault does: the account snapshot and the
/// name change (VAULT-MESSAGING §10.2, §10.8, §11.13), the credential screen (§3.5, §10.6, §10.8) and the PIN change of
/// release R with the phone's next secret (§11.14.9, IOS-PLAN §6.3). Mirrors the parts of vettid-android's
/// `VaultManager` tests and `ProfileManagerTest` that these operations have.
@MainActor
@Suite(.serialized) struct VaultManagerSettingsTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

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

    static let snapshot = #"{"v":1,"as_of":"2026-10-18T10:00:00Z","email_hint":"m***@example.com","email":"member@example.com","state":"member","account_status":"active","first_name":"Ada","last_name":"Lovelace","name_change":{"allowed_after":null}}"#

    // MARK: - The account and its names

    /// The vault opening reads the account; `account.changed` reads it again; the snapshot is kept in memory only
    /// (IOS-PLAN §4.7), and read again after a restart.
    @Test func theAccountIsReadWhenTheVaultOpensAndWhenItChanges() async throws {
        defer { phone.close() }
        service.accountSnapshot(Self.snapshot)
        try await setUp()
        #expect(await eventually { m.account?.fullName == "Ada Lovelace" })
        #expect(m.account?.email == "member@example.com" && m.account?.state == "member")
        service.accountSnapshot(Self.snapshot.replacingOccurrences(of: "10:00:00Z", with: "11:00:00Z").replacingOccurrences(of: "Lovelace", with: "King"))
        #expect(await eventually { m.account?.lastName == "King" })
        try await phone.restart()
        #expect(m.account?.fullName == nil, "nothing of it on the phone")
        try await m.refresh()
        // The vault is still open: the start reads the account from it again.
        #expect(m.phase == .unlocked)
        #expect(await eventually { m.account?.fullName == "Ada King" })
    }

    /// The name change: the PIN, the password and the normalised names, checked as an owner check; the pending request is
    /// kept with the account at once; VettID's result arrives with `account.changed` (the version repeated, 0.19.0).
    @Test func aNameChangeIsRequestedAndItsResultArrives() async throws {
        defer { phone.close() }
        service.accountSnapshot(Self.snapshot)
        try await setUp()
        #expect(await eventually { m.account?.fullName != nil })
        let before = service.vaultCredentialVersion
        let r = await m.profiles.changeName(pin: pin, password: password, firstName: " Ada ", lastName: "King")
        guard case .requested(let request) = r else {
            Issue.record("not requested: \(r)")
            return
        }
        let sent = try #require(service.nameSets.last)
        #expect(sent.pin == pin && sent.password == password && sent.firstName == "Ada" && sent.lastName == "King")
        #expect(service.vaultCredentialVersion == before + 1, "the CEK rotated")
        #expect(request.state == .pending && m.account?.nameRequest?.seq == request.seq)
        service.settleNameRequest("applied")
        #expect(await eventually { m.account?.nameRequest?.state == .applied })
    }

    /// A wrong PIN is a failed owner check with the checks left; `too_soon` says when; names that break the rule are not
    /// sent.
    @Test func aNameChangeIsRefusedAsTheVaultSays() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await m.profiles.changeName(pin: "111111", password: password, firstName: "Ada", lastName: "King") == .badPin(checksLeft: 9))
        #expect(await m.profiles.changeName(pin: pin, password: "wrong", firstName: "Ada", lastName: "King") == .badPassword(checksLeft: 8))
        let after = Date().addingTimeInterval(86_400 * 3)
        service.nameChangeAllowedAfter(after)
        guard case .tooSoon(let at?) = await m.profiles.changeName(pin: pin, password: password, firstName: "Ada", lastName: "King") else {
            Issue.record("not too soon")
            return
        }
        #expect(abs(at.timeIntervalSince(after)) < 1)
        let sets = service.nameSets.count
        #expect(await m.profiles.changeName(pin: pin, password: password, firstName: "Ada1", lastName: "King") == .invalid)
        #expect(service.nameSets.count == sets)
        #expect(m.account?.nameRequest == nil)
    }

    // MARK: - The credential screen

    /// `credential.version`, the settings and the critical items counted; the backup and the window's length set; the
    /// unlock window opened with the password and closed.
    @Test func theCredentialScreensOperations() async throws {
        defer { phone.close() }
        try await setUp()
        service.criticalItems = 3
        var st = try await m.status()
        #expect(st.exists && st.version == service.vaultCredentialVersion && st.keyFingerprint == String(FakeVaultService.credentialKeyID.prefix(12)))
        #expect(st.backup && st.unlockTtlSeconds == 300 && st.criticalItems == 3 && st.alarm == nil)
        try await m.setBackup(false)
        try await m.setUnlockTtl(seconds: 900)
        #expect(!service.backupSetting && service.unlockTtlSetting == 900)
        st = try await m.status()
        #expect(!st.backup && st.unlockTtlSeconds == 900)
        #expect(await vaultFailure { try await m.setUnlockTtl(seconds: 10) } != nil)
        try await m.openUnlockWindow(password: password)
        let until = try #require(m.unlockWindow)
        #expect(until > Date().addingTimeInterval(800))
        try await m.closeUnlockWindow()
        #expect(m.unlockWindow == nil)
        #expect(await vaultFailure { try await m.openUnlockWindow(password: "wrong") }?.code == "bad_password")
    }

    /// The password change of release R carries the PIN (§11.14.9); the vault then checks the new password.
    @Test func aPasswordChangeCarriesThePin() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin)
        let sent = try #require(service.passwordChanges.last)
        #expect(sent.pin == pin && sent.password == password && sent.newPassword == "a brand new passphrase")
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "x", pin: pin) }?.code == "bad_password")
        service.refusePassword("common")
        let weak = await vaultFailure { try await m.changePassword("a brand new passphrase", newPassword: "password1", pin: pin) }
        #expect(weak?.kind == .weakPassword && weak?.weakPasswordReason == "common")
    }

    // MARK: - The PIN (release R)

    /// `pin.change` with the password and the next epoch's secret (§11.14.9): on `epoch_advanced` the phone's record
    /// moves to the next epoch, and the next unlock carries the new PIN and the new secret.
    @Test func aPinChangeMovesThePhoneToTheNextEpoch() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(try m.phoneSecrets.current()).epoch
        try await m.changePin(pin: pin, newPin: "518293", password: password)
        let sent = try #require(service.pinChanges.last)
        #expect(sent.pin == pin && sent.newPin == "518293" && sent.password == password)
        #expect(try m.phoneSecrets.current()?.epoch == before + 1)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
        try await m.lock()
        #expect(try await m.unlock(pin: "518293") == .success)
        #expect(service.unlocks.last?.unlockSecret == service.currentSecret)
    }

    /// A wrong PIN changes nothing on the vault; the retry reuses the same next-epoch record (IOS-PLAN §6.3 item 2),
    /// so no second candidate is made.
    @Test func aRetryReusesTheNextEpochsRecord() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await vaultFailure { try await m.changePin(pin: "111111", newPin: "518293", password: password) }?.code == "bad_pin")
        #expect(try m.phoneSecrets.records().candidates.count == 1)
        try await m.changePin(pin: pin, newPin: "518293", password: password)
        #expect(service.pinChanges.count == 2 && service.pinChanges[0].newUnlockSecret == service.pinChanges[1].newUnlockSecret)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && service.currentPin == "518293")
    }

    /// Without `epoch_advanced` the record stays a candidate; the next unlock decides.
    @Test func noEpochAdvancedLeavesACandidate() async throws {
        defer { phone.close() }
        try await setUp()
        service.epochAdvanced = false
        let before = try #require(try m.phoneSecrets.current()).epoch
        try await m.changePin(pin: pin, newPin: "518293", password: password)
        #expect(try m.phoneSecrets.current()?.epoch == before && m.phoneSecrets.records().candidates.count == 1)
        try await m.lock()
        #expect(try await m.unlock(pin: "518293") == .success)
        #expect(try m.phoneSecrets.current()?.epoch == before + 1 && m.phoneSecrets.records().candidates.isEmpty)
    }

    /// A record that cannot be made current after `epoch_advanced` is still a success; the next unlock confirms it.
    @Test func aConfirmThatCannotBeWrittenIsStillASuccess() async throws {
        defer { phone.close() }
        try await setUp()
        m.confirmPinChangeOverride = { _ in throw VaultFailure(.localState) }
        try await m.changePin(pin: pin, newPin: "518293", password: password)
        #expect(try m.phoneSecrets.records().candidates.count == 1 && m.pinChangeOperation == nil)
        try await m.lock()
        #expect(try await m.unlock(pin: "518293") == .success)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
    }

    /// While a change is on its way, a second one is refused before anything is sent.
    @Test func aSecondChangeWhileOneIsOnItsWayIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        service.answerPinChange = false
        let first = Task { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        #expect(await eventually { m.pinChangeOperation.map { m.phoneSecrets.inFlight(operation: $0) } == true })
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }?.kind == .busy)
        _ = await first.result
        #expect(service.pinChanges.count == 1)
    }

    /// A fifth change while four are unconfirmed is refused before anything is sent (IOS-PLAN §6.3), and no candidate goes.
    @Test func aFifthUnconfirmedChangeIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        service.epochAdvanced = false
        let pins = [pin, "518293", "640213", "731524", "842635", "953746"]
        for i in 0..<4 {
            m.pinChangeOperation = nil
            try await m.changePin(pin: pins[i], newPin: pins[i + 1], password: password)
        }
        m.pinChangeOperation = nil
        let refused = await vaultFailure { try await m.changePin(pin: pins[4], newPin: pins[5], password: password) }
        #expect(refused?.kind == .unconfirmedChanges)
        #expect(try service.pinChanges.count == 4 && m.phoneSecrets.records().candidates.count == 4)
    }

    /// The password change without the PIN is not the iPhone app's (IOS-PLAN ID8).
    @Test func thePasswordChangeNeedsThePin() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "x y z w", pin: nil) }?.kind == .notSupported)
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "x y z w") }?.kind == .notSupported)
    }

    /// A wipe forgets the snapshot and the name request with the rest.
    @Test func aWipeErasesTheAccount() async throws {
        defer { phone.close() }
        service.accountSnapshot(Self.snapshot)
        try await setUp()
        _ = await m.profiles.changeName(pin: pin, password: password, firstName: "Ada", lastName: "King")
        #expect(await eventually { m.account?.fullName != nil && m.account?.nameRequest != nil })
        try await m.lock()
        service.unlockAnswers(.sealed("unknown_device"))
        _ = try await m.unlock(pin: pin)
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.account == nil && m.ownAccount.snapshot == nil && m.ownAccount.nameRequest == nil)
    }

    /// The PIN change before release R is not the iPhone app's (IOS-PLAN ID8).
    @Test func thePinChangeBeforeReleaseRIsNotSupported() async throws {
        defer { phone.close() }
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: "518293") }?.kind == .notSupported)
    }
}

// swiftlint:enable line_length
