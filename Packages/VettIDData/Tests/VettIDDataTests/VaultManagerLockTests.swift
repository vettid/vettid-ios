import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// The member's lock against an unlock and the app's background (IOS-PLAN §6.6), end to end with ``FakeVaultService``,
/// whose every unlock first locks a running vault, as vettid-vault's `procHost.Open` does.
@MainActor
@Suite(.serialized) struct VaultManagerLockTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func openVault() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        try await m.lock()
        // An unlock: its time is known, so that later lock notices can be placed.
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked && service.isOpen)
    }

    /// An unlock locks the running vault first: a wrong PIN leaves it locked, and the phone says so.
    @Test func aWrongPinOnAnOpenVaultLeavesItLocked() async throws {
        defer { phone.close() }
        try await openVault()
        #expect(try await m.unlock(pin: "111111") == .badPin(retryAfterSeconds: 0))
        #expect(!service.isOpen)
        #expect(await eventually { m.phase == .locked })
        try await m.refresh()
        #expect(m.phase == .locked)
    }

    /// A lock asked while an unlock is on its way is not confirmed by that unlock's own `vault.locking`: it stays pending,
    /// is sent after the unlock, and the vault ends locked, as the phone says.
    @Test func aLockDuringAnUnlockIsSentAfterIt() async throws {
        defer { phone.close() }
        try await openVault()
        service.unlockAnswers(.held)
        service.holdMessages = true
        let unlock = Task { @MainActor in try await m.unlock(pin: pin) }
        #expect(await eventually { service.unlocks.count == 2 })
        let locking = Task { @MainActor in try await m.lock() }
        #expect(await eventually { m.lockPending })
        // The unlock's own lock notice arrives now, after the lock was asked for.
        service.holdMessages = false
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.lockPending, "the unlock's own lock is no evidence for this one")
        service.releaseHeldUnlock()
        #expect(try await unlock.value == .success)
        try await locking.value
        #expect(await eventually { !m.lockPending })
        #expect(!service.isOpen && m.phase == .locked)
    }

    /// Leaving the foreground: the first attempt of a lock asked for is finished, then the collection stops.
    @Test func theBackgroundFinishesTheLockThenStopsCollecting() async throws {
        defer { phone.close() }
        try await openVault()
        let relays = service.relayLocks
        service.relayLockAnswer = .noAnswer
        let locking = Task { @MainActor in try await m.lock() }
        await Task.yield()
        await m.onBackground()
        #expect(service.relayLocks == relays + 1 && service.memberLocks == 1, "the lock request went out first")
        #expect(m.session == nil, "the collection stopped")
        try await locking.value
    }

    /// Background, then foreground before the background work ended: the collection runs on.
    @Test func aReturnToTheForegroundKeepsTheCollection() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        let locking = Task { @MainActor in try await m.lock() }
        await Task.yield()
        let background = Task { @MainActor in await m.onBackground() }
        try await Task.sleep(for: .milliseconds(100))
        m.onForeground()
        await background.value
        #expect(await eventually { m.session?.device.collecting == true })
        try await locking.value
    }

    /// In the background a lock's retries open the session but never start the collection again; the member API carries
    /// the lock. The return to the foreground starts it.
    @Test func aRetryInTheBackgroundDoesNotCollect() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        await m.onBackground(budget: .milliseconds(50))
        #expect(m.session == nil)
        let asked = service.memberLocks
        #expect(await eventually { service.memberLocks > asked + 1 }, "the retries go on")
        #expect(m.session?.device.collecting != true, "nothing collects in the background")
        m.onForeground()
        #expect(await eventually { m.session?.device.collecting == true })
        service.memberLockAnswer = .lock
        #expect(await eventually { !m.lockPending })
    }

    /// The background work is bounded: past its budget the collection stops all the same.
    @Test func theBackgroundWorkIsBounded() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        let locking = Task { @MainActor in try await m.lock() }
        await Task.yield()
        let start = Date()
        await m.onBackground(budget: .milliseconds(50))
        #expect(Date().timeIntervalSince(start) < 0.4)
        #expect(m.session == nil)
        try await locking.value
    }

    /// Finish setup is refused while the vault is locked.
    @Test func finishSetupIsRefusedWhileLocked() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.lock()
        try await m.finishSetup()
        #expect(m.phase == .locked)
    }
}
