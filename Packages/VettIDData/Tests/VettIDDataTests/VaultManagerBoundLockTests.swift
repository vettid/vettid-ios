import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// Release L (VAULT-MESSAGING 0.56.4 §10.2 "Locks"; VAULT-LOCK 0.1.4) end to end with ``FakeVaultService`` as a vault that
/// names its openings: the lock bound to its unlock, `stale_lock` as "opened again", and the lock of a vault before L.
@MainActor
@Suite(.serialized) struct VaultManagerBoundLockTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func openVault(announcing: Bool) async throws {
        service.announcesUnlockID = announcing
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked && service.isOpen)
    }

    /// The unlock's result names the opening, in memory; the lock names it over the relay and the vault locks.
    @Test func theLockNamesTheOpeningTheUnlockResultNamed() async throws {
        defer { phone.close() }
        try await openVault(announcing: true)
        let id = try #require(service.currentUnlockID)
        #expect(m.session?.device.unlockID == id)
        try await m.lock()
        #expect(service.relayLockNamed.last == id)
        #expect(await eventually { !service.isOpen && !m.lockPending })
        #expect(m.lockNotice == .none && !m.lockHoldsPhone)
    }

    /// The vault was opened again by another device: the bound lock is answered `stale_lock`, which is not taken as locked.
    /// The vault stays open, the member is told, this phone stays locked; "Lock it now" binds a fresh lock to the opening
    /// running now, and the vault locks.
    @Test func aStaleLockIsOpenedAgainAndLockItNowLocksTheNewOpening() async throws {
        defer { phone.close() }
        try await openVault(announcing: true)
        let known = try #require(service.currentUnlockID)
        service.openedByAnotherDevice(notifying: false) // this phone is not told: it was off the network
        let now = try #require(service.currentUnlockID)
        #expect(now != known)
        try await m.lock()
        #expect(await eventually { m.lockNotice == .openedAgain })
        #expect(service.relayLockNamed.last == known)
        #expect(service.isOpen, "nothing was locked")
        #expect(!m.lockPending && m.lockHoldsPhone && m.phase == .locked)
        // The refreshed phase stays locked whatever the status says.
        try await m.refresh()
        #expect(m.phase == .locked)
        await m.lockAgain()
        #expect(await eventually { !service.isOpen })
        #expect(service.relayLockNamed.last == now, "bound to the opening the status named")
        #expect(await eventually { !m.lockHoldsPhone })
        #expect(m.phase == .locked)
        // The next unlock here ends every hold.
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(!m.lockHoldsPhone && m.phase == .unlocked)
    }

    /// The vault before L: no name anywhere; the lock is #127's (the relay lock, the unconditional API lock).
    @Test func aVaultBeforeLIsLockedWithoutAName() async throws {
        defer { phone.close() }
        try await openVault(announcing: false)
        #expect(m.session?.device.unlockID == nil)
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        #expect(service.relayLockNamed.last == .some(nil))
        #expect(await eventually { !service.memberLockNamed.isEmpty })
        #expect(service.memberLockNamed.allSatisfy { $0 == nil })
        service.memberLockAnswer = .lock
        #expect(await eventually { !m.lockPending })
    }

    /// An app that lost the value (a new process before its first status read) of a vault that announced one locks as for a
    /// vault before L (VAULT-LOCK Q3): one relay lock and the unconditional API lock.
    @Test func aPhoneWithoutTheValueLocksUnbound() async throws {
        defer { phone.close() }
        try await openVault(announcing: true)
        m.session?.device.recoveryOpened(unlockID: nil) // a new process: the name is in memory only
        try await m.lock()
        #expect(service.relayLockNamed.last == .some(nil))
        #expect(await eventually { !service.isOpen && !m.lockPending })
    }
}
