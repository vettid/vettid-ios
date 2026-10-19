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
        phone = try TestVaultPhone(service: service, requestTimeout: 0.4)
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

    /// The answer lost, then the member tries again: the retry sends the same secret (IOS-PLAN §6.3 item 2); the vault,
    /// which holds it already, answers after the blob is fetched (`stale_credential`, then the generic retry that spends
    /// nothing), and the record becomes current.
    @Test func aLostAnswerThenARetrySendsTheSameSecret() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers([])
        #expect(await renew() == nil)
        let secrets = Set(service.renews.map(\.newUnlockSecret))
        #expect(secrets.count == 1 && service.renews.count == 3, "the lost one, the stale blob's refusal, the retry")
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

    /// A renew's answer lost (the vault holds its secret and a newer blob), then a PIN change whose request does not
    /// arrive. The change carries the latest blob, fetched first, so that the version decides it and not the renew. With
    /// the vault locked, the unlock asks for the previous PIN: `device_secret` with the current record, then the renew's
    /// candidate with the same PIN opens the vault (§11.14.9 step 5, 0.45.0), never the new PIN. The change's candidate
    /// stays one: the resend after the unlock applies it, the check decides it applied, and the new PIN opens.
    @Test func aLostRenewIsTriedWithThePreviousPinBeforeTheNewOne() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers([])
        service.loseRequests(["pin.change"])
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }?.kind == .changeUnresolved)
        #expect(try m.phoneSecrets.unresolvedChange()?.version == service.vaultCredentialVersion, "the renew's blob fetched first")
        try await m.lock()
        service.loseRequests([])
        #expect(m.unlockPinStep == .previous)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.unlocks.allSatisfy { $0.pin == pin } && service.pinFailureCount == 0)
        #expect(await eventually { m.changeCheck == ChangeCheck(.pin, .applied) })
        #expect(try service.currentPin == newPin && m.phoneSecrets.currentSecret() == service.currentSecret)
        try await m.lock()
        #expect(try await m.unlock(pin: newPin) == .success)
    }

    /// The same with the PIN change applied (its answers lost): the previous PIN gets `device_secret` with the current
    /// record and with the renew's; only then is the new PIN asked for, which opens with the change's record.
    @Test func aLostRenewAndAnAppliedPinChangeAskForTheNewPinLast() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseAnswers([VaultApi.typeSecretRenew])
        #expect(await renew()?.kind == .noResponse)
        service.loseAnswers(["pin.change", "credential.version"])
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

    // MARK: - A renew waiting in a locked vault (chosen; not in the spec)

    /// The vault's clock and the phone's, moved together past a request's `exp` by more than a minute.
    func pastExp() {
        let t = ChangeRequest.validFor + 2 * VaultManager.decidedAfterExp
        service.advanceVaultClock(t)
        phone.clockAhead = t
        phone.uptimeAhead = t
    }

    /// The vault locked behind the app's back; the renew waits in its mailbox, unanswered. The unlock's `ok` with the
    /// current record comes before `exp`: the record stays a candidate, because the waiting copy applies after that
    /// unlock. The next unlock gets `device_secret`, tries the candidate, and opens: never "this phone no longer holds the
    /// keys".
    @Test func aRenewWaitingInALockedVaultIsKeptUntilItsExp() async throws {
        defer { phone.close() }
        try await setUp()
        service.lockByItself(reason: "test")
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
        service.lockByItself(reason: "test")
        #expect(await renew()?.kind == .noResponse)
        let candidate = try #require(try m.phoneSecrets.records().candidates.first)
        pastExp()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.renews.isEmpty && service.currentSecret == before)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
        #expect(try m.phoneSecrets.records().replaced.contains { $0.operation == candidate.operation })
    }

    // MARK: - In flight, restarts and the cap

    /// A renew on its way: a PIN change and a password change are each refused at once (busy), nothing asked of the
    /// vault, so that neither reads a blob the renew is about to move; once it is answered, the password change goes with
    /// the blob the renew left.
    @Test func aRenewInFlightRefusesAPinChangeAndAPasswordChange() async throws {
        defer { phone.close() }
        try await setUp()
        service.holdMessages = true
        let renewing = Task { await renew() }
        #expect(await eventually { service.renews.count == 1 })
        let seen = service.requestsSeen.count
        #expect(await vaultFailure { try await m.changePin(pin: pin, newPin: newPin, password: password) }?.kind == .busy)
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin) }?.kind == .busy)
        #expect(service.requestsSeen.count == seen, "nothing asked of the vault")
        service.holdMessages = false
        #expect(await renewing.value == nil)
        #expect(await vaultFailure { try await m.changePassword(password, newPassword: "a brand new passphrase", pin: pin) } == nil)
        #expect(service.pinChanges.isEmpty && service.passwordChanges.count == 1 && service.passwordFailureCount == 0)
        #expect(m.session?.device.credentialVersion == service.vaultCredentialVersion && m.changeCheck == nil)
    }

    /// A crash after the record was written and before the request went: a harmless candidate. It is kept until a minute
    /// past its `exp` (nothing tells the phone it was never sent), then the unlock's `ok` replaces it.
    @Test func aCrashBeforeTheSendLeavesAHarmlessCandidate() async throws {
        defer { phone.close() }
        try await setUp()
        let exp = try #require(m.session?.device.vaultNow()).addingTimeInterval(ChangeRequest.validFor)
        _ = try m.phoneSecrets.beginChange(operation: "vault.secret.renew-crash", exp: exp)
        m.phoneSecrets.endChange(operation: "vault.secret.renew-crash")
        try phone.restart()
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
        try phone.restart()
        try await m.refresh()
        #expect(await renew() == nil)
        #expect(Set(service.renews.map(\.newUnlockSecret)).count == 2)
        #expect(try m.phoneSecrets.currentSecret() == service.currentSecret && m.phoneSecrets.records().candidates.isEmpty)
        #expect(try m.phoneSecrets.records().replaced.contains { $0.operation == first.operation })
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// Four renews that never arrived, each after a restart (a new operation): the fifth is refused before anything is made
    /// or sent ("Unlock your vault first"), and no candidate is dropped.
    @Test func theFourCandidateCapThroughRenews() async throws {
        defer { phone.close() }
        try await setUp()
        service.loseRequests([VaultApi.typeSecretRenew])
        for _ in 0..<4 {
            #expect(await renew()?.kind == .noResponse)
            try phone.restart()
            try await m.refresh()
        }
        let candidates = try m.phoneSecrets.records().candidates
        #expect(candidates.count == 4)
        #expect(await renew()?.kind == .unconfirmedChanges)
        #expect(try m.phoneSecrets.records().candidates == candidates && service.renews.isEmpty)
    }
}
