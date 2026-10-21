import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// How long ``eventually(within:_:)`` waits by default: 20 s. A full run shares the main actor among every suite running
/// at once, and the vault's opening now reads several lists one after another; on a loaded machine (and on CI) 5 s was
/// too short. Every use waits for something that must happen, so the longer wait only delays a failure.
let eventuallyDefault: Duration = .seconds(20)

/// Waits (up to [within], wall-clock) until [condition] holds; false when it never did.
@MainActor
func eventually(within: Duration = eventuallyDefault, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + within
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The unlock (VAULT-MESSAGING §11.4) and the member's lock (VAULT-LOCK as vettid-android implements it) end to end:
/// the member API, the enclave, both relays and the vault are ``FakeVaultService``, which answers `vault.unlock` as
/// vettid-vault's enclave does; the keys are software keys behind the Secure Enclave's protocols. vettid-android covers
/// these paths with its dev-stack tests; here they run without one (`DevStackAcceptanceTests` runs them on the stack).
@MainActor
@Suite(.serialized) struct VaultManagerUnlockTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// Setup code to the open app.
    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// Setup, then a lock the vault acknowledged.
    func lockedVault() async throws {
        try await setUp()
        try await m.lock()
        #expect(m.phase == .locked && !service.isOpen)
    }

    // MARK: - Lock and unlock

    /// The member's lock over the relay: the vault answers, so it is confirmed at once and never in doubt; the unlock
    /// after it carries the PIN and the phone's current secret, and the app opens.
    @Test func lockThenUnlock() async throws {
        defer { phone.close() }
        try await lockedVault()
        #expect(service.relayLocks == 1 && service.memberLocks == 0)
        #expect(m.lockNotice == .none && !m.lockPending)

        let p = try await m.preflight()
        #expect(p.routed.number == 3 && !p.rollback && !p.softwareUpdated)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked && service.isOpen)
        let sent = try #require(service.unlocks.last)
        let current = try m.phoneSecrets.currentSecret()
        #expect(sent.pin == pin && sent.unlockSecret == current)
        // The open phase stays: no stale vault.locking takes it back.
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.phase == .unlocked)
    }

    /// A wrong PIN is counted by the vault; after three in a row it backs off (§11.8) and says for how long
    /// (`retry_after`); a right PIN during the wait is not tried; after it, it opens and the count starts again.
    @Test func wrongPinsBackOffAfterThree() async throws {
        defer { phone.close() }
        try await lockedVault()
        #expect(try await m.unlock(pin: "111111") == .badPin(retryAfterSeconds: 0))
        #expect(try await m.unlock(pin: "111111") == .badPin(retryAfterSeconds: 0))
        #expect(try await m.unlock(pin: "111111") == .badPin(retryAfterSeconds: 30))
        #expect(service.pinFailureCount == 3)
        guard case .backoff(let wait) = try await m.unlock(pin: pin) else {
            Issue.record("a right PIN during the backoff is not tried")
            return
        }
        #expect(wait > 0 && wait <= 30)
        #expect(m.phase == .locked)
        service.advanceVaultClock(31)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.pinFailureCount == 0 && m.phase == .unlocked)
    }

    /// The vault could not be told (no answer over the relay, the member API's slot stays queued) and its status still
    /// says unlocked: this phone is locked all the same, the lock is pending and in doubt, and a refresh does not open
    /// the app. The vault locks: the next retry reads the status and the member is told it is now confirmed.
    @Test func aLockThatCannotBeConfirmedIsPendingUntilTheStatusSaysLocked() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.phase == .locked && m.lockPending)
        #expect(m.lockNotice.inDoubt)
        #expect(service.isOpen, "the vault was never told")
        try await m.refresh()
        #expect(m.phase == .locked, "locked here whatever the status says")
        // Finish setup is held while a lock is pending.
        try await m.finishSetup()
        #expect(m.phase == .locked)

        // The member API's "done" proves nothing (VAULT-LOCK §2 F8): still pending.
        service.memberLockAnswer = .doneNotLocked
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.lockPending)

        service.lockByItself(reason: "owner")
        #expect(await eventually { m.lockNotice == .confirmedLate })
        #expect(!m.lockPending)
        m.dismissLockNotice()
        #expect(m.lockNotice == .none)
        // The relay lock may still be waiting at the vault: the unlock waits it out, then opens.
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked)
    }

    /// A pending lock survives the process: the next start is locked from the start, in doubt, and tries again.
    @Test func aPendingLockSurvivesARestart() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .locked && m.lockPending && m.lockNotice.inDoubt)
        service.memberLockAnswer = .lock
        #expect(await eventually { !m.lockPending })
        #expect(!service.isOpen)
    }

    /// A lock the vault confirms through the member API after the relay got no answer.
    @Test func aLockThroughTheMemberApiIsConfirmedByTheStatus() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayLockAnswer = .noAnswer
        try await m.lock()
        #expect(service.memberLocks == 1 && !service.isOpen)
        #expect(!m.lockPending && m.lockNotice == .none, "confirmed by the first attempt: never in doubt")
    }

    // MARK: - Answers that are lost, unreadable or sealed refusals

    /// The unlock's answer was lost: the vault opened, the phone does not know. It says so (a failure, nothing erased),
    /// and the next unlock locks the running vault and opens it again; its late `vault.locking` is stale and dropped.
    @Test func aLostUnlockAnswerIsTriedAgain() async throws {
        defer { phone.close() }
        try await lockedVault()
        service.unlockAnswers(.answerLost)
        guard case .failed(let kind, _, _) = try await m.unlock(pin: pin) else {
            Issue.record("a lost answer is a failure")
            return
        }
        #expect(kind == .network)
        #expect(service.isOpen && m.phase == .locked)
        #expect(try await m.unlock(pin: pin) == .success)
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.phase == .unlocked, "the lock before this unlock does not lock the app again")
    }

    /// An unreadable result (§11.4: the bytes an unknown device gets) is no proof: nothing is erased.
    @Test func anUnreadableResultIsAFailureAndNothingMore() async throws {
        defer { phone.close() }
        try await lockedVault()
        service.unlockAnswers(.unreadable)
        #expect(try await m.unlock(pin: pin) == .failed(.other, code: "unreadable_result"))
        #expect(m.holder?.count == 0 && m.phase == .locked)
    }

    /// The sealed answers decided before the PIN: a recovery pending, the signer refused, a rollback of the vault's state
    /// (an unknown device, the proof of a replacement, wipes the phone: `VaultManagerWipeTests`).
    @Test func sealedRefusalsBeforeThePin() async throws {
        defer { phone.close() }
        try await lockedVault()
        service.unlockAnswers(.sealed("recovery_pending"), .sealed("signer_refused"), .sealed("state_rollback"))
        #expect(try await m.unlock(pin: pin) == .recoveryPending)
        #expect(try await m.unlock(pin: pin) == .signerRefused)
        #expect(try await m.unlock(pin: pin) == .stateRollback)
        #expect(m.holder?.count == 0)
        #expect(service.pinFailureCount == 0, "none of these counts as a wrong PIN")
        // The cancel of a recovery travels with the unlock.
        #expect(try await m.unlock(pin: pin, approve: nil, cancelRecovery: true) == .success)
        #expect(service.unlocks.last?.cancelRecovery == true)
    }

    /// IOS-PLAN ID8: an instance without `recovery_r` is refused at the release check, before any PIN.
    @Test func aReleaseBeforeRIsRefusedAtThePreflight() async throws {
        defer { phone.close() }
        try await lockedVault()
        service.capabilities = nil
        #expect(await vaultFailure { _ = try await m.preflight() }?.kind == .releaseTooOld)
        #expect(try await m.unlock(pin: pin) == .failed(.releaseTooOld, code: "release_too_old"))
        #expect(service.unlocks.isEmpty, "nothing was sent")
    }

    // MARK: - The phone secret

    /// A change of the phone secret whose answer was lost, which the vault stored: the current record gets
    /// `device_secret`, the candidate opens the vault and becomes current (§11.14.1 rule 4; IOS-PLAN §6.3 item 3).
    @Test func aCandidateTheVaultStoredSettlesAtTheUnlock() async throws {
        defer { phone.close() }
        try await lockedVault()
        try await lostChange(storedByVault: true)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.unlocks.count == 2, "the current record, then the candidate")
        let recs = try m.phoneSecrets.records()
        #expect(recs.current?.record.epoch == 2 && recs.candidates.isEmpty)
    }

    /// The same change the vault never stored: the current record opens it, and the candidate becomes a replaced record.
    @Test func aCandidateTheVaultNeverStoredIsReplacedAtTheUnlock() async throws {
        defer { phone.close() }
        try await lockedVault()
        try await lostChange(storedByVault: false)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(service.unlocks.count == 1)
        let recs = try m.phoneSecrets.records()
        #expect(recs.current?.record.epoch == 1 && recs.candidates.isEmpty && recs.replaced.count == 1)
    }

    /// The phone no longer holds the vault's keys: `device_secret`, the screen's "this phone cannot open your vault". With
    /// a replaced record kept, the member's tap tries it: an operator restore of the state from before a change.
    @Test func theEarlierSecretOnlyOnTheMembersTap() async throws {
        defer { phone.close() }
        try await lockedVault()
        #expect(!m.earlierSecretOffered)
        let first = try m.phoneSecrets.currentSecret()
        // A change the vault answered: epoch 2 is current, epoch 1 a replaced record.
        let svc = service
        _ = try await m.phoneSecrets.change(operation: "renew-1", send: { next in svc.storeSecret(next) }, confirmed: { _ in true })
        #expect(try m.phoneSecrets.current()?.epoch == 2)
        // The operator restored the vault's state from before the change.
        service.storeSecret(first)
        #expect(try await m.unlock(pin: pin) == .failed(.deviceSecret, code: "device_secret"))
        #expect(service.unlocks.count == 1, "the earlier secret is never tried by itself")
        #expect(m.earlierSecretOffered)
        #expect(!m.renewSecretSuggested)
        #expect(try await m.unlockWithEarlierSecret(pin: pin) == .success)
        #expect(m.renewSecretSuggested, "a new phone secret is to be asked for at once")
        #expect(try m.phoneSecrets.current()?.epoch == 1 && m.phase == .unlocked)
    }

    /// A change of the phone secret whose answer was lost: its record stays a candidate; [storedByVault]: the vault holds
    /// its secret.
    private func lostChange(storedByVault: Bool) async throws {
        struct Lost: Error {}
        let svc = service
        await #expect(throws: Lost.self) {
            _ = try await m.phoneSecrets.change(operation: "pin-1", send: { (next: [UInt8]) -> Bool in
                if storedByVault { svc.storeSecret(next) }
                throw Lost()
            }, confirmed: { $0 })
        }
        #expect(try m.phoneSecrets.records().candidates.count == 1)
    }

    // MARK: - Locks the phone did not ask for

    /// Ten failed checks lock the vault (§3.6.4): its `vault.locking` sends the open app to the unlock screen; the PIN
    /// opens it again.
    @Test func theVaultsOwnLockIsFollowed() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await m.unlock(pin: pin) // an unlock time known, so that the notice can be placed
        #expect(m.phase == .unlocked)
        try await Task.sleep(for: .milliseconds(100))
        service.lockByItself(reason: "owner_check")
        #expect(await eventually { m.phase == .locked })
        #expect(!m.lockPending && m.lockNotice == .none, "nothing of this phone's was pending")
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked)
    }
}
