import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// Release L (VAULT-MESSAGING §3.6.8) end to end: the vault says `idle_lock_at`, the setting follows "the lowest value since
/// the last check", and a vault that locked itself is said to have, until it opens again.
@MainActor
@Suite(.serialized) struct VaultManagerIdleLockTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var checks: OwnerCheckManager { phone.manager.ownerChecks }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    @Test func theVaultSaysWhenItLocksItselfAndTheSettingFollowsTheLowestValue() async throws {
        defer { phone.close() }
        try await setUp()
        try await checks.refreshOwnerCheck()
        let deadline = try #require(checks.ownerCheck?.deadline)
        #expect(checks.ownerCheck?.idleAfterSeconds == 604_800)
        #expect(checks.ownerCheck?.idleLockAt != nil && service.idleLockAt != nil)

        try await checks.refreshIdleLockSetting()
        #expect(checks.idleLockSetting == IdleLockSetting(seconds: 604_800))
        // Shorter: at once, and the vault says the new time.
        try await checks.setIdleLockAfter(seconds: 3_600)
        #expect(checks.idleLockSetting == IdleLockSetting(seconds: 3_600))
        #expect(checks.ownerCheck?.idleAfterSeconds == 3_600)
        // Longer: from the next check; the time said stays.
        try await checks.setIdleLockAfter(seconds: 2_592_000)
        #expect(checks.idleLockSetting?.afterNextCheck == true)
        #expect(service.idleLockAfter == 2_592_000 && service.idleLockInForce == 3_600)
        #expect(checks.ownerCheck?.deadline == deadline && checks.ownerCheck?.idleAfterSeconds == 3_600)

        // Past the deadline, the vault locks itself: the unlock screen says why, until the vault opens again.
        service.advanceVaultClock(86_401)
        try await checks.refreshOwnerCheck()
        service.lockByItself(reason: "idle")
        #expect(await eventually { checks.idleLocked != nil && m.phase == .locked })
        #expect(checks.idleLocked == IdleLocked(afterSeconds: 3_600))
        #expect(try await m.unlockWithCheck(pin: pin, password: password) == .success)
        #expect(checks.idleLocked == nil)
        #expect(checks.unlockCheckOutcome == .passed)
        // The check put the longer value in force: the vault says a time 30 days past the new deadline.
        try await checks.refreshOwnerCheck()
        #expect(checks.idleLockSetting == IdleLockSetting(seconds: 2_592_000))
        #expect(checks.ownerCheck?.idleAfterSeconds == 2_592_000)
    }

    /// The member's own lock, whatever `idle_lock_at` says later, is not said to be the vault locking itself.
    @Test func aLockByTheMemberIsNotSaidToBeAnIdleLockWhenIdleLockAtPasses() async throws {
        defer { phone.close() }
        try await setUp()
        try await checks.refreshOwnerCheck()
        let idleAt = try #require(checks.ownerCheck?.idleLockAt)
        let later = idleAt.addingTimeInterval(60)
        try await m.lock()
        #expect(checks.idleLockedNow(later) == nil)
        await m.lockAgain()
        #expect(checks.idleLockedNow(later) == nil)
    }

    @Test func aVaultBeforeLHasNoSettingAndNoTime() async throws {
        defer { phone.close() }
        service.idleLockSupported = false
        try await setUp()
        try await checks.refreshOwnerCheck()
        try await checks.refreshIdleLockSetting()
        #expect(checks.ownerCheck?.idleLockAt == nil)
        #expect(checks.idleLockSetting == nil)
        let refused = await vaultFailure { try await checks.setIdleLockAfter(seconds: 3_600) }
        #expect(refused?.kind == .notSupported)
    }
}
