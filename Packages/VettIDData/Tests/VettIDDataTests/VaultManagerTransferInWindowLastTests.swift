import Foundation
import Testing
@testable import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// The last collects of a settlement window (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5; the shared rule with Android #307):
/// a refusal of the last one gives one more, after `retry_after`; once that one went, a background gives nothing more; a
/// session's collector is followed after its session went; and a window kept alive in the background collects slowly.
extension VaultManagerTransferInTests {
    /// The window's collect handed the pairing at 150 s, a freeze to 170 s cutting it: the end goes to the cap (185 s),
    /// and the last collect there waits to 225 s, released at 225 s. Returns with the pairing leased.
    func lastCollectAfterAFreeze() async throws {
        try await windowOnFrozenClocks()
        m.session?.device.stop()
        try await advance(150)
        let sent = m.config.uptime()
        #expect(await eventually { m.moveFlags.book.windowCollectSent == sent }, "a window collect went out at 150 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true, wait: 0)
        phone.uptimeAhead += 20
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15] }, "to the cap: \(phone.windowPauses.lengths)")
        try await advance(15)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, 40] }, "the hold: \(phone.windowPauses.lengths)")
        try await advance(40)
    }

    /// The last collect refused `429` (`Retry-After: 7`): one more goes 7 s later, on a request signed anew, and applies
    /// the move once the pairing is back.
    @Test func aRefusedLastCollectGetsOneMoreAfterItsRetryAfter() async throws {
        defer { phone.close() }
        try await lastCollectAfterAFreeze()
        service.refuseNextCollects(1)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, 40, 7] }, "\(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// Once the one more last collect went, a background while it is out gives nothing more: nothing is decided in the
    /// background, and back in the foreground the window drops, with no hold and no last collect after it.
    @Test func aBackgroundAfterTheOneMoreLastCollectGivesNothingMore() async throws {
        defer { phone.close() }
        try await lastCollectAfterAFreeze()
        service.refuseNextCollects(1)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, 40, 7] }, "\(phone.windowPauses.lengths)")
        try await advance(7)
        // The one more last collect is handed the pairing, and held out.
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 0
        service.holdsCollectAnswers = gate
        service.losesCollectAnswers = 1
        service.endLeases()
        let finals = m.moveFlags.book.finalCollects
        phone.windowPauses.release()
        #expect(await eventually { gate.waiting > 0 && m.moveFlags.book.finalCollects == finals + 1 }, "the one more goes")
        await m.onBackground(budget: .seconds(1))
        service.holdsCollectAnswers = nil
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.record.value.transferStartedMs != nil, "nothing decided in the background")
        m.onForeground()
        #expect(await eventually { m.record.value.transferStartedMs == nil }, "dropped back in the foreground")
        #expect(m.moveFlags.book.finalCollects == finals + 1, "no last collect more")
        #expect(phone.windowPauses.lengths == [90, 15, 40, 7], "no hold more: \(phone.windowPauses.lengths)")
    }

    /// A cut of the collector of a session's device (not the window's) is followed after the session went (a
    /// background): the end moves out.
    @Test func aCutOfAGoneSessionsCollectorIsFollowed() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let old = try #require(m.session?.device)
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.session != nil }, "a session of the new process")
        let new = try #require(m.session?.device)
        #expect(new !== old)
        new.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        phone.windowPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, old)
        // 24 s on, in steps the clock sees as no freeze: a lease of what is cut now outlasts the first end (90 s).
        for _ in 0..<3 {
            phone.uptimeAhead += 8
            clock.follow(m, old)
        }
        let until = clock.until
        new.collectorRequest(true, of: new.collectRound)
        new.collectorSent(of: new.collectRound, wait: new.collectorWait)
        new.collectorFailed(URLError(.networkConnectionLost), of: new.collectRound)
        m.session = nil
        clock.follow(m, old)
        #expect(clock.until > until, "the end moved out")
        clock.stop()
        phone.heartbeatPauses.release()
        phone.windowPauses.release()
    }

    /// Kept alive in the background, the window collects about every 15 s, not every second.
    @Test func aWindowInTheBackgroundCollectsSlowly() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        await m.onBackground(budget: .seconds(1))
        #expect(await eventually { m.moveFlags.book.windowPauseSeconds == VaultManager.backgroundCollectPause })
        m.onForeground()
        phone.windowPauses.release()
    }

    /// A collection's end after it was stopped, and a newer one began, is not the newer one's.
    @Test func aStoppedCollectionsEndIsNotTheNewerOnes() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let old = d.collectRound
        d.collectionEnded(RelayError(status: 404, code: RelayError.mailboxUnknown), of: old - 1)
        #expect(d.collectionEnded == nil, "a stale end")
        d.collectionEnded(RelayError(status: 404, code: RelayError.mailboxUnknown), of: old)
        #expect(d.collectionEnded == RelayError.mailboxUnknown)
    }

    /// A round handed messages whose ack is refused (a 4xx) mid-batch is a cut: the rest of the batch stays leased.
    @Test func aRoundThatWasHandedMessagesIsACutWhateverItsError() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let cuts = d.collectorCuts.count
        d.collectorFailed(RelayError(status: 403, code: "forbidden"), of: d.collectRound)
        #expect(d.collectorCuts.count == cuts, "a 4xx of a round handed nothing")
        d.collectorFailed(RelayError(status: 403, code: "forbidden"), handed: true, of: d.collectRound)
        #expect(d.collectorCuts.count == cuts + 1, "a 4xx of a round handed messages")
    }

    /// Once the one more last collect went, a background while it is out: the pairing, back during the background or on
    /// the return, is collected (a `wait=0` collect every 15 s in the background, one more back in the foreground) and
    /// applied, with no last collect more.
    @Test func thePairingBackAfterTheOneMoreLastCollectIsStillApplied() async throws {
        defer { phone.close() }
        try await lastCollectAfterAFreeze()
        service.refuseNextCollects(1)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, 40, 7] }, "\(phone.windowPauses.lengths)")
        try await advance(7)
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 0
        service.holdsCollectAnswers = gate
        service.losesCollectAnswers = 1
        service.endLeases()
        let finals = m.moveFlags.book.finalCollects
        phone.windowPauses.release()
        #expect(await eventually { gate.waiting > 0 && m.moveFlags.book.finalCollects == finals + 1 }, "the one more goes")
        await m.onBackground(budget: .seconds(1))
        // Only the window's collects take it: the collector, started again in the foreground, finds nothing.
        service.handsMessagesOnlyToWait = 0
        service.holdsCollectAnswers = nil
        // The pairing is back (its lease ended) before the one more last collect's answer is lost.
        service.endLeases()
        gate.open()
        m.onForeground()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending }, "the pairing applied")
        // The take-over's answers come to the collector.
        service.handsMessagesOnlyToWait = nil
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil }, "the take-over completed")
        #expect(m.moveFlags.book.finalCollects == finals + 1, "no last collect more")
    }

    /// A stream that pushed at the window's start, then nothing for 40 s, cut: what it may have pushed since is leased
    /// from its push, as late as the cut, so the end moves to the cut + V + 15 s (not to the last push + V + 15 s).
    @Test func aStreamsCutCountsFromTheCut() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        let d = try #require(m.session?.device)
        d.stop()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        d.collectorRequest(true, of: d.collectRound)
        d.collectorSent(of: d.collectRound, wait: nil)
        // 40 s on, in steps the clock sees as no freeze, with no push.
        for _ in 0..<5 {
            phone.uptimeAhead += 8
            clock.follow(m, d)
        }
        let cut = m.config.uptime()
        d.collectorFailed(URLError(.networkConnectionLost), of: d.collectRound)
        clock.follow(m, d)
        #expect(clock.until == cut + 75, "from the cut")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A freeze with the collector's stream open: it may have pushed, and leased, up to the wake, so the last collect
    /// waits to the wake + V + 15 s.
    @Test func aFreezeWithAStreamOpenHoldsFromTheWake() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        let d = try #require(m.session?.device)
        d.stop()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        d.collectorRequest(true, of: d.collectRound)
        d.collectorSent(of: d.collectRound, wait: nil)
        clock.follow(m, d)
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == m.config.uptime() + 75, "from the wake")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A stop with the collector's stream open is a cut from the stop.
    @Test func aStopWithAStreamOpenIsACutFromTheStop() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        d.start()
        let round = d.collectRound
        d.collectorRequest(true, of: round)
        d.collectorSent(of: round, wait: nil)
        #expect(d.streamOpen)
        let cuts = d.collectorCuts.count
        d.stop()
        #expect(d.collectorCuts.count == cuts + 1 && d.collectorCuts.sent?.wait == 0, "a cut")
        #expect((d.collectorCuts.sent?.at ?? 0) > (d.lastCollectorSent?.at ?? .infinity), "from the stop, not the open")
    }

    /// The collector the device makes passes a send's `wait` on: nil for its stream (0 after it, the stream open), a
    /// long poll's own.
    @Test func theDevicesCollectorPassesTheWaitThrough() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let c = d.collector(of: d.collectRound)
        d.collectorRequest(true, of: d.collectRound)
        c.onSent(nil)
        #expect(d.lastCollectorSent?.wait == 0 && d.streamOpen, "a stream's")
        c.onSent(25)
        #expect(d.lastCollectorSent?.wait == 25 && !d.streamOpen, "a long poll's")
    }

    /// A wipe (the mailbox gone) during the last look in the background ends the window as ended, not dropped.
    @Test func aWipeDuringTheLastLookEndsTheWindow() async throws {
        defer { phone.close() }
        try await oneMoreLastCollectInTheBackground()
        service.refusesCollect = true
        #expect(await eventually(within: .seconds(30)) { m.transferEnd == .stopped }, "ended")
        m.onForeground()
    }

    /// A sign-out or a wipe of the app (the session's end) during the last look in the background ends it.
    @Test func aSessionEndDuringTheLastLookEndsTheWindow() async throws {
        defer { phone.close() }
        try await oneMoreLastCollectInTheBackground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.moveFlags.book.settleWindow != nil, "the last look runs")
        m.moveFlags.book.sessionEnds += 1
        #expect(await eventually(within: .seconds(30)) { m.moveFlags.book.settleWindow == nil }, "the window ended")
        #expect(m.transferEnd != .timedOut, "not dropped: \(String(describing: m.transferEnd))")
        m.onForeground()
    }

    /// In the background, the last look makes a `wait=0` collect after each of its pauses, and no last collect more.
    @Test func theLastLookCollectsAfterEachPause() async throws {
        defer { phone.close() }
        phone.backgroundPauses.holding = true
        let finals = try await oneMoreLastCollectInTheBackground()
        #expect(await eventually { !phone.backgroundPauses.lengths.isEmpty }, "the last look pauses")
        let from = service.relay.requests.count
        phone.backgroundPauses.release()
        #expect(await eventually { collectWaits(from: from).contains(0) }, "a wait=0 collect after the pause")
        #expect(m.moveFlags.book.finalCollects == finals + 1, "no last collect more")
        phone.backgroundPauses.holding = false
        phone.backgroundPauses.release()
        m.onForeground()
    }

    /// A window's heartbeat stopped during its sleep follows nothing more: a session's device it had not seen is not
    /// marked to collect on connections of its own.
    @Test func aStoppedHeartbeatFollowsNothingMore() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let old = try #require(m.session?.device)
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.session != nil }, "a session of the new process")
        let held = m.session
        let new = try #require(held?.device)
        phone.heartbeatPauses.holding = true
        phone.windowPauses.holding = true
        m.session = nil
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, old)
        #expect(await eventually { !phone.heartbeatPauses.lengths.isEmpty }, "the heartbeat sleeps")
        m.session = held
        clock.stop()
        phone.heartbeatPauses.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!new.collectsFresh, "not followed after the stop")
        phone.windowPauses.release()
    }

    /// The one more last collect gone, its answer lost, the app in the background: the window's last look runs. Returns
    /// the last collects counted before the one more.
    @discardableResult
    func oneMoreLastCollectInTheBackground() async throws -> Int {
        try await lastCollectAfterAFreeze()
        service.refuseNextCollects(1)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, 40, 7] }, "\(phone.windowPauses.lengths)")
        try await advance(7)
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 0
        service.holdsCollectAnswers = gate
        service.losesCollectAnswers = 1
        service.endLeases()
        let finals = m.moveFlags.book.finalCollects
        phone.windowPauses.release()
        #expect(await eventually { gate.waiting > 0 && m.moveFlags.book.finalCollects == finals + 1 }, "the one more goes")
        await m.onBackground(budget: .seconds(1))
        service.holdsCollectAnswers = nil
        gate.open()
        return finals
    }

    /// While a settlement window follows the transfer's device, its collector's long polls go on connections of their
    /// own; before and after it, on the transport's.
    @Test func theCollectorGoesFreshOnlyDuringTheWindow() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        try await m.refresh()
        #expect(await eventually { m.session != nil })
        let d = try #require(m.session?.device)
        #expect(!d.collectsFresh, "before the window")
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { phone.windowPauses.lengths == [90] }, "the window runs")
        #expect(d.collectsFresh, "during the window")
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil }, "dropped")
        #expect(await eventually { !d.collectsFresh }, "after the window")
    }

    /// The collector the device makes tells a round's failure with whether it had been handed messages: a 4xx after
    /// messages is a cut.
    @Test func theDevicesCollectorPassesHandedThrough() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let cuts = d.collectorCuts.count
        let c = d.collector(of: d.collectRound)
        c.onFailed(RelayError(status: 403, code: "forbidden"), false)
        #expect(d.collectorCuts.count == cuts, "a 4xx handed nothing")
        c.onFailed(RelayError(status: 403, code: "forbidden"), true)
        #expect(d.collectorCuts.count == cuts + 1, "a 4xx after messages")
    }
}
