import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A live call keeps the vault's collection running when the app leaves the foreground (the `audio` background mode keeps the
/// process): the peer's `call.end` is received and the local hang-up is sent. When the call ends with the app still in the
/// background, the collection stops as it would have. With no call, leaving the foreground stops it as before.
@MainActor
@Suite(.serialized) struct VaultManagerHoldCollectionTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    @MainActor final class Hold {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    struct CallEventMissing: Error {}

    func openVault() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    func seen(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    func waitFor(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 40) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func withNoCallLeavingTheForegroundStopsTheCollectionAsBefore() async throws {
        defer { phone.close() }
        try await openVault()
        let hold = Hold(false)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session == nil && m.backgrounded)
    }

    @Test func aLiveCallKeepsCollectingAndSendingInTheBackground() async throws {
        defer { phone.close() }
        try await openVault()
        let hold = Hold(true)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session != nil, "the collection runs on")
        // Received: the peer's `call.end` in the background reaches the call events.
        var events = try #require(m.session).api.callEvents().makeAsyncIterator()
        service.sendCallEnd(callId)
        guard case .ended(let ended)? = await events.next() else { throw CallEventMissing() }
        #expect(ended.callId == callId, "the vault's messages are collected")
        // Sent: the local hang-up goes through the session.
        try await m.sendCallEnd(callId: callId, reason: CallReason.hangup)
        #expect(await waitFor { seen("call.end") == 1 }, "the hang-up is sent")
    }

    @Test func whenTheCallEndsInTheBackgroundTheCollectionStops() async throws {
        defer { phone.close() }
        try await openVault()
        let hold = Hold(true)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session != nil)
        // The hold is still on: nothing changes.
        m.collectionHoldEnded()
        #expect(m.session != nil && !m.backgrounded)
        hold.on = false
        m.collectionHoldEnded()
        #expect(m.session == nil && m.backgrounded, "as onBackground would have left it")
    }

    @Test func aCallThatEndsAfterTheReturnToTheForegroundStopsNothing() async throws {
        defer { phone.close() }
        try await openVault()
        let hold = Hold(true)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        m.onForeground()
        hold.on = false
        m.collectionHoldEnded()
        #expect(m.session != nil && !m.backgrounded)
    }

    @Test func aCallEndingWithNoBackgroundWaitingStopsNothing() async throws {
        defer { phone.close() }
        try await openVault()
        m.holdCollection { false }
        m.collectionHoldEnded()
        #expect(m.session != nil && !m.backgrounded)
    }

    // MARK: only call traffic in a held background

    /// What is not a call's or a lock's is neither handled nor acked in a held background: the relay keeps it and delivers it again
    /// after its lease, and the app applies it once it is back in the foreground.
    @Test func nonCallEventsAreLeftUnackedInAHeldBackgroundAndHandledAtTheForeground() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        service.sendEvent("credential.alarm", alarm("a1"))
        #expect(await waitFor { service.mailboxCounts.leased >= 1 }, "collected and leased, not acked")
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.alarm == nil, "nothing is acted on in the background")
        m.onForeground()
        service.endLeases()
        #expect(await waitFor { m.alarm?.alarmID == "a1" }, "delivered again and applied once the app is back")
        #expect(await waitFor { service.mailboxCounts.leased == 0 }, "and acked then")
    }

    @Test func withoutAHoldEventsAreHandledAsBefore() async throws {
        defer { phone.close() }
        try await openVault()
        service.sendReleaseSync(7)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!m.eventsMissedWhileHeld)
    }

    /// A lock signal is honoured in a held background: the vault locking ends the phone's open state, and the call with it.
    @Test func aLockSignalIsHonouredInAHeldBackground() async throws {
        defer { phone.close() }
        try await openVault()
        let hold = Hold(true)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        service.lockByItself(reason: "owner_check")
        #expect(await waitFor { m.phase != .unlocked }, "the vault's own lock reaches the phone")
    }

    // MARK: the connection closes

    /// The connection is closed when the call ends in the background, and nothing starts it again; with no call it closes at once.
    @Test func theConnectionClosesWhenTheCallEndsInTheBackgroundAndStaysClosed() async throws {
        defer { phone.close() }
        try await openVault()
        let device = try #require(m.session).device
        let hold = Hold(true)
        m.holdCollection { hold.on }
        await m.onBackground(budget: .seconds(2))
        #expect(!device.mem.withLock { device.stopped }, "open while the call is live")
        hold.on = false
        m.collectionHoldEnded()
        #expect(device.mem.withLock { device.stopped }, "closed when the call ends")
        #expect(!device.ensureCollecting(), "nothing opens it again")
        m.collectionHoldEnded()
        #expect(m.session == nil && !device.ensureCollecting(), "no loop after the end")
    }

    @Test func withNoCallTheConnectionClosesAtOnce() async throws {
        defer { phone.close() }
        try await openVault()
        let device = try #require(m.session).device
        m.holdCollection { false }
        await m.onBackground(budget: .seconds(2))
        #expect(device.mem.withLock { device.stopped } && m.session == nil)
    }

    // MARK: the process ends while held

    /// The process ends while a call holds the background (iOS ends the app once the call is over, or under memory pressure): the
    /// clone alarm and the key warning were not acked, so a new process gets them again with its next unlock.
    @Test func aProcessEndedWhileHeldLosesNeitherTheAlarmNorTheKeyWarning() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        let raised = service.raiseCloneAlarm()
        service.sendEvent("connection.authenticate.result", #"{"connection_id":"c1","authenticated":true,"key_changed":true}"#)
        #expect(await waitFor { service.mailboxCounts.leased >= 2 }, "both leased, neither acked")
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.connections.authentication["c1"] == nil)
        // The process ends here: a fresh manager over the same vault and files.
        try await phone.restart()
        try await m.refresh()
        if m.phase != .unlocked { #expect(try await m.unlock(pin: pin) == .success) }
        service.endLeases()
        #expect(await waitFor { m.alarm?.alarmID == raised }, "the clone alarm comes back")
        #expect(await waitFor { m.connections.authentication["c1"]?.keyChanged == true }, "and the key warning")
    }

    // MARK: what a held background keeps

    func heldBackground() async throws {
        try await openVault()
        m.holdCollection { true }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session != nil)
    }

    /// An event the device had already handed over (acked) when the hold began: it reaches the manager and is kept.
    func inject(_ type: String, _ body: String) {
        m.onEvent(VaultMessage(inner: Inner(id: "i\(m.heldEvents.count)", type: type, ts: Date(), body: Array(body.utf8))))
    }

    func alarm(_ id: String) -> String { #"{"alarm_id":"\#(id)","state":"frozen"}"# }

    /// What reached the manager in a held background (already acked by the device, a race at the start of the hold) is kept in memory
    /// and applied, in arrival order, when the app is back in the foreground.
    @Test func eventsOfAHeldBackgroundAreAppliedInOrderAtTheForeground() async throws {
        defer { phone.close() }
        try await heldBackground()
        inject("credential.alarm", alarm("a1"))
        inject("connection.authenticate.result", #"{"connection_id":"c1","authenticated":true,"key_changed":true}"#)
        inject("credential.alarm", alarm("a2"))
        #expect(m.heldEvents.count == 3)
        #expect(m.alarm == nil && m.connections.authentication["c1"] == nil, "nothing is acted on in the background")
        #expect(m.heldEvents.map(\.type) == ["credential.alarm", "connection.authenticate.result", "credential.alarm"], "in arrival order")
        m.onForeground()
        #expect(m.heldEvents.isEmpty)
        #expect(m.alarm?.alarmID == "a2", "applied in order: the last alarm stands")
        #expect(m.connections.authentication["c1"]?.keyChanged == true, "the warning is not lost")
    }

    /// A lock while held clears what was kept: nothing of the earlier opening is replayed after it.
    @Test func aLockWhileHeldClearsTheBufferAndNothingIsReplayedAfterIt() async throws {
        defer { phone.close() }
        try await heldBackground()
        inject("credential.alarm", alarm("a1"))
        #expect(m.heldEvents.count == 1)
        try await m.lock()
        #expect(m.heldEvents.isEmpty)
        #expect(try await m.unlock(pin: pin) == .success)
        m.onForeground()
        #expect(m.alarm == nil, "no event crossed the lock")
    }

    /// More than the cap: the oldest go, and the foreground reads the state instead (the alarm, the account, the owner check),
    /// forgets the authentication it cannot read, and ends the unlock window.
    @Test func anOverflowTakesTheReadAgainFallback() async throws {
        defer { phone.close() }
        try await heldBackground()
        for i in 0..<(VaultManager.maxHeldEvents + 1) {
            m.onEvent(VaultMessage(inner: Inner(id: "e\(i)", type: "tag.changed", ts: Date(), body: Array("{}".utf8))))
        }
        #expect(m.heldEvents.count == VaultManager.maxHeldEvents && m.heldEventsOverflowed)
        let reads = seen("credential.version")
        m.onForeground()
        #expect(m.heldEvents.isEmpty && !m.heldEventsOverflowed)
        #expect(await waitFor { seen("credential.version") > reads }, "the alarm is read again")
    }

    // MARK: the relay's window, and flows in hand

    /// While a call holds the background the collection is a long poll (the WebSocket's window of unacked messages would fill with
    /// the held events); the build's mode is back at the foreground and when the call ends.
    @Test func theCollectionIsALongPollWhileHeldAndTheBuildsModeAfter() async throws {
        defer { phone.close() }
        try await openVault()
        let device = try #require(m.session).device
        func longPoll() -> Bool { device.mem.withLock { device.collectLongPoll } }
        m.holdCollection { true }
        await m.onBackground(budget: .seconds(2))
        #expect(longPoll() && device.collectMode == .longPoll)
        m.onForeground()
        #expect(!longPoll())
        m.holdCollection { true }
        await m.onBackground(budget: .seconds(2))
        #expect(longPoll())
        m.holdCollection { false }
        m.collectionHoldEnded()
        #expect(!longPoll() && m.session == nil, "closed, and back to the build's mode")
    }

    /// Past the cap of different held events the rest are acked (and kept in memory), so the relay's window of unacked messages
    /// does not fill, and the peer's `call.end` is received at once, not after the leases.
    @Test func moreThanTheCapOfHeldEventsLeavesRoomForTheCallsOwn() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        var events = try #require(m.session).api.callEvents().makeAsyncIterator()
        for i in 0..<40 { service.sendEvent("tag.changed", #"{"n":\#(i)}"#) }
        #expect(await waitFor { service.mailboxCounts.queued == 0 })
        // What the collection that was cut at the switch to the long poll may have taken is leased: it comes back after the lease.
        try await Task.sleep(for: .milliseconds(300))
        service.endLeases()
        #expect(await waitFor(seconds: 30) { service.mailboxCounts.leased == 32 }, "only the cap stays unacked: \(service.mailboxCounts)")
        service.sendCallEnd(callId)
        guard case .ended(let ended)? = await events.next() else { throw CallEventMissing() }
        #expect(ended.callId == callId, "received at once, with no wait for a lease")
    }

    /// An event a flow of this device is waiting for is not held back: a flow begun just before the app left the foreground does
    /// not time out.
    @Test func anEventAFlowIsWaitingForIsNotHeld() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        let device = try #require(m.session).device
        let waiting = Task { try await device.awaitEvent("grant.value", timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        service.sendEvent("grant.value", "{}")
        let got = try await waiting.value
        #expect(got.type == "grant.value")
        #expect(await waitFor { service.mailboxCounts.leased == 0 }, "acked: not held")
    }

    // MARK: the cap

    /// The warnings are held outside the cap: past 32 other events the alarm and the key warning are still unacked, and a process that
    /// ends loses neither.
    @Test func theAlarmAndTheKeyWarningSurviveAnOverflowOfOtherEvents() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        for i in 0..<39 { service.sendEvent("tag.changed", #"{"n":\#(i)}"#) }
        let raised = service.raiseCloneAlarm()
        service.sendEvent("connection.authenticate.result", #"{"connection_id":"c1","authenticated":true,"key_changed":true}"#)
        #expect(await waitFor(seconds: 30) { service.mailboxCounts.leased == 35 }, "32 others and the 3 warnings: \(service.mailboxCounts)")
        try await phone.restart()
        try await m.refresh()
        if m.phase != .unlocked { #expect(try await m.unlock(pin: pin) == .success) }
        service.endLeases()
        #expect(await waitFor(seconds: 30) { m.alarm?.alarmID == raised }, "the clone alarm comes back")
        #expect(await waitFor(seconds: 30) { m.connections.authentication["c1"]?.keyChanged == true }, "and the key warning")
    }

    /// The calls' own signals do not reset the cap: with call events between, no more than the cap (and the warnings) stay unacked.
    @Test func callSignalsBetweenEventsDoNotResetTheCap() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        // Every call signal is counted as it is handled by the device.
        var handledCount = 0
        let events = try #require(m.session).api.callEvents()
        let counting = Task { @MainActor in
            for await e in events {
                if case .ended = e { handledCount += 1 }
            }
        }
        defer { counting.cancel() }
        for round in 0..<4 {
            for i in 0..<10 { service.sendEvent("tag.changed", #"{"r":\#(round),"n":\#(i)}"#) }
            service.sendCallEnd(callId)
        }
        // All of it processed: every call signal handled, nothing left queued, the overflow acked.
        #expect(await waitFor(seconds: 60) { handledCount == 4 }, "each call signal was handled: \(handledCount)")
        // The device's own state, not the relay's leased count (which the vault's background traffic and real-time leases perturb): the
        // first 32 events are held (unacked), the 8 past the cap were handed over and acked (the app keeps them in memory), and each
        // call signal was handled. Within 20 s, far under the relay's 60 s lease, whose redelivery would refill a cleared set.
        func held() -> Int { m.session.map { d in d.device.mem.withLock { d.device.memory.heldIDs.count } } ?? -1 }
        #expect(
            await waitFor(seconds: 20) { held() == 32 && m.heldEvents.count == 8 },
            "held \(held()), acked and kept \(m.heldEvents.count)"
        )
        #expect(handledCount == 4)
        // And it stays so: nothing more is held or handed over.
        try await Task.sleep(for: .milliseconds(300))
        #expect(held() == 32 && m.heldEvents.count == 8 && handledCount == 4)
    }

    /// Whatever event was or was not received, the clone alarm is read after every unlock (`credential.version`).
    @Test func theAlarmIsReadAfterEveryUnlock() async throws {
        defer { phone.close() }
        try await openVault()
        let raised = service.raiseCloneAlarm(told: false)
        #expect(m.alarm == nil)
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await waitFor { m.alarm?.alarmID == raised }, "read at the unlock, with no event")
    }

    /// A `credential.alarm` event that arrives while the read at the unlock is on its way is not cleared by the read's older answer
    /// ("no alarm").
    @Test func anAlarmEventIsNotClearedByAnOlderRead() async throws {
        defer { phone.close() }
        try await openVault()
        let started = m.beginAlarmRead()
        m.onEvent(VaultMessage(inner: Inner(id: "ev1", type: "credential.alarm", ts: Date(), body: Array(alarm("a1").utf8))))
        #expect(m.alarm?.alarmID == "a1")
        m.finishAlarmRead(CredentialInfo(exists: true, version: 1, key: nil, updatedAt: nil, alarm: nil), started: started)
        #expect(m.alarm?.alarmID == "a1", "the older answer does not clear it")
        // A read that began after the event is current.
        let later = m.beginAlarmRead()
        m.finishAlarmRead(CredentialInfo(exists: true, version: 1, key: nil, updatedAt: nil, alarm: nil), started: later)
        #expect(m.alarm == nil)
    }

    // MARK: the held background is a background

    /// In a background a call holds, nothing is read that nobody asked for (the quiet reads), as in any background.
    @Test func noQuietReadWhileHeld() async throws {
        defer { phone.close() }
        try await openVault()
        m.holdCollection { true }
        await m.onBackground(budget: .seconds(2))
        #expect(m.inBackground && !m.backgrounded, "in the background, with the collection held")
        // The reads of the opening, which may still be on their way under load, are over once the count stays put.
        var before = seen("connection.list")
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let now = seen("connection.list")
            if now == before { break }
            before = now
        }
        try? await m.connections.refresh(quietly: true)
        #expect(seen("connection.list") == before, "no read in the background")
        m.onForeground()
        #expect(!m.inBackground)
    }

    /// The hold is decided at the start of the background's work, but the call may end during it: the collection then stops at the
    /// work's end, as without a call.
    @Test func aCallThatEndsDuringTheBackgroundWorkClosesTheConnectionAtItsEnd() async throws {
        defer { phone.close() }
        try await openVault()
        var asked = 0
        m.holdCollection {
            asked += 1
            return asked == 1
        }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session == nil && m.backgrounded && m.heldBackground == nil)
    }

    // MARK: the order

    /// An older alarm event redelivered after a newer one was applied (the buffered one, at the foreground) or after a read is dropped:
    /// the newest state wins.
    @Test func anOlderHeldAlarmEventDoesNotBeatANewerBufferedOne() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await openVault()
        let raised = service.raiseCloneAlarm(told: false)
        m.holdCollection { true }
        await m.onBackground(budget: .seconds(2))
        // The older event: held at the relay (frozen).
        service.sendEvent("credential.alarm", #"{"alarm_id":"\#(raised)","state":"frozen"}"#)
        #expect(await waitFor { service.mailboxCounts.leased >= 1 })
        // The newer one, already acked, kept in memory (rotation required), and the vault says so too.
        service.requireRotation()
        let newer = Date().addingTimeInterval(60)
        let sync = #"{"kind":"credential.alarm","alarm_id":"\#(raised)","state":"rotation_required"}"#
        m.onEvent(VaultMessage(inner: Inner(id: "newer", type: "sync.event", ts: newer, body: Array(sync.utf8))))
        m.onForeground()
        #expect(await waitFor { m.alarm?.state == "rotation_required" }, "the newer state is applied")
        service.endLeases()
        try await Task.sleep(for: .milliseconds(500))
        #expect(m.alarm?.state == "rotation_required", "the older event, redelivered, does not beat it")
    }

    // MARK: what is handled while held

    /// What ends the session is not held: `device.unlinked` is acked and reaches the manager at once, not kept for the foreground.
    @Test func deviceUnlinkedIsHandledWhileHeld() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        service.unlinkThisPhone(reason: "transferred")
        #expect(await waitFor { service.mailboxCounts.leased == 0 }, "acked, not left for the foreground")
        #expect(m.heldEvents.isEmpty && !m.eventsMissedWhileHeld, "and not kept in memory either")
    }

    @Test func vaultHeldIsAckedWhileHeld() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        service.sendEvent("vault.held", "{}")
        #expect(await waitFor { service.mailboxCounts.leased == 0 }, "not left unacked")
    }

    /// `sync.event` is held outside the cap: with the cap of others full, it is still left unacked.
    @Test func syncEventIsHeldOutsideTheCap() async throws {
        defer { phone.close() }
        service.leasesCollected = 60
        try await heldBackground()
        for i in 0..<40 { service.sendEvent("tag.changed", #"{"n":\#(i)}"#) }
        service.sendEvent("sync.event", #"{"kind":"vault.release","release_number":9}"#)
        func held() -> Int { m.session.map { d in d.device.mem.withLock { d.device.memory.heldIDs.count } } ?? -1 }
        #expect(await waitFor(seconds: 20) { held() == 33 }, "32 others and the sync event: \(held())")
    }

    /// A sign-out while held clears what was kept: nothing is replayed after it.
    @Test func aSignOutWhileHeldClearsWhatWasKept() async throws {
        defer { phone.close() }
        try await heldBackground()
        m.onEvent(VaultMessage(inner: Inner(id: "x", type: "credential.alarm", ts: Date(), body: Array(alarm("a1").utf8))))
        #expect(m.heldEvents.count == 1)
        m.phase = .signedOut
        #expect(m.heldEvents.isEmpty)
        m.onForeground()
        #expect(m.alarm == nil)
    }
}
