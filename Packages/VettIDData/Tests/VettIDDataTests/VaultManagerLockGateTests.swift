import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The lock gate of the outbox, end to end (ANDROID-PLAN "Locking", "While pending": nothing is sent to the vault but the
/// lock and a pending `call.end`): a return to the foreground with a lock pending starts the collection and flushes, and
/// the device's gate holds what the outbox has; once the lock is confirmed, the next unlock's flush sends it as before. Only
/// a pending lock holds it: in "opened again" the replies go.
@MainActor
@Suite(.serialized) struct VaultManagerLockGateTests {
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
        #expect(m.phase == .unlocked && service.isOpen)
    }

    /// Puts [type] in the session device's outbox, as a deposit that failed in transport leaves it.
    func keep(_ type: String) async throws -> VaultDevice {
        let d = try #require(try await m.storedSession()).device
        try await Self.enqueue(type, on: d)
        return d
    }

    nonisolated static func enqueue(_ type: String, on d: VaultDevice) async throws {
        let e = try await d.lock.withLock {
            try d.enqueueLocked(id: nil, type: type, body: VaultJSON.empty, re: nil, status: nil, exp: nil)
        }
        d.mem.withLock { _ = d.outboxInFlight.remove(e.id) }
    }

    func seen(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    /// Going to the background with a lock pending flushes all the same (no longer skipped): a pending `call.end` goes, and
    /// the gate holds the rest.
    @Test func theBackgroundsFlushWithALockPendingSendsOnlyACallEnd() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        let d = try await keep("device.features")
        _ = try await keep("call.end")
        let features = seen("device.features")
        await m.onBackground(budget: .seconds(5))
        #expect(await eventually { seen("call.end") == 1 }, "a pending call.end still goes")
        #expect(seen("device.features") == features)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["device.features"])
    }

    @Test func aForegroundWithALockPendingDepositsNothingButACallEnd() async throws {
        defer { phone.close() }
        try await openVault()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        let d = try await keep("device.features")
        _ = try await keep("call.end")
        let features = seen("device.features")
        m.onForeground()
        #expect(await eventually { seen("call.end") == 1 }, "a pending call.end still goes")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(seen("device.features") == features)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["device.features"])
        // Confirmed, and the vault opened again: the unlock's flush sends it, as before.
        service.memberLockAnswer = .lock
        #expect(await eventually { !m.lockPending })
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { seen("device.features") > features })
        #expect(await eventually { d.mem.withLock { d.st.outbox.isEmpty } })
    }

    /// Only a pending lock holds the outbox: in "opened again" (the lock ended as stale, this phone stays locked until an
    /// unlock here) the phone's replies go, as before.
    @Test func inOpenedAgainThePhonesRepliesGo() async throws {
        defer { phone.close() }
        service.announcesUnlockID = true
        try await openVault()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        service.openedByAnotherDevice(notifying: false)
        try await m.lock()
        #expect(await eventually { m.lockNotice == .openedAgain })
        #expect(!m.lockPending && m.lockHoldsPhone)
        let d = try await keep("device.features")
        _ = try await keep("relay.token.issued")
        let features = seen("device.features")
        let issued = seen("relay.token.issued")
        m.onForeground()
        #expect(await eventually { seen("device.features") > features && seen("relay.token.issued") > issued })
        #expect(await eventually { d.mem.withLock { d.st.outbox.isEmpty } })
        #expect(m.lockHoldsPhone, "the phone stays locked")
    }

    /// "Opened again" with an ack owed: this phone's lock was answered `stale_lock` (the vault was opened again elsewhere).
    func openedAgain(ackOwed: Bool = false) async throws -> VaultDevice {
        service.announcesUnlockID = true
        if ackOwed { service.refuse("credential.ack", with: "retry", times: 1) }
        try await openVault()
        let d = try #require(m.session?.device)
        // No flush may send the owed ack on its own meanwhile: the last one counts as just tried.
        if ackOwed { d.holdBackAckRetries(true) }
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        service.openedByAnotherDevice(notifying: false)
        try await m.lock()
        #expect(await eventually { m.lockNotice == .openedAgain })
        #expect(!m.lockPending && m.lockHoldsPhone)
        if ackOwed { #expect(d.credentialAckPending) }
        return d
    }

    /// In "opened again" a handled vault message's reply (the refresh answer) and the flush's owed `credential.ack` go.
    @Test func inOpenedAgainAHandledReplyAndTheOwedAckGo() async throws {
        defer { phone.close() }
        let d = try await openedAgain(ackOwed: true)
        let refreshes = seen("relay.token.refresh")
        service.sendTokenRefresh()
        #expect(await eventually { seen("relay.token.refresh") > refreshes }, "the refresh answer goes")
        let acks = seen("credential.ack")
        d.holdBackAckRetries(false)
        m.onForeground()
        #expect(await eventually { seen("credential.ack") > acks && !d.credentialAckPending }, "the owed ack goes")
        #expect(m.lockHoldsPhone)
    }

    /// "Lock it now" from "opened again" makes the lock pending at once: the gate holds the outbox again.
    @Test func lockItNowShutsTheGateAgain() async throws {
        defer { phone.close() }
        _ = try await openedAgain()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        await m.lockAgain()
        #expect(m.lockPending)
        let d = try await keep("device.features")
        let features = seen("device.features")
        m.onForeground()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(seen("device.features") == features)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["device.features"])
    }

    /// A new process that starts in "opened again" lets the outbox go too; an operation on the open vault is still refused.
    @Test func aRestartIntoOpenedAgainLetsTheOutboxGoButNoOperation() async throws {
        defer { phone.close() }
        _ = try await openedAgain()
        try await phone.restart()
        try await m.refresh()
        #expect(m.lockNotice == .openedAgain && m.lockHoldsPhone && !m.lockPending)
        let d = try await keep("device.features")
        let features = seen("device.features")
        m.onForeground()
        #expect(await eventually { seen("device.features") > features })
        #expect(await eventually { d.mem.withLock { d.st.outbox.isEmpty } })
        let s = try #require(try await m.storedSession())
        #expect(throws: VaultFailure.self) { _ = try m.openApi(s) }
    }
}
