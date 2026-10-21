import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// New phone secret (`vault.secret.renew`, VAULT-MESSAGING §11.14.9; IOS-PLAN §6.3) end to end against
/// ``FakeVaultService``, which answers it as vettid-vault does. A lost answer follows §6.3's rules for a renew (the record
/// kept as a candidate, a retry with the same secret, an unlock that tries it), not the decision of §11.14.9 "A lost
/// answer", which a renew MAY use and need not; its candidate is tried with the previous PIN while a PIN change is
/// unresolved (step 5, 0.45.0). Mirrors vettid-android's `renewPhoneSecret` tests.
@MainActor
@Suite(.serialized) struct VaultManagerRenewTests {
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

    func renew(password: String? = nil) async -> VaultFailure? {
        await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password ?? self.password) }
    }

    /// The vault stores the next epoch's secret with the PIN unchanged; the answer makes it current and the earlier one a
    /// replaced record; the vault opens with the same PIN and the new secret.
    @Test func aNewSecretIsMadeAndOpensTheVault() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(try m.phoneSecrets.current())
        #expect(await renew() == nil)
        let sent = try #require(service.renews.first)
        #expect(sent.pin == pin && sent.password == password && sent.newUnlockSecret.count == 32)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && service.currentPin == pin)
        #expect(try m.phoneSecrets.current()?.epoch == before.epoch + 1)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && m.phoneSecrets.records().replaced.map(\.entry.record) == [before])
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion, "the rotated blob kept")
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// The answer lost after the vault stored the secret: not a success, the record kept as a candidate; the next unlock
    /// gets `device_secret` with the current record, tries the candidate and makes it current. No PIN attempt counted.
    @Test func aLostAnswerThenAnUnlockConfirmsTheCandidate() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(try m.phoneSecrets.current())
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        #expect(try m.phoneSecrets.current() == before && m.phoneSecrets.records().candidates.count == 1)
        service.loseAnswers([])
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
        #expect(service.pinFailureCount == 0 && service.renews.count == 1)
    }

    /// The answer lost, then the member tries again: the retry sends the same secret (IOS-PLAN §6.3 item 2). The version
    /// asked first shows the blob the lost renew left: it is fetched before anything is sent (VAULT-MESSAGING 0.47.0
    /// §11.14.9 step 1), and the record becomes current.
    @Test func aLostAnswerThenARetrySendsTheSameSecret() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers([])
        // Until the lost one is settled, the retry is refused with nothing sent (renews settle too).
        #expect(await renew()?.kind == .credentialUnsettled && service.renews.count == 1)
        pastExp()
        #expect(await renew() == nil)
        let secrets = Set(service.renews.map(\.newUnlockSecret))
        #expect(secrets.count == 1 && service.renews.count == 2, "the lost one, the retry with the latest blob")
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
        #expect(service.pinFailureCount == 0 && service.passwordFailureCount == 0)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// A refusal (a wrong password) changes nothing and keeps the record for the retry, which sends the same secret.
    @Test func aRefusalKeepsTheRecordForTheRetry() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await renew(password: "wrong")?.kind == .badPassword)
        #expect(try m.phoneSecrets.records().candidates.count == 1)
        #expect(await renew() == nil)
        #expect(service.renews.count == 2 && service.renews[0].newUnlockSecret == service.renews[1].newUnlockSecret)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && m.phoneSecrets.currentSecret() == service.currentSecret)
    }

    /// A renew is a credential operation (§11.14.9 step 2): refused before anything is sent while a PIN change is
    /// unresolved; refused on a phone without a phone secret.
    @Test func aRenewWaitsForAnUnresolvedChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests(["pin.change"])
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(await renew()?.kind == .changeChecking)
        #expect(service.renews.isEmpty)
    }

    /// The earlier-secret step's prompt (IOS-PLAN §6.3 item 5): set by the step, ended by a new secret or by the member.
    @Test func thePromptEndsWithANewSecretOrWhenDismissed() async throws {
        defer { phone.close() }
        try await setUp()
        m.earlierSecretRestored()
        #expect(m.renewSecretSuggested)
        m.dismissRenewSuggestion()
        #expect(!m.renewSecretSuggested)
        m.earlierSecretRestored()
        #expect(await renew() == nil)
        #expect(!m.renewSecretSuggested)
    }

    /// A renew's answer lost: until it is settled a PIN change is refused with nothing sent ("earlier request"); once the
    /// vault's clock is past its `exp` by more than a minute, `credential.version` one above the version it carried
    /// decides it applied: its record is made current, and the PIN change goes (VAULT-MESSAGING 0.46.0 §11.14.9 step 1).
    @Test func aLostRenewIsDecidedBeforeAPinChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers([])
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(f?.kind == .credentialUnsettled && service.pinChanges.isEmpty)
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
        pastExp()
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(service.currentPin == newPin && service.pinFailureCount == 0 && service.pinChanges.count == 1)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
        try await m.lock()
        #expect(try await m.unlock(pin: newPin) == .success)
    }

    /// A renew that never reached the vault: past its `exp`, the same version decides it not applied, and the PIN change
    /// goes; the renew's record stays a candidate until an unlock replaces it.
    @Test func aRenewThatNeverArrivedIsDecidedNotApplied() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try m.phoneSecrets.currentSecret()
        service.loseRequests([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseRequests([])
        pastExp()
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(service.renews.isEmpty && service.currentPin == newPin)
        let now = try m.phoneSecrets.currentSecret()
        #expect(now == service.currentSecret && service.currentSecret != before)
    }

    /// The version cannot decide the renew (the blob moved for something else as well): the PIN change is refused with
    /// nothing sent, and a lock and unlock with the same PIN settles it at no cost; the PIN change goes then.
    @Test func anUndecidableRenewIsSettledByALockAndUnlock() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers([])
        service.moveCredentialWithoutTheApp()
        pastExp()
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(f?.kind == .renewUnconfirmed && f?.code == VaultManager.codeRenewUnconfirmed && service.pinChanges.isEmpty)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try service.pinFailureCount == 0 && m.phoneSecrets.records().candidates.isEmpty)
        try await m.changePin(pin: pin, newPin: newPin, password: password)
        #expect(try service.currentPin == newPin && m.phoneSecrets.currentSecret() == service.currentSecret)
    }

    /// A renew candidate left from before 0.46.0 (no request stored with it) is the fallback of step 5: with a PIN change
    /// applied and its answers lost, the previous PIN gets `device_secret` with the current record and with the renew's;
    /// only then is the new PIN asked for, which opens with the change's record.
    @Test func anOldRenewCandidateIsTriedWithThePreviousPinFirst() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        let renewOp = try #require(try m.phoneSecrets.records().candidates.first?.operation)
        try m.phoneSecrets.clearSent(operation: renewOp)
        pastExp()
        service.loseAnswers(["pin.change", "credential.version"], from: "pin.change")
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }?.kind == .changeUnresolved)
        #expect(service.currentPin == newPin)
        try await m.lock()
        service.loseAnswers([])
        let before = service.unlocks.count
        #expect(try await m.unlock(pin: pin) == .newPinNeeded)
        #expect(service.unlocks.count - before == 2 && service.pinFailureCount == 0, "the current record, then the renew's")
        #expect(try await m.unlock(pin: newPin) == .success)
        #expect(await eventually { m.changeCheck == ChangeCheck(.pin, .applied) })
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret)
    }

    /// VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13 §6.3: a renew that never arrived is being decided before a PIN change, and the
    /// vault answers its `credential.version` `forbidden` (another phone is the holder): the renew's candidate goes, the
    /// PIN change is refused with "Your vault moved to a new phone" and nothing of it is sent. The candidate shares the
    /// current record's phone key, which stays (only keys no record names are deleted): the vault opens with the same PIN.
    @Test func forbiddenWhileDecidingARenewDropsOnlyItsCandidate() async throws {
        defer { phone.close() }
        try await setUp()
        let current = try #require(try m.phoneSecrets.current())
        let keys = phone.phoneKeys.count
        service.loseRequests([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseRequests([])
        #expect(try m.phoneSecrets.records().candidates.count == 1)
        pastExp()
        // Every `credential.version` is refused, as a vault whose holder is another phone refuses them (the settle's time
        // probe included, which only reads the vault's clock).
        service.refuse("credential.version", with: VaultManager.codeNotHolder)
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(f?.kind == .notHolder && f?.code == VaultManager.codeNotHolder, "\(String(describing: f))")
        #expect(m.changeCheck == ChangeCheck(.pin, .notHolder) && service.pinChanges.isEmpty && service.renews.isEmpty)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && m.phoneSecrets.uncertainPin() == nil)
        #expect(try m.phoneSecrets.current() == current && phone.phoneKeys.count == keys, "nothing erased")
        #expect(!m.credentialRequired && m.phase == .unlocked)
        // The fake answers `credential.version` again: the vault opens with the current record.
        service.refuse("credential.version", with: VaultManager.codeNotHolder, times: 0)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.pinFailureCount == 0)
    }

    /// The renew's own request answered `forbidden` (IOS-PLAN §4.4 (3)): "Your vault moved to a new phone". A refusal, so it
    /// did not apply (VAULT-MESSAGING 0.47.0 §11.14.9 step 1): its record stays a candidate for a retry with nothing left
    /// to decide (no request stored with it), no change ends, the current record and its phone key stay, and the vault
    /// opens with the same PIN.
    @Test func theRenewsOwnForbiddenIsShownAsAnotherHolder() async throws {
        defer { phone.close() }
        try await setUp()
        let current = try #require(try m.phoneSecrets.current())
        let keys = phone.phoneKeys.count
        service.refuseNext(VaultApi.typeSecretRenew, code: VaultManager.codeNotHolder)
        let f = await renew()
        #expect(f?.kind == .notHolder && f?.code == VaultManager.codeNotHolder, "\(String(describing: f))")
        let candidates = try m.phoneSecrets.records().candidates
        #expect(candidates.count == 1 && candidates.first?.sent == nil, "the record kept for a retry, nothing to decide")
        #expect(try m.phoneSecrets.current() == current)
        #expect(phone.phoneKeys.count == keys && m.changeCheck == nil && !m.credentialRequired)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    // MARK: - A renew waiting in a locked vault (chosen; not in the spec)

    /// The vault's clock and the phone's, moved together past a request's `exp` by more than a minute (each call once more).
    func pastExp() {
        let t = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        service.advanceVaultClock(t)
        phone.clockAhead += t
        phone.uptimeAhead += t
    }

    /// The vault locked behind the app's back just before the renew reached it; the renew waits in its mailbox, unanswered. The unlock's `ok` with the
    /// current record comes before `exp`: the record stays a candidate, because the waiting copy applies after that
    /// unlock. The next unlock gets `device_secret`, tries the candidate, and opens: never "this phone no longer holds the
    /// keys".
    @Test func aRenewWaitingInALockedVaultIsKeptUntilItsExp() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(on: VaultApi.typeSecretRenew)
        #expect(await renew()?.kind == .noResponse)
        let candidate = try #require(try m.phoneSecrets.records().candidates.first)
        #expect(candidate.exp != nil && service.renews.isEmpty)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.renews.count == 1, "the waiting copy applied after the unlock")
        #expect(try m.phoneSecrets.records().candidates.map(\.operation) == [candidate.operation], "kept")
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
    }

    /// The same past the renew's `exp`: the vault drops the waiting copy unanswered, and the unlock's `ok` makes the
    /// candidate a replaced record.
    @Test func aRenewWaitingPastItsExpNeverApplies() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try m.phoneSecrets.currentSecret()
        service.lockByItself(on: VaultApi.typeSecretRenew)
        #expect(await renew()?.kind == .noResponse)
        let candidate = try #require(try m.phoneSecrets.records().candidates.first)
        pastExp()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.renews.isEmpty && service.currentSecret == before)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
        #expect(try m.phoneSecrets.records().replaced.contains { $0.operation == candidate.operation })
    }

    // MARK: - In flight, restarts and the cap

    /// A renew on its way: a PIN change and a password change are each refused at once (busy), nothing of theirs sent,
    /// so that neither reads a blob the renew is about to move.
    @Test func aRenewInFlightRefusesAPinChangeAndAPasswordChange() async throws {
        // Long waits for the answers, so that the renew is still on its way while the changes are tried: it waits,
        // unanswered, in the mailbox of a vault that locked just before it arrived.
        let slow = try TestVaultPhone(service: service, requestTimeout: 1)
        defer { slow.close() }
        let m = slow.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        service.lockByItself(on: VaultApi.typeSecretRenew)
        let renewing = Task { await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password) } }
        #expect(await eventually { m.phoneSecrets.anyInFlight })
        let seen = service.requestsSeen.count
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }?.kind == .busy)
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin) }?.kind == .busy)
        let asked = service.requestsSeen.dropFirst(seen)
        #expect(!asked.contains(VaultApi.typePinChange) && !asked.contains(VaultApi.typePasswordChange), "nothing of theirs sent")
        #expect(await renewing.value?.kind == .noResponse)
        #expect(service.pinChanges.isEmpty && service.passwordChanges.isEmpty)
    }

    /// A crash after the record was written and before the request went: a harmless candidate. It is kept until a minute
    /// past its `exp` (nothing tells the phone it was never sent), then the unlock's `ok` replaces it.
    @Test func aCrashBeforeTheSendLeavesAHarmlessCandidate() async throws {
        defer { phone.close() }
        try await setUp()
        let exp = try #require(m.session?.device.vaultNow()).addingTimeInterval(ChangeRequest.validFor)
        _ = try m.phoneSecrets.beginChange(operation: "vault.secret.renew-crash", exp: exp)
        m.phoneSecrets.endChange(operation: "vault.secret.renew-crash")
        try await phone.restart()
        try await m.refresh()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try m.phoneSecrets.records().candidates.count == 1)
        pastExp()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(try m.phoneSecrets.records().candidates.isEmpty && service.renews.isEmpty)
    }

    /// Two renews, the first answer lost, with a restart between them (IOS-PLAN §8 I1.4): the second is a new operation
    /// and a new record; its answer makes it current, the first a replaced record; the vault opens.
    @Test func twoRenewsWithTheFirstAnswerLostAcrossARestart() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        let first = try #require(try m.phoneSecrets.records().candidates.first)
        service.loseAnswers([])
        try await phone.restart()
        try await m.refresh()
        pastExp()
        #expect(await renew() == nil)
        #expect(Set(service.renews.map(\.newUnlockSecret)).count == 2)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
        #expect(try m.phoneSecrets.records().replaced.contains { $0.operation == first.operation })
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// The renew's own `stale_credential` (the blob moved between the version's answer and the renew): not applied and
    /// not retried, the latest blob fetched, no attempt counted, shown with the "earlier request" text (VAULT-MESSAGING
    /// 0.47.0 §11.14.9 step 1); the next renew goes through with the same record.
    @Test func theRenewsOwnStaleCredentialIsNotApplied() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try m.phoneSecrets.currentSecret()
        service.moveCredential(on: VaultApi.typeSecretRenew)
        let f = await renew()
        #expect(f?.kind == .credentialUnsettled && f?.code == VaultFailures.codeCredentialUnsettled, "\(String(describing: f))")
        #expect(service.pinFailureCount == 0 && service.renews.count <= 1)
        #expect(try m.phoneSecrets.currentSecret() == before)
        #expect(try m.phoneSecrets.records().candidates.allSatisfy { $0.sent == nil }, "nothing left to decide")
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion)
        #expect(await renew() == nil)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret)
    }

    /// Four renews that never arrived, each after a restart (a new operation): the fifth is refused before anything is made
    /// or sent ("Unlock your vault first"), and no candidate is dropped.
    @Test func theFourCandidateCapThroughRenews() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typeSecretRenew])
        for _ in 0..<4 {
            #expect(await renew()?.kind == .noResponse)
            try await phone.restart()
            try await m.refresh()
            pastExp()
        }
        let candidates = try m.phoneSecrets.records().candidates
        #expect(candidates.count == 4)
        #expect(await renew()?.kind == .unconfirmedChanges)
        #expect(try m.phoneSecrets.records().candidates == candidates && service.renews.isEmpty)
    }
}
