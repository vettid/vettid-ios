import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The daily owner check (VAULT-MESSAGING §3.6) end to end, as ANDROID-PLAN §6 item 9 asks for it on the dev stack: the
/// vault's own clock is moved past its deadline (``FakeVaultService/advanceVaultClock(_:)``, the dev stack's clock), and
/// ``FakeVaultService`` answers as vettid-vault does: the held state and its counts, the check, a wrong PIN, a wrong
/// password, the ten-failure lock, and the check right after an unlock past the deadline (§3.6.5).
@MainActor
@Suite(.serialized) struct VaultManagerOwnerCheckTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    /// One day and a second: past the default interval (§3.6.2).
    let pastDeadline: TimeInterval = 86_401

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var checks: OwnerCheckManager { phone.manager.ownerChecks }

    /// Setup code to the open app; the first credential started the vault's clock.
    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        #expect(service.ownerCheckDeadline != nil)
    }

    /// Setup, then the vault's clock past the deadline and the app reading it.
    func pastTheDeadline() async throws {
        try await setUp()
        service.advanceVaultClock(pastDeadline)
        try await checks.refreshOwnerCheck()
        #expect(checks.ownerCheck?.state == .held && checks.ownerCheck?.gated(Date()) == true)
    }

    /// The held screen's content: the vault holds past its deadline and says what waits (`vault.held`, §3.6.3); nothing
    /// but the check goes through (`owner_check_required`); the check opens it, moves the deadline and rotates the blob.
    @Test func pastTheDeadlineTheVaultHoldsAndTheCheckOpensIt() async throws {
        defer { phone.close() }
        try await pastTheDeadline()
        // vault.held at the start of the gate (handled: the status read already said nothing waits), then with what
        // arrived.
        #expect(await eventually { checks.heldTs != nil && checks.ownerCheck?.waiting == WaitingCounts() })
        service.heldArrived(messages: 3, requests: 1)
        #expect(await eventually { checks.ownerCheck?.waiting == WaitingCounts(messages: 3, requests: 1) })
        // Nothing else is answered while gated (a settings change, here).
        let refused = await vaultFailure { try await checks.setCheckInterval(seconds: 3_600) }
        #expect(refused?.kind == .ownerCheckRequired)
        #expect(await eventually { checks.ownerCheck?.state == .held })

        let before = service.vaultCredentialVersion
        #expect(try await checks.check(pin: pin, password: password) == .passed)
        let sent = try #require(service.ownerChecks.last)
        #expect(sent.pin == pin && sent.password == password && sent.hold == nil)
        #expect(service.vaultCredentialVersion == before + 1, "the CEK rotated (§3.6.1 step 8)")
        #expect(checks.ownerCheck?.state == .ok && checks.ownerCheck?.gated(Date()) == false && checks.ownerCheck?.waiting == nil)
        let deadline = try #require(checks.ownerCheck?.deadline)
        #expect(deadline > Date().addingTimeInterval(pastDeadline + 86_000), "a full interval on the vault's clock")
        // Open again: the settings change goes through.
        try await checks.setCheckInterval(seconds: 3_600)
    }

    /// A wrong PIN and a wrong password are failed checks: each says which entry was wrong and how many are left
    /// (§3.6.4, §3.6.5); a right check starts the count again.
    @Test func aWrongPinAndAWrongPasswordAreFailedChecks() async throws {
        defer { phone.close() }
        try await pastTheDeadline()
        #expect(try await checks.check(pin: "111111", password: password) == .badPin(checksLeft: 9))
        #expect(try await checks.check(pin: pin, password: "wrong horse") == .badPassword(checksLeft: 8))
        #expect(service.ownerCheckFailures == 2)
        #expect(checks.ownerCheck?.checksLeft == 8)
        #expect(try await checks.check(pin: pin, password: password) == .passed)
        #expect(service.ownerCheckFailures == 0 && checks.ownerCheck?.checksLeft == 10)
    }

    /// The password's own backoff (§11.8 for the password): after five wrong ones in a row the vault waits and says how
    /// long; a right entry during the wait is not tried.
    @Test func wrongPasswordsBackOffAfterFive() async throws {
        defer { phone.close() }
        try await pastTheDeadline()
        for _ in 0..<5 {
            guard case .badPassword = try await checks.check(pin: pin, password: "wrong horse") else {
                Issue.record("a wrong password is a failed check")
                return
            }
        }
        guard case .backoff(let wait) = try await checks.check(pin: pin, password: password) else {
            Issue.record("the sixth check waits")
            return
        }
        #expect(wait > 0 && wait <= 30)
        #expect(service.ownerCheckFailures == 5, "a check refused for the backoff is not counted")
        service.advanceVaultClock(31)
        #expect(try await checks.check(pin: pin, password: password) == .passed)
    }

    /// Ten failed checks in a row lock the vault (§3.6.4): the tenth is answered, then `vault.locking{reason:
    /// "owner_check"}`; the unlock screen says so and asks for the PIN and the password, and the check follows the unlock.
    @Test func tenFailedChecksLockTheVault() async throws {
        defer { phone.close() }
        try await pastTheDeadline()
        for i in 1...10 {
            // Past each of the password's waits, so that every check counts.
            service.advanceVaultClock(3_601)
            guard case .badPassword(let left) = try await checks.check(pin: pin, password: "wrong horse") else {
                Issue.record("check \(i) is a failed check")
                return
            }
            if i < 10 { #expect(left == 10 - i) }
        }
        #expect(service.ownerCheckFailures == 10)
        #expect(await eventually { checks.lockedByOwnerCheck && m.phase == .locked })
        #expect(!service.isOpen)

        // The unlock screen: PIN and password, the check right after the unlock (past the password's last wait).
        service.advanceVaultClock(3_601)
        #expect(try await m.unlockWithCheck(pin: pin, password: password) == .success)
        #expect(checks.unlockCheckOutcome == .passed)
        #expect(!checks.lockedByOwnerCheck && checks.ownerCheck?.gated(Date()) == false)
        #expect(m.phase == .unlocked && service.ownerCheckFailures == 0)
    }

    /// A locked vault past its deadline (§3.6.5): one screen for the PIN and the password; the unlock, then the check at
    /// once without asking again. A wrong password there opens the vault and leaves the check screen its answer.
    @Test func aLockedVaultPastItsDeadlineChecksRightAfterTheUnlock() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        service.advanceVaultClock(pastDeadline)
        #expect(try await m.unlockWithCheck(pin: pin, password: "wrong horse") == .success)
        guard case .badPassword = checks.unlockCheckOutcome else {
            Issue.record("the check after the unlock was refused for its password")
            return
        }
        #expect(m.phase == .unlocked && checks.ownerCheck?.gated(Date()) == true)
        checks.consumeUnlockCheckOutcome()
        // The check screen: the check passes.
        #expect(try await checks.check(pin: pin, password: password) == .passed)
        #expect(checks.ownerCheck?.gated(Date()) == false)
    }

    /// Before the deadline the unlock sends no check, even with the password.
    @Test func beforeTheDeadlineTheUnlockSendsNoCheck() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        #expect(try await m.unlockWithCheck(pin: pin, password: password) == .success)
        #expect(service.ownerChecks.isEmpty && checks.unlockCheckOutcome == nil)
    }

    /// Turning the hold off rides on a check (§3.6.7); turning it on is a plain settings change.
    @Test func theHoldGoesOffWithACheckAndOnWithoutOne() async throws {
        defer { phone.close() }
        try await setUp()
        let until = Date().addingTimeInterval(3 * 86_400)
        #expect(try await checks.check(pin: pin, password: password, holdOff: HoldOff(until: until)) == .passed)
        #expect(service.holdIsOff && service.ownerChecks.last?.hold == false)
        #expect(checks.ownerCheck?.holdOff(Date()) == true)
        try await checks.turnHoldOn()
        #expect(!service.holdIsOff && checks.ownerCheck?.holdOff(Date()) == false)
    }

    /// What the phone learnt is kept: after a restart a vault past its deadline still asks for the password with the PIN.
    @Test func theGateSurvivesARestart() async throws {
        defer { phone.close() }
        try await pastTheDeadline()
        try phone.restart()
        // Read only after the first-run cleanup and a pending wipe, before anything else of the vault.
        #expect(m.ownerChecks.ownerCheck == nil)
        m.reloadLocalState()
        #expect(m.ownerChecks.ownerCheck?.gated(Date()) == true)
    }
}
