import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Step 1 of VAULT-MESSAGING §11.14.9 "A lost answer" end to end against ``FakeVaultService``, which rotates the blob on
/// the operations vettid-vault rotates it on (the owner check, the name change, the unlock window, the renew and the two
/// changes): an earlier credential operation applied without its answer leaves the vault one version ahead of the phone.
/// A change is sent only once every earlier credential request of the phone is settled (answered, or past its `exp` by
/// more than a minute on the vault's clock; VAULT-MESSAGING 0.46.0 §11.14.9 step 1), waiting for at most 30 s. It then
/// asks `credential.version` under the credential lock (VAULT-MESSAGING 0.47.0 §11.14.9 step 1, "Sent with the vault's
/// current blob"; IOS-PLAN 0.1.6 §6.3): when the version moved, the latest blob is fetched and the change goes with it,
/// so that "version + 1" decides it correctly.
@MainActor
@Suite(.serialized) struct VaultManagerVersionGapTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let newPin = "518293"
    let password = "correct horse battery"
    let newPassword = "a brand new passphrase"

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
        // The opening's reads done (the items are read last), so that the test's requests do not go out among them.
        #expect(await eventually { m.items.load == .loaded })
    }

    var phoneVersion: Int64? { m.session?.device.credentialVersion }

    /// The vault's clock and the phone's, moved together past the earlier request's `exp` by more than a minute: it can no
    /// longer apply, and the change may go.
    func pastExp() {
        let t = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        service.advanceVaultClock(t)
        phone.clockAhead += t
        phone.uptimeAhead += t
    }

    func seen(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    /// The requests that reached the vault since [mark], in order.
    func since(_ mark: Int) -> [String] { Array(service.requestsSeen.dropFirst(mark)) }

    /// An owner check applied by the vault, its answer lost: the vault is a version ahead of the phone.
    func ownerCheckAppliedWithoutAnswer() async throws {
        service.loseAnswers([VaultApi.typeOwnerCheck])
        let r = try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil)
        guard case .failed = r else {
            Issue.record("answered: \(r)")
            return
        }
        service.loseAnswers([])
        #expect(service.vaultCredentialVersion == 2 && phoneVersion == 1)
        // Until it is settled no change goes.
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(f?.kind == .credentialUnsettled && service.pinChanges.isEmpty, "\(String(describing: f))")
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
        pastExp()
    }

    /// The PIN change as decided: the vault holds the new PIN and the phone the record the vault holds.
    func expectPinChanged() throws {
        #expect(service.currentPin == newPin && service.pinFailureCount == 0)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && m.phoneSecrets.currentSecret() == service.currentSecret)
        #expect(try m.phoneSecrets.unresolvedChange() == nil && phoneVersion == service.vaultCredentialVersion)
    }

    /// An owner check applied without its answer, then a PIN change: the version moved, so the latest blob is fetched
    /// before anything is sent, and the change goes with it; its own answer lost, "version + 1" decides it applied, and
    /// it did.
    @Test func anOwnerCheckWithoutItsAnswerThenAPinChange() async throws {
        defer { phone.close() }
        try await setUp()
        try await ownerCheckAppliedWithoutAnswer()
        let mark = service.requestsSeen.count
        service.loseAnswers([VaultApi.typePinChange], from: VaultApi.typePinChange)
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        // The owner check's own resends (the same request) may still arrive meanwhile: only the credential's are looked at.
        let order = since(mark).filter { $0.hasPrefix("credential.") || $0 == VaultApi.typePinChange }
        let firstChange = try #require(order.firstIndex(of: VaultApi.typePinChange))
        let before = Array(order[..<firstChange])
        // The settling's probe of the vault's time and the check that found the version moved, then the fetch; the change
        // goes with the fetched blob, without asking again.
        let get = try #require(before.lastIndex(of: "credential.get"), "\(order)")
        #expect(before.first == "credential.version" && !before[get...].contains("credential.version"), "\(order)")
        #expect(service.pinChanges.count == 1 && m.changeCheck == ChangeCheck(.pin, .applied))
        try expectPinChanged()
        try await m.lock()
        #expect(try await m.unlock(pin: newPin) == .success)
    }

    /// The same after a name change applied without its answer.
    @Test func aNameChangeWithoutItsAnswerThenAPinChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeAccountNameSet])
        _ = await m.profiles.changeName(pin: pin, password: password, firstName: "Ada", lastName: "King")
        #expect(service.vaultCredentialVersion == 2 && phoneVersion == 1)
        service.loseAnswers([])
        pastExp()
        service.loseAnswers([VaultApi.typePinChange], from: VaultApi.typePinChange)
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(service.pinChanges.count == 1 && m.changeCheck == ChangeCheck(.pin, .applied))
        try expectPinChanged()
    }

    /// The same after the unlock window opened without its answer (`credential.unlock` rotates the blob too).
    @Test func anUnlockWindowWithoutItsAnswerThenAPinChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers(["credential.unlock"])
        _ = await vaultFailure { try await m.openUnlockWindow(password: password) }
        #expect(service.vaultCredentialVersion == 2 && phoneVersion == 1)
        service.loseAnswers([])
        pastExp()
        service.loseAnswers([VaultApi.typePinChange], from: VaultApi.typePinChange)
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        try expectPinChanged()
    }

    /// A password change after an owner check applied without its answer: sent with the refreshed blob, decided applied
    /// by the version, and the new password is the vault's.
    @Test func anOwnerCheckWithoutItsAnswerThenAPasswordChange() async throws {
        defer { phone.close() }
        try await setUp()
        try await ownerCheckAppliedWithoutAnswer()
        service.loseAnswers([VaultApi.typePasswordChange], from: VaultApi.typePasswordChange)
        try await m.changePassword(password, newPassword: newPassword, pin: pin)
        #expect(m.changeCheck == ChangeCheck(.password, .applied) && service.passwordChanges.count == 1)
        #expect(service.passwordFailureCount == 0 && phoneVersion == service.vaultCredentialVersion)
        #expect(try await m.ownerChecks.check(pin: pin, password: newPassword, holdOff: nil) == .passed)
    }

    /// A locked vault answers nothing: the question gets no answer, so the change is refused with nothing sent and no
    /// marker kept; after the unlock the vault still holds the PIN, which opens it.
    @Test func aLockedVaultRefusesTheChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(f?.kind == .noResponse, "\(String(describing: f))")
        #expect(service.pinChanges.isEmpty && service.requestsSeen.last != VaultApi.typePinChange)
        #expect(try m.phoneSecrets.unresolvedChange() == nil && m.unlockPinStep == .pin)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.pinChanges.isEmpty && service.currentPin == pin)
    }

    /// No answer to `credential.version` before a password change or a renew: the plain no-answer text, never a "change
    /// pending" one, since nothing was sent (VAULT-MESSAGING 0.47.0 §11.14.9 step 1; the owner's decision of 2026-10-19);
    /// no marker or renew request kept.
    @Test func noAnswerToTheVersionIsThePlainNoAnswerText() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
        let change = await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: pin) }
        #expect(change?.kind == .noResponse, "\(String(describing: change))")
        let renew = await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password) }
        #expect(renew?.kind == .noResponse, "\(String(describing: renew))")
        #expect(service.passwordChanges.isEmpty && service.renews.isEmpty)
        #expect(try m.phoneSecrets.unresolvedChange() == nil && m.changeCheck == nil)
        #expect(try m.phoneSecrets.records().candidates.allSatisfy { $0.sent == nil })
    }

    /// A change waits at most 30 s for a credential operation in flight (here an owner check whose answer does not come),
    /// then is refused with nothing sent; the refusal says an earlier request is unfinished.
    @Test func aChangeWaitsAtMostThirtySeconds() async throws {
        let slow = try TestVaultPhone(service: service, requestTimeout: 2)
        slow.holdsChangeWaits = true
        defer { slow.close() }
        let m = slow.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        service.loseAnswers([VaultApi.typeOwnerCheck])
        let check = Task { try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil) }
        #expect(await eventually { service.ownerChecks.count == 1 })
        let change = Task { await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) } }
        #expect(await eventually { slow.changeWaits.lengths == [30] })
        slow.changeWaits.release()
        let f = await change.value
        #expect(f?.kind == .credentialUnsettled && f?.code == "credential_unsettled")
        #expect(service.pinChanges.isEmpty && service.currentPin == pin)
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
        _ = await check.result
    }

    /// The app killed between the marker and the send (a new manager on the same files), after an earlier operation
    /// moved the version: the marker was stored only after the version was confirmed, on that version, so the restart's
    /// check never reads the earlier operation as this change (VAULT-MESSAGING 0.47.0 §11.14.9 step 1).
    @Test func aRestartBetweenTheMarkerAndTheSendNeverDecidesApplied() async throws {
        defer { phone.close() }
        try await setUp()
        try await ownerCheckAppliedWithoutAnswer()
        // The request never goes out, as when the app is killed right after the marker.
        service.loseRequests([VaultApi.typePinChange])
        let change = Task { await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) } }
        #expect(await eventually { ((try? m.phoneSecrets.unresolvedChange()) ?? nil) != nil })
        let marker = try #require(try m.phoneSecrets.unresolvedChange())
        #expect(marker.version == service.vaultCredentialVersion, "stored on the confirmed version")
        _ = await change.value
        try await phone.restart()
        service.loseRequests([])
        pastExp()
        await m.checkUnresolvedChange(evenLocked: true)
        #expect(m.changeCheck == ChangeCheck(.pin, .notApplied))
        #expect(service.currentPin == pin && service.pinChanges.isEmpty)
    }

    /// The same for a renew: its request is stored on the confirmed version, so after a restart the PIN change decides it
    /// "not applied", never the earlier operation's version as the renew's.
    @Test func aRestartAfterALostRenewNeverDecidesItApplied() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try m.phoneSecrets.currentSecret()
        try await ownerCheckAppliedWithoutAnswer()
        service.loseRequests([VaultApi.typeSecretRenew])
        #expect(await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password) }?.kind == .noResponse)
        let candidate = try #require(try m.phoneSecrets.records().candidates.first)
        #expect(candidate.sent?.version == service.vaultCredentialVersion)
        try await phone.restart()
        try await m.refresh()
        service.loseRequests([])
        pastExp()
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(service.renews.isEmpty && service.currentPin == newPin)
        let now = try m.phoneSecrets.currentSecret()
        #expect(now == service.currentSecret && now != before)
    }

    /// A renew answered `ok`, whose acknowledgement then fails: its record is current all the same (confirmed on its own
    /// answer, before the blob is kept), and nothing is left to decide.
    @Test func aRenewIsConfirmedOnItsOwnOk() async throws {
        defer { phone.close() }
        try await setUp()
        service.failNext("credential.ack")
        _ = await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password) }
        #expect(service.renews.count == 1)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
    }
}
