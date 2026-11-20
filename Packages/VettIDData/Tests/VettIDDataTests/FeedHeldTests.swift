import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// (Rule 3) The feed while the vault's release is checked (``FeedManager+Held``): events and arrivals wait, in order and
/// bounded, and come when the check is over or the release gate lifts, after the reads under way; none overtakes them, an
/// item notified among the held arrivals is not notified again for a change no newer, a waiting-asks replay waits with
/// them (or, while the gate pauses the work, for the lift's full read); an owner check due or held, or a clear, drops them.
/// Mirrors vettid-android `FeedManagerTest` (#392).
@MainActor
@Suite struct FeedHeldTests {
    let ops = FakeFeedOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    let state = GateState()

    /// The release check and the gates, as the vault manager tells them: [paused] is part of [gated], as
    /// ``VaultManager/featuresGated()`` includes ``ReleaseUpdateManager/holdsFeatures``.
    @MainActor
    final class GateState {
        var checking = false
        var paused = false
        var ownerGated = false
        var arrived: [String] = []
        var replayed: [String] = []
    }

    func manager() -> FeedManager {
        let ops = ops, now = now, s = state
        let f = FeedManager(ops: { ops }, gated: { s.ownerGated || s.paused }, checking: { s.checking }, paused: { s.paused }, ownerGated: { s.ownerGated }, now: { now })
        f.onArrival = { s.arrived.append("\($0.itemID)@\($0.seq)") }
        f.onWaitingAsk = { s.replayed.append($0.itemID) }
        // The vault opened just before the events of these tests were sent (``event(_:sent:)``).
        f.vaultOpened(at: now.addingTimeInterval(-1))
        return f
    }

    func event(_ item: FeedItem, sent: Date? = nil) -> VaultMessage {
        var b = JsonBuilder().string("item_id", item.itemID).uint("seq", UInt64(item.seq)).string("kind", item.kind).string("at", item.at).string("status", item.status).string("priority", item.priority)
        if let r = item.ref { b = b.string("ref", r) }
        return VaultMessage(inner: Inner(id: Ulid.new(), type: "feed.event", ts: sent ?? now, body: b.bytes()))
    }

    func sync() -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: now, body: Array(#"{"kind":"feed.updated"}"#.utf8)))
    }

    func id(_ i: FeedItem) -> String { "\(i.itemID)@\(i.seq)" }

    /// An open feed, read in full, with the check under way.
    func checked() async throws -> FeedManager {
        ops.add("message.received", at: now)
        let f = manager()
        try await f.refresh()
        state.checking = true
        return f
    }

    @Test func anEventDuringTheCheckWaitsAndNotifiesWhenItEnds() async throws {
        let f = try await checked()
        let next = ops.add("connection.added", at: now)
        f.onEvent(event(next))
        #expect(state.arrived.isEmpty && f.items.count == 1, "neither notified nor applied during the check")
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(next)] && f.items.count == 2 && f.cursor == next.seq)
    }

    /// The opening's full read already brought the item: it notifies as the feed lists it, once.
    @Test func aHeldEventTheReadCoversNotifiesTheListedItem() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        state.checking = true
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item)) // before the read: held
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(item)])
    }

    @Test func aHeldItemReadMeanwhileIsNotNotified() async throws {
        let f = try await checked()
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item))
        try await f.refresh()
        try await f.setStatus(item.itemID, status: FeedManager.statusRead)
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived.isEmpty)
    }

    /// A catch-up during the check brings an item (held as an arrival), and its event is held too: one notification.
    @Test func aHeldEventOfAnItemThatArrivedAmongTheHeldIsNotNotifiedTwice() async throws {
        let f = try await checked()
        let item = ops.add("connection.added", at: now)
        f.onEvent(sync())
        #expect(await eventually { f.cursor == item.seq })
        f.onEvent(event(item))
        #expect(state.arrived.isEmpty)
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(item)])
    }

    /// Only what is no newer is not notified twice: a newer change of the item notifies.
    @Test func aNewerChangeOfAnItemNotifiedAmongTheHeldIsNotified() async throws {
        let f = try await checked()
        let item = ops.add("approval.pending", at: now, ref: "r1")
        f.onEvent(sync())
        #expect(await eventually { f.cursor == item.seq })
        var changed = item
        ops.seq += 1
        changed.seq = ops.seq
        f.onEvent(event(changed))
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(item), id(changed)])
    }

    /// The check is over but a read is under way: what was held waits for it, and a live event that comes meanwhile comes
    /// after the held ones.
    @Test func aLiveEventAfterTheCheckNeverOvertakesTheHeldOnes() async throws {
        let f = try await checked()
        let held = ops.add("connection.added", at: now)
        f.onEvent(event(held))
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        f.onEvent(sync())
        #expect(await eventually { ops.calls.count == 2 }, "the catch-up is under way")
        state.checking = false
        f.releaseHeld()
        let live = ops.add("grant.request", at: now, ref: "g1")
        f.onEvent(event(live))
        #expect(state.arrived.isEmpty, "both wait for the read")
        ops.listGate = nil
        gate.complete()
        #expect(await eventually { state.arrived.count == 2 })
        #expect(state.arrived == [id(held), id(live)])
    }

    @Test func atMost64EventsAndArrivalsAreHeldTheOldestGoFirst() async throws {
        let f = try await checked()
        let items = (0..<70).map { _ in ops.add("message.received", at: now) }
        for i in items { f.onEvent(event(i)) }
        #expect(f.heldEvents.count == FeedManager.heldLimit)
        #expect(f.heldEvents.first.flatMap { FeedItem.of($0.object) }?.itemID == items[6].itemID)
    }

    /// A failed check pauses the work: what was held waits for the lift; a check that ended behind keeps it too.
    @Test func whileTheGatePausesTheWorkTheyWaitForTheLift() async throws {
        let f = try await checked()
        state.paused = true // the check's read failed
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item))
        state.checking = false // the check ended behind
        f.releaseHeld()
        #expect(state.arrived.isEmpty && f.heldEvents.count == 1)
        state.paused = false // the vault moved: the gate lifts
        f.releaseHeld()
        #expect(state.arrived == [id(item)])
    }

    @Test func anOwnerCheckDueOrHeldDropsThem() async throws {
        let f = try await checked()
        f.onEvent(event(ops.add("connection.added", at: now)))
        state.checking = false
        state.ownerGated = true
        f.releaseHeld()
        #expect(state.arrived.isEmpty && !f.queuesBehind)
    }

    /// What comes while the owner check is due or held is not held for later, even during the release check.
    @Test func nothingIsHeldWhileTheOwnerCheckIsDueOrHeld() async throws {
        let f = try await checked()
        state.ownerGated = true
        f.onEvent(event(ops.add("connection.added", at: now)))
        #expect(!f.queuesBehind)
        state.ownerGated = false
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived.isEmpty)
    }

    @Test func aClearDropsThem() async throws {
        let f = try await checked()
        f.onEvent(event(ops.add("connection.added", at: now)))
        f.clear()
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived.isEmpty && !f.queuesBehind)
    }

    /// The feed was not loaded when the check ended: it is read, and what was held comes after the read.
    @Test func aFeedNotLoadedIsReadFirst() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        state.checking = true
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item))
        state.checking = false
        f.releaseHeld()
        #expect(await eventually { state.arrived == [id(item)] })
        #expect(f.load == .loaded)
    }

    // MARK: the review's cases

    /// A read that fails after the check does not stall the feed: the next event reads it, and what was held comes.
    @Test func aFailedReadAfterTheCheckDoesNotStallTheFeed() async throws {
        ops.add("message.received", at: now)
        ops.failing = ["list"]
        let f = manager()
        try? await f.refresh()
        #expect(f.load == .failed)
        state.checking = true
        let held = ops.add("connection.added", at: now)
        f.onEvent(event(held))
        state.checking = false
        f.releaseHeld()
        #expect(await eventually { ops.calls.count == 2 && f.readsRunning == 0 }, "its read failed")
        ops.failing = []
        let live = ops.add("grant.request", at: now, ref: "g1")
        f.onEvent(event(live))
        #expect(await eventually { state.arrived.count == 2 }, "\(state.arrived)")
        #expect(state.arrived == [id(held), id(live)] && f.load == .loaded)
    }

    /// The gate lifts: what was held waits for a full read, so an item read elsewhere during the pause does not alert.
    @Test func theLiftReleasesAfterAFullRead() async throws {
        let f = try await checked()
        state.paused = true
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item))
        _ = try await ops.feedUpdate(item.itemID, status: FeedManager.statusRead) // on another device; its sync.event dropped
        f.onEvent(sync())
        state.checking = false
        state.paused = false
        f.releaseHeld(afterFullRead: true)
        #expect(await eventually { !f.queuesBehind && f.readsRunning == 0 })
        #expect(state.arrived.isEmpty, "\(state.arrived)")
        #expect(f.items.first { $0.itemID == item.itemID }?.status == FeedManager.statusRead)
    }

    /// The mailbox's backlog at an opening (sent before the vault opened) is covered by the opening's read and stays silent;
    /// what the vault sent after the opening notifies.
    @Test func theBacklogSentBeforeTheOpeningIsNotNotified() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        f.vaultOpened(at: now)
        state.checking = true
        let backlog = ops.add("connection.added", at: now)
        f.onEvent(event(backlog, sent: now.addingTimeInterval(-120)))
        let fresh = ops.add("grant.request", at: now, ref: "g1")
        f.onEvent(event(fresh, sent: now.addingTimeInterval(1)))
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(fresh)])
    }

    /// A released arrival counts for the waiting asks as a live one: an owner check passed while it was held opens the
    /// window, and the replay does not notify it again.
    @Test func aReleasedArrivalIsNotReplayedAgain() async throws {
        let f = manager()
        try await f.refresh()
        state.checking = true
        let ask = ops.add("connection.authenticate.requested", at: now, ref: "r1")
        f.onEvent(sync())
        #expect(await eventually { f.heldArrivals.count == 1 })
        f.openWaitingAsks()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(ask)])
        try await f.refresh()
        f.replayWaitingAsks(approvals())
        #expect(state.replayed.isEmpty)
    }

    /// Two catch-ups bring the same item during the check: it is held once, as it is now, and notifies once.
    @Test func anItemHeldTwiceNotifiesOnce() async throws {
        let f = try await checked()
        let item = ops.add("approval.pending", at: now, ref: "r1")
        f.onEvent(sync())
        #expect(await eventually { f.cursor == item.seq })
        let changed = try await ops.feedUpdate(item.itemID, status: FeedManager.statusActive)
        f.onEvent(sync())
        #expect(await eventually { f.cursor == changed.seq })
        #expect(f.heldArrivals.count == 1)
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(changed)])
    }

    /// The check ended behind with something held: an event that comes then is dropped (the vault is behind), not queued.
    @Test func anEventWhileBehindIsDroppedNotQueued() async throws {
        let f = try await checked()
        let held = ops.add("connection.added", at: now)
        f.onEvent(event(held))
        state.checking = false
        state.paused = true
        let behind = ops.add("grant.request", at: now, ref: "g1")
        f.onEvent(event(behind))
        #expect(f.heldEvents.count == 1)
        state.paused = false
        f.releaseHeld(afterFullRead: true)
        #expect(await eventually { !f.queuesBehind && f.readsRunning == 0 })
        #expect(state.arrived == [id(held)])
    }

    @Test func atMost64ArrivalsAreHeldInOrder() async throws {
        let f = try await checked()
        let items = (0..<70).map { _ in ops.add("message.received", at: now) }
        f.onEvent(sync())
        #expect(await eventually { f.cursor == items.last?.seq })
        #expect(f.heldArrivals.map(\.item.itemID) == items.suffix(FeedManager.heldLimit).map(\.itemID))
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == items.suffix(FeedManager.heldLimit).map(id))
    }

    @Test func aHeldArrivalReadMeanwhileIsNotNotified() async throws {
        let f = try await checked()
        let item = ops.add("connection.added", at: now)
        f.onEvent(sync())
        #expect(await eventually { f.heldArrivals.count == 1 })
        try await f.setStatus(item.itemID, status: FeedManager.statusRead)
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived.isEmpty)
    }

    /// Two held events of one item that the read covers: the listed item notifies once.
    @Test func twoCoveredEventsOfOneItemNotifyOnce() async throws {
        let f = try await checked()
        let item = ops.add("approval.pending", at: now, ref: "r1")
        f.onEvent(event(item))
        let changed = try await ops.feedUpdate(item.itemID, status: FeedManager.statusActive)
        f.onEvent(event(changed))
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(changed)])
    }

    /// A change notified live, then delivered again during a check that began again (the opening's mark is older): it does
    /// not notify twice.
    @Test func aChangeNotifiedLiveIsNotNotifiedAgainByARestartedCheck() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        try await f.refresh()
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item))
        #expect(state.arrived == [id(item)], "live")
        state.checking = true // a re-read that no longer verifies: the check again
        f.onEvent(event(item)) // redelivered
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived == [id(item)])
    }

    /// The phone's clock until the opening's first answer gives the vault's (``FeedManager/openingMarked(_:opening:)``),
    /// for that opening only: a release before it judges by the phone's clock, and a mark told for an earlier opening is
    /// not taken.
    @Test func theOpeningsMarkIsThePhonesClockUntilItsFirstAnswerAndOnlyForItsOpening() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        let earlier = f.vaultOpened(at: now.addingTimeInterval(-600))
        let current = f.vaultOpened(at: now)
        f.openingMarked(now.addingTimeInterval(-3_600), opening: earlier)
        #expect(f.openedAt == now, "an earlier opening's mark is not taken")
        state.checking = true
        let item = ops.add("connection.added", at: now)
        f.onEvent(event(item, sent: now.addingTimeInterval(-30)))
        try await f.refresh()
        state.checking = false
        f.releaseHeld()
        #expect(state.arrived.isEmpty, "released before the first answer: judged by the phone's clock")
        f.openingMarked(now.addingTimeInterval(-60), opening: current)
        #expect(f.openedAt == now.addingTimeInterval(-60))
    }

    /// A mark is fixed once: a second answer for the same opening (an earlier device's, landing after a new one began the
    /// opening again) is not taken.
    @Test func theMarkIsFixedOnce() {
        let f = manager()
        let n = f.vaultOpened(at: now, uptime: 100)
        #expect(f.openingToBeginAgain?.opening == n)
        f.openingMarked(now.addingTimeInterval(-60), opening: n)
        #expect(f.markFixed && f.openingToBeginAgain == nil)
        f.openingMarked(now.addingTimeInterval(-30), opening: n)
        #expect(f.openedAt == now.addingTimeInterval(-60))
    }

    // MARK: the waiting asks

    func approvals() -> [PendingApproval] {
        [.authentication(AuthenticationRequest(requestID: "r1", connectionID: "c1", context: nil, receivedAt: now.addingTimeInterval(-60), exp: nil))]
    }

    @Test func aWaitingAskReplayedDuringTheCheckComesWhenItEnds() async throws {
        let ask = ops.add("connection.authenticate.requested", at: now, ref: "r1")
        let f = manager()
        try await f.refresh()
        f.openWaitingAsks()
        try await f.refresh()
        state.checking = true
        f.replayWaitingAsks(approvals())
        #expect(state.replayed.isEmpty)
        state.checking = false
        f.releaseHeld()
        #expect(state.replayed == [ask.itemID] && state.arrived.isEmpty, "as a waiting ask, once")
    }

    /// The feed's full read came before the gate paused the work: the replay waits for the lift's full read, then runs.
    @Test func aWaitingAskReplayWhileThePauseWaitsForTheLiftsFullRead() async throws {
        let ask = ops.add("connection.authenticate.requested", at: now, ref: "r1")
        let f = manager()
        f.openWaitingAsks()
        try await f.refresh()
        state.paused = true
        f.replayWaitingAsks(approvals())
        #expect(state.replayed.isEmpty)
        state.paused = false
        #expect(state.replayed.isEmpty, "not before the lift's read")
        try await f.refresh()
        #expect(state.replayed == [ask.itemID])
    }
}

// swiftlint:enable line_length
