import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// (Rule 3) The release check and the notifications, end to end: an item that arrives while a failing check holds the
/// features notifies once the check passes, and a passed owner check's waiting-asks replay that comes due meanwhile runs
/// after the lift's reads.
extension VaultManagerWaitingAsksTests {
    /// A re-read that no longer verifies the vault's release: the check holds the features again (fail closed).
    func failReleaseCheck() async {
        service.release3ListedAs = 2
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.checking && m.featuresGated())
    }

    /// A read that verifies it: the gate lifts.
    func passReleaseCheck() async {
        service.release3ListedAs = 3
        await m.releaseUpdate.refreshOffer()
        #expect(!m.releaseUpdate.checking && !m.featuresGated())
    }

    @Test func anItemDuringAFailingReleaseCheckNotifiesOnceItPasses() async throws {
        defer { phone.close() }
        let id = try await connected()
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(live.isEmpty, "nothing while the check fails")
        await passReleaseCheck()
        #expect(await eventually { live.count == 1 }, "\(live)")
        try await settled()
        #expect(live.count == 1 && replays.isEmpty, "once")
    }

    /// The feed's opening mark is on the vault's clock, as its messages' `ts` are, whichever way the phone's clock is off: an
    /// item sent during a failing check notifies once it passes, also with the vault's clock two minutes behind the phone's.
    @Test(arguments: [-120.0, 120.0])
    func theOpeningMarkIsOnTheVaultsClock(skew: TimeInterval) async throws {
        defer { phone.close() }
        service.stampsOnVaultClock = true
        service.advanceVaultClock(skew)
        let id = try await connected()
        // The mark is stored after a main-actor hop: waited for, not raced.
        #expect(await eventually { m.feed.markFixed })
        let mark = try #require(m.feed.openedAt)
        #expect(abs(mark.timeIntervalSinceNow - skew) < 30, "the vault's clock, not the phone's: \(mark.timeIntervalSinceNow)")
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        try await Task.sleep(for: .milliseconds(200))
        await passReleaseCheck()
        #expect(await eventually { live.count == 1 }, "\(live)")
    }

    /// A new device of this process while the opening's mark is still the phone's clock (no answer came before the first
    /// device was let go): the opening begins again on it, so its first answer puts the mark on the vault's clock.
    @Test func aNewDeviceBeginsTheOpeningAgainWhileTheMarkIsThePhones() async throws {
        defer { phone.close() }
        service.stampsOnVaultClock = true
        service.advanceVaultClock(120)
        _ = try await connected()
        #expect(await eventually { m.feed.markFixed })
        // Fixed already: a new device does not begin the opening again.
        try await m.dropSession(forget: false)
        _ = try await m.openSession()
        let fresh = try #require(m.session?.device)
        #expect(fresh.mem.withLock { fresh.opening } == nil, "not begun again")
        // As if no answer had come before the device was let go: the phone's clock, not fixed.
        m.feed.markFixed = false
        m.feed.openedAt = Date()
        try await m.dropSession(forget: false)
        _ = try await m.openSession()
        try await m.connections.refresh(quietly: true)
        #expect(await eventually { m.feed.markFixed }, "begun again on the new device")
        let mark = try #require(m.feed.openedAt)
        #expect(mark.timeIntervalSinceNow > 60, "the vault's clock, two minutes ahead: \(mark.timeIntervalSinceNow)")
    }

    /// A device made while the opening is paused (only Unreachable since Unlocked) begins it again too: the same opening goes
    /// on at the return.
    @Test func aDeviceMadeDuringAPausedOpeningBeginsItAgain() async throws {
        defer { phone.close() }
        _ = try await connected()
        #expect(await eventually { m.feed.markFixed })
        m.feed.markFixed = false
        service.statusForbidden = true
        try await m.refresh()
        #expect(m.openingPaused)
        try await m.dropSession(forget: false)
        _ = try await m.openSession()
        let fresh = try #require(m.session?.device)
        #expect(fresh.mem.withLock { fresh.opening } != nil, "begun again during the pause")
    }

    /// A cold start with the vault open: what the mailbox delivers first is the backlog of what changed while the app was
    /// away (here a day old on the vault's clock), and stays silent; the opening's moment is the vault's clock at its first
    /// answer, never a vault time learnt from the backlog; an item the vault sends after the opening notifies
    /// (ANDROID-PLAN 0.1.134 Notification modes 7, IOS-PLAN §6.7).
    @Test func aColdStartsBacklogStaysSilentAndAFreshItemNotifies() async throws {
        defer { phone.close() }
        service.stampsOnVaultClock = true
        service.freezeVaultClock()
        let frozen = Date()
        let id = try await connected()
        try await phone.restart {
            service.advanceVaultClock(-86_400)
            _ = try service.feedItemArrives("message.received", connectionID: id)
            _ = try service.feedItemArrives("message.received", connectionID: id)
            // Back, and the app was away a while (within the requests' validity, which the vault's clock judges).
            service.advanceVaultClock(86_400 + 90)
        }
        try await m.refresh()
        #expect(await eventually { m.phase == .unlocked && m.feed.load == .loaded && !m.releaseUpdate.checking })
        // The opening's reads are over (an item that comes during a full read is read, not notified, as at any time).
        try await settled()
        let mark = try #require(m.feed.openedAt)
        let off = mark.timeIntervalSince(frozen.addingTimeInterval(90))
        #expect(abs(off) < 30, "the vault's clock at the opening, not the backlog's: \(off)")
        #expect(live.isEmpty, "the backlog is silent: \(live)")
        service.advanceVaultClock(30)
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { live.count == 1 }, "\(live)")
        // A background and a return let the device's collection go and come back, with no new opening: the mark stays.
        await m.onBackground()
        m.onForeground()
        #expect(await eventually { m.feed.load == .loaded })
        #expect(m.feed.openedAt == mark, "fixed in the feed")
    }

    @Test func aCheckPassedElsewhereWhileAFailingReleaseCheckHoldsReplaysAfterTheLift() async throws {
        defer { phone.close() }
        let id = try await connected()
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        // The test vault sends `feed.event` for these while this phone is held (the vault sends none then): whenever they come,
        // nothing that comes while held is kept for later, so none notifies as a new arrival at the lift.
        let expected = try asksWhileHeld(id)
        await failReleaseCheck()
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        try await Task.sleep(for: .milliseconds(300))
        #expect(replays.isEmpty, "nothing while the release check fails")
        await passReleaseCheck()
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected && live.isEmpty, "once, and nothing else")
    }
}
