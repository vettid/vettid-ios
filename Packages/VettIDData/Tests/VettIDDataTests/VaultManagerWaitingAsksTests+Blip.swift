import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// (ANDROID-PLAN 0.1.134, as vettid-android #411) Unlocked, then only Unreachable, then Unlocked is the same opening: a
/// status read that could not be made closed nothing. The feed (its cursor, what it notified, what it holds) and the
/// opening's mark are kept, what the vault sent meanwhile notifies as it would have, and the release is checked again. Any
/// other phase in between ends the opening.
extension VaultManagerWaitingAsksTests {
    /// The vault open, then a status read that fails: published as Unreachable over it, through ``VaultManager/refresh()``.
    func blip() async throws {
        service.statusForbidden = true
        try await m.refresh()
        #expect(m.phase.isUnreachable, "\(m.phase)")
    }

    /// The status read works again: the vault is open.
    func back() async throws {
        service.statusForbidden = false
        try await m.refresh()
        #expect(m.phase == .unlocked)
    }

    @Test func aFailedStatusReadOverTheOpenVaultKeepsTheFeedAndItsMark() async throws {
        defer { phone.close() }
        let id = try await connected()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { live.count == 1 })
        let (cursor, notified, items) = (m.feed.cursor, m.feed.lastNotified, m.feed.items)
        let (mark, opening) = (try #require(m.feed.openedAt), m.feed.opening)
        #expect(cursor > 0 && !notified.isEmpty)

        try await blip()
        #expect(m.feed.load == .loaded && m.feed.cursor == cursor && m.feed.lastNotified == notified, "kept while Unreachable")
        try await back()
        #expect(m.feed.openedAt == mark && m.feed.opening == opening, "the same opening: no new mark")
        #expect(await eventually { m.feed.load == .loaded && !m.releaseUpdate.checking })
        try await settled()
        #expect(m.feed.cursor == cursor && m.feed.lastNotified == notified && m.feed.items == items)
        #expect(live.count == 1, "nothing notified again: \(live)")
    }

    /// An item sent during the blip waits (no release check runs then) and notifies once the check that restarts at the
    /// return passes: judged against the kept mark, so once.
    @Test func anItemDuringTheBlipNotifiesOnceTheCheckPasses() async throws {
        defer { phone.close() }
        let id = try await connected()
        try await blip()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { m.feed.heldEvents.count == 1 }, "held while Unreachable")
        #expect(live.isEmpty)
        try await back()
        #expect(await eventually { live.count == 1 }, "after the check: \(live)")
        try await settled()
        #expect(live.count == 1, "once: \(live)")
    }

    /// Fail closed: with the release check failing before the blip, neither what it held nor what comes during the blip
    /// notifies before a check passes after the return.
    @Test func nothingNotifiesBeforeTheReleaseIsConfirmed() async throws {
        defer { phone.close() }
        let id = try await connected()
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { m.feed.heldEvents.count == 1 })
        try await blip()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { m.feed.heldEvents.count == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(live.isEmpty, "nothing while Unreachable: \(live)")
        try await back()
        await failReleaseCheck()
        try await Task.sleep(for: .milliseconds(200))
        #expect(live.isEmpty, "nothing while the check fails: \(live)")
        await passReleaseCheck()
        #expect(await eventually { live.count == 2 }, "\(live)")
        try await settled()
        #expect(live.count == 2)
    }

    /// An item held by the release check before the blip stays held across it, and notifies once the check that restarts
    /// at the return passes: it was sent after the opening's mark, which is kept.
    @Test func whatTheCheckHeldIsKeptAndTheCheckRestarts() async throws {
        defer { phone.close() }
        let id = try await connected()
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { m.feed.heldEvents.count == 1 })
        try await blip()
        #expect(!m.releaseUpdate.checking, "no check while the vault is not open")
        #expect(m.feed.heldEvents.count == 1, "kept while Unreachable")
        let fetches = service.manifestFetches
        try await back()
        #expect(m.releaseUpdate.checking, "the release is checked again at the return")
        #expect(await eventually { service.manifestFetches > fetches }, "the manifest read again")
        #expect(live.isEmpty, "nothing while the check fails")
        await passReleaseCheck()
        #expect(await eventually { live.count == 1 }, "\(live)")
        try await settled()
        #expect(live.count == 1)
    }

    /// A passed check's waiting-asks window does not outlive the blip (the replay ends with the lists it was judged against):
    /// the kept feed closes it, as a cleared one did.
    @Test func theBlipClosesTheWaitingAsksWindow() async throws {
        defer { phone.close() }
        _ = try await connected()
        m.feed.openWaitingAsks()
        #expect(m.feed.arrivedSinceCheck != nil)
        try await blip()
        #expect(m.feed.load == .loaded, "the feed is kept")
        #expect(m.feed.arrivedSinceCheck == nil, "the window is closed")
    }

    /// Unlocked → Unreachable → Locked → Unlocked: the lock ended the opening. The feed is cleared at the lock, and the
    /// return is a new opening with a new mark.
    @Test func aLockBetweenEndsTheOpening() async throws {
        defer { phone.close() }
        let id = try await connected()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { live.count == 1 })
        let opening = m.feed.opening
        try await blip()
        #expect(m.feed.load == .loaded)
        service.statusForbidden = false
        service.status("locked")
        try await m.refresh()
        #expect(m.phase == .locked)
        #expect(m.feed.load == .notLoaded && m.feed.cursor == 0 && m.feed.lastNotified.isEmpty, "cleared at the lock")
        service.status("unlocked")
        try await m.refresh()
        #expect(m.phase == .unlocked)
        #expect(m.feed.opening == opening + 1, "a new opening")
    }

    /// A wipe that did not finish (Unreachable, ``FailureKind/eraseFailed``) is no status read: it ends the opening and its
    /// feed.
    @Test func aWipeThatDidNotFinishEndsTheOpening() async throws {
        defer { phone.close() }
        _ = try await connected()
        m.phase = WipeRun.failedPhase
        #expect(!m.openingPaused)
        #expect(m.feed.load == .notLoaded && m.feed.cursor == 0, "cleared")
    }

    /// Unreachable twice in a row (another kind) is still only Unreachable: the opening goes on.
    @Test func unreachableTwiceStillContinues() async throws {
        defer { phone.close() }
        _ = try await connected()
        let (mark, opening) = (try #require(m.feed.openedAt), m.feed.opening)
        try await blip()
        service.statusForbidden = false
        service.status("unlocked", noVault: true)
        try await m.refresh()
        #expect(m.phase == .unreachable(.noVault))
        #expect(m.feed.load == .loaded)
        service.status("unlocked")
        try await m.refresh()
        #expect(m.phase == .unlocked && m.feed.openedAt == mark && m.feed.opening == opening)
    }
}
