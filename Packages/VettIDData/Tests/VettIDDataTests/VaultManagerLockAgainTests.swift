import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

/// Release L, "Lock it now" and the opening a lock is bound to, end to end with ``FakeVaultService``: the bound it puts on the
/// status read, the name a lock that ended as "opened again" leaves dead, and the foreground's retry.
@MainActor
@Suite(.serialized) struct VaultManagerLockAgainTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        // The status read of "Lock it now" waits 0.3 s here (5 s in the app).
        phone = try TestVaultPhone(service: service, lockStatusWait: 0.3)
    }

    var m: VaultManager { phone.manager }

    func openVault() async throws {
        service.announcesUnlockID = true
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.phase == .unlocked && service.isOpen)
    }

    /// The vault was opened again while this phone was away, and its lock came back `stale_lock`: held on "opened again".
    func heldOnOpenedAgain() async throws {
        try await openVault()
        service.openedByAnotherDevice(notifying: false)
        try await m.lock()
        #expect(await eventually { m.lockNotice == .openedAgain })
    }

    func locking(_ unlockID: String?, ts: Date) -> VaultMessage {
        let body = unlockID.map { #"{"unlock_id":"\#($0)"}"# } ?? "{}"
        return VaultMessage(inner: Inner(id: Ulid.new(), type: LockNotices.type, ts: ts, body: Array(body.utf8)))
    }

    /// The status read of "Lock it now" never answers: at the wait's end the lock goes out unconditional, and locks the vault.
    @Test func aStatusThatNeverAnswersLetsTheLockGoOutUnboundAtTheEndOfTheWait() async throws {
        defer { phone.close() }
        try await heldOnOpenedAgain()
        service.loseAnswers(["vault.status"])
        let asked = service.relayLockNamed.count
        await m.lockAgain()
        #expect(m.lockPending, "pending from the tap, before anything is read")
        #expect(await eventually { !service.isOpen })
        #expect(service.relayLockNamed.count > asked && service.relayLockNamed.last == .some(nil), "unconditional")
        #expect(await eventually { !m.lockHoldsPhone })
    }

    /// (a) A late `vault.locking` that names the dead opening confirms nothing while held; (b) a plain lock afterwards is not
    /// bound to the dead name.
    @Test func theNameOfALockThatEndedOpenedAgainIsForgotten() async throws {
        defer { phone.close() }
        try await openVault()
        let known = try #require(service.currentUnlockID)
        // The status cannot be read when the lock is answered stale: the device keeps the name of the dead opening.
        service.openedByAnotherDevice(notifying: false)
        service.loseAnswers(["vault.status"])
        try await m.lock()
        #expect(await eventually(within: .seconds(20)) { m.lockNotice == .openedAgain })
        #expect(service.relayLockNamed.last == known)
        #expect(m.session?.device.unlockID != known, "the dead name is forgotten")
        // (a) The dead opening's notice, however late it says it is, does not turn the card into "locked".
        m.onEvent(locking(known, ts: Date().addingTimeInterval(3600)))
        #expect(m.lockNotice == .openedAgain && m.lockHoldsPhone)
        // (b) A plain lock is not bound to it, so it is not answered stale_lock again.
        service.loseAnswers([])
        try await m.lock()
        #expect(await eventually { !service.isOpen })
        #expect(service.relayLockNamed.last == .some(nil))
        #expect(await eventually { !m.lockHoldsPhone })
    }

    /// The dead name is kept across a restart: a new process that starts held still drops a `vault.locking` naming it.
    @Test func aRestartedHeldPhoneStillDropsTheDeadOpeningsNotice() async throws {
        defer { phone.close() }
        try await openVault()
        let known = try #require(service.currentUnlockID)
        service.openedByAnotherDevice(notifying: false)
        try await m.lock()
        #expect(await eventually { m.lockNotice == .openedAgain })
        try await phone.restart()
        try await m.refresh()
        #expect(m.lockNotice == .openedAgain && m.lockHoldsPhone && m.session?.device.unlockID != known)
        m.onEvent(locking(known, ts: Date().addingTimeInterval(3600)))
        #expect(m.lockNotice == .openedAgain, "the dead opening's notice does not turn it into locked")
    }

    /// The foreground retry skips an attempt that just began and leaves the member's "Try again" alone.
    @Test func theForegroundDoesNotUseUpTryAgain() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        m.onForeground()
        let asked = service.memberLocks
        // The foreground's try did not use up the member's: it is started (false after a try within 10 s).
        #expect(m.lockGuard.keeper.retryNow())
        #expect(await eventually { service.memberLocks > asked }, "Try again right after the foreground's still goes out")
        service.memberLockAnswer = .lock
        #expect(await eventually { !m.lockPending })
    }
}
