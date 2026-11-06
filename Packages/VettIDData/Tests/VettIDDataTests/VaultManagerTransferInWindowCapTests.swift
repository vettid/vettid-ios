import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// The settlement window's cuts and its cap (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5; the shared rule with Android #307):
/// a collector round that fails is a cut, the end moves out to min(max(end, now + V), the first end + V + 35 s), and a
/// window woken past the cap makes its last collect no sooner than the lease of the request cut then allows.
extension VaultManagerTransferInTests {
    /// The window at its first end (90 s), waiting for the collector's round, whose long poll holds the pairing (leased
    /// until the test ends it; its answer lost when [lost]).
    func windowAtItsEndWithThePairingOut(lost: Bool = false) async throws -> FakeHTTPServer.Gate {
        try await windowOnFrozenClocks()
        try await advance(90)
        #expect(m.session?.device.collecting == true, "the collector runs")
        let gate = try await pairingHeldOut(lease: 600, lost: lost)
        let rounds = m.moveFlags.book.collectorRounds
        phone.windowPauses.release()
        #expect(await eventually { m.moveFlags.book.collectorRounds > rounds }, "the window waits for the collector's round")
        return gate
    }

    /// The collector's long poll (`wait=1`; any collect when [wait] is nil) holds the pairing, leased for [lease] seconds,
    /// its answer lost when [lost].
    func pairingHeldOut(lease: TimeInterval, lost: Bool, wait: Int? = 1) async throws -> FakeHTTPServer.Gate {
        service.leasesCollected = lease
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = wait
        service.holdsCollectAnswers = gate
        if lost { service.losesCollectAnswers = 1 }
        service.approveTransferIn()
        #expect(await eventually { gate.waiting > 0 }, "a long poll holds the pairing")
        return gate
    }

    /// The collector's long poll that carried the pairing loses its answer (the relay leased it): the collect is not
    /// retried into an empty answer, the failed round is a cut, the end moves out, and the pairing is applied when it
    /// reappears.
    @Test func aCollectorAnswerLostWithThePairingIsACut() async throws {
        defer { phone.close() }
        let gate = try await windowAtItsEndWithThePairingOut(lost: true)
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "the end moved out: \(phone.windowPauses.lengths)")
        service.endLeases()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        phone.windowPauses.release()
    }

    /// A collector round answered 503 is a cut; a 4xx the relay answered handed nothing out, and is none.
    @Test func aCollectorRoundAnswered5xxIsACut() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        let before = d.collectorCuts.count
        service.failNextCollects(1)
        #expect(await eventually { d.collectorCuts.count == before + 1 }, "the 503 is counted")
        d.collectorFailed(RelayError(status: 403, code: "forbidden"), of: d.collectRound)
        d.collectorFailed(RelayError(status: 429, code: "rate_limited"), of: d.collectRound)
        #expect(d.collectorCuts.count == before + 1, "a 4xx is no cut")
        d.collectorFailed(URLError(.networkConnectionLost), of: d.collectRound)
        #expect(d.collectorCuts.count == before + 2, "a transport loss is one")
    }

    /// The collector cut by a background 20 s after the first end, the pairing leased for the visibility timeout: the end
    /// moves to now + 60 s (the cap, the first end + 95 s, leaves room for it; one of the first end + 60 s would not).
    @Test func aCutAfterTheFirstEndIsCoveredByTheCap() async throws {
        defer { phone.close() }
        let gate = try await windowAtItsEndWithThePairingOut()
        try await advance(20)
        await m.onBackground(budget: .seconds(1))
        service.holdsCollectAnswers = nil
        gate.open()
        m.onForeground()
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "\(phone.windowPauses.lengths)")
        service.endLeases()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        phone.windowPauses.release()
    }

    /// A request out at s = 130 s, a freeze to 186 s (past the cap, 185 s, before s + V) during which its answer is lost:
    /// the end goes to the cap, and the last collect waits to s + wait + V + 15 s (20 s more); the pairing, leased to s + V, is
    /// collected and applied.
    @Test func aWakePastTheCapWaitsForTheLeaseOfTheRequestOut() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(130)
        // Only requests sent from 130 s on are out (the clocks are frozen: they all went at that uptime).
        let sent = m.config.uptime()
        #expect(await eventually { m.session?.device.collectRequestUptime == sent }, "a collect went out at 130 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true, wait: nil)
        phone.uptimeAhead += 56
        service.holdsCollectAnswers = nil
        gate.open()
        // The collector's long poll (`wait=1`) may be answered, and its lease start, 1 s after it went.
        let left = (sent + 1 + 75 - m.config.uptime()).rounded()
        #expect(left == 20, "s + wait + V + 15 s is 20 s away")
        #expect(await eventually { phone.windowPauses.lengths == [90, 20] }, "\(phone.windowPauses.lengths)")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// A freeze while the last collect is out, the pairing leased to it (its answer lost): that collect is cut too, and one
    /// more last collect goes, no sooner than its own s + V + 15 s (45 s after a wake 30 s on), which applies the move.
    @Test func aFreezeDuringTheLastCollectMakesAnotherOne() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        // Only the window collects (`wait=0` past its end): the pairing goes to its collects alone.
        m.session?.device.stop()
        try await advance(150)
        let first = m.config.uptime()
        #expect(await eventually { m.moveFlags.book.windowCollectSent == first }, "a window collect went out at 150 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true, wait: 0)
        phone.uptimeAhead += 36
        service.holdsCollectAnswers = nil
        gate.open()
        // Woken past the cap (186 s): the last collect waits (39 s).
        #expect(await eventually { phone.windowPauses.lengths == [90, 39] }, "\(phone.windowPauses.lengths)")
        let finals = m.moveFlags.book.finalCollects
        service.endLeases()
        let last = FakeHTTPServer.Gate()
        service.holdsCollectAnswers = last
        service.losesCollectAnswers = 1
        phone.windowPauses.release()
        #expect(await eventually { last.waiting > 0 && m.moveFlags.book.finalCollects == finals + 1 }, "the last collect holds it")
        let sent = m.config.uptime()
        phone.uptimeAhead += 30
        service.holdsCollectAnswers = nil
        last.open()
        #expect(await eventually { phone.windowPauses.lengths.count == 3 }, "\(phone.windowPauses.lengths)")
        #expect(phone.windowPauses.lengths.last == (sent + 75 - m.config.uptime()).rounded(), "\(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// A request handed the pairing at 150 s, a freeze from 150 to 170 s (the wake before the cap, 185 s): the end moves
    /// to the cap, and the last collect there waits to s + V + 15 s (225 s, 40 s more), then applies the move.
    @Test func aFreezeThatWakesBeforeTheCapHoldsTheLastCollect() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        m.session?.device.stop()
        try await advance(150)
        // The window's collects go one at a time: once one went at 150 s, none sent earlier is still out.
        let sent = m.config.uptime()
        #expect(await eventually { m.moveFlags.book.windowCollectSent == sent }, "a window collect went out at 150 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true, wait: 0)
        phone.uptimeAhead += 20
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15] }, "to the cap: \(phone.windowPauses.lengths)")
        try await advance(15)
        let held = (sent + 75 - m.config.uptime()).rounded()
        #expect(held == 40, "s + V + 15 s is 40 s away: \(held)")
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 15, held] }, "\(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// The send time of a request that ended on the wake, before anything saw the freeze, is kept: the last collect waits
    /// for its lease all the same (the collector's request, and the window's own).
    @Test func aRequestThatEndsOnTheWakeStillHoldsTheLastCollect() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        let d = try #require(m.session?.device)
        d.stop()
        phone.heartbeatPauses.holding = true
        for own in [false, true] {
            let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
            clock.start(m, d)
            clock.follow(m, d)
            phone.uptimeAhead += 0.5
            let sent = m.config.uptime()
            if own {
                clock.ownOut = .init(at: sent, wait: 0)
                clock.ownOut = nil
            } else {
                d.collectorRequest(true, of: d.collectRound)
                d.collectorRequest(false, of: d.collectRound)
            }
            phone.uptimeAhead += 20
            clock.follow(m, d)
            #expect(clock.finalNotBefore == sent + (own ? 0 : d.collectorWait) + 75, own ? "the window's own" : "the collector's")
            clock.stop()
        }
        phone.heartbeatPauses.release()
    }

    /// A cut noticed 5 s before the cap (185 s), its s + V past it (240 s), the pairing leased: the end moves to the cap,
    /// and the last collect there waits to s + wait + V + 15 s (71 s more), then applies the move.
    @Test func aCutJustBeforeTheCapWhoseLeaseOutrunsItHoldsTheLastCollect() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(180)
        let sent = m.config.uptime()
        #expect(await eventually { m.session?.device.collectRequestUptime == sent }, "a collect went out at 180 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true)
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 5] }, "to the cap: \(phone.windowPauses.lengths)")
        try await advance(5)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 5, 71] }, "\(phone.windowPauses.lengths)")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// A collector cut past the cap during the hold of the last collect, the pairing leased to it: the last collect counts
    /// as cut, and one more waits for the hold that cut raised (s + wait + V + 15 s), then applies the move.
    @Test func aCutDuringTheHoldOfTheLastCollectMakesAnotherOne() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(130)
        let first = m.config.uptime()
        #expect(await eventually { m.session?.device.collectRequestUptime == first }, "a collect went out at 130 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true)
        phone.uptimeAhead += 56
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 20] }, "the hold: \(phone.windowPauses.lengths)")
        // During the hold, the collector is handed the pairing at 186 s, and its answer is lost.
        let again = FakeHTTPServer.Gate()
        service.holdsCollectAnswers = again
        service.losesCollectAnswers = 1
        service.endLeases()
        #expect(await eventually { again.waiting > 0 }, "the collector holds the pairing")
        service.holdsCollectAnswers = nil
        again.open()
        #expect(await eventually { (m.session?.device.collectorCuts.count ?? 0) >= 2 }, "the cut")
        try await Task.sleep(for: .milliseconds(100))
        phone.windowPauses.release()
        // The last collect finds the pairing leased; the one more waits to 186 s + 1 s + 75 s (the collector's long poll).
        #expect(await eventually { phone.windowPauses.lengths == [90, 20, 76] }, "\(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// The collector's long poll sent after the last tick fails on the wake, and the collector sends again before the
    /// window looks: the cut is the freeze's, and the last collect waits to its s + wait + V + 15 s.
    @Test func aCollectorCutOnTheWakeIsTheFreezes() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        let d = try #require(m.session?.device)
        d.stop()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        clock.follow(m, d)
        phone.uptimeAhead += 0.5
        let sent = m.config.uptime()
        d.collectorRequest(true, of: d.collectRound)
        phone.uptimeAhead += 20
        d.collectorFailed(URLError(.networkConnectionLost), of: d.collectRound)
        d.collectorRequest(false, of: d.collectRound)
        d.collectorRequest(true, of: d.collectRound)
        clock.follow(m, d)
        #expect(clock.finalNotBefore == sent + d.collectorWait + 75)
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The window's own collect answered 503 is a cut, as the collector's is: 40 s in, the end moves to now + 60 s.
    @Test func aWindowCollectAnswered5xxIsACut() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        m.session?.device.stop()
        try await advance(40)
        service.failNextCollects(1)
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// A window long poll (`wait=25`) sent at 59 s is handed the pairing, a freeze to 79 s cuts it: the relay may have
    /// answered it, and leased the pairing, as late as 84 s, so the last collect (the end at 139 s) waits to 84 s + V + 15 s.
    @Test func aLongPollsLeaseCountsFromItsLatestAnswer() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        m.session?.device.stop()
        try await advance(59)
        let sent = m.config.uptime()
        #expect(await eventually { m.moveFlags.book.windowCollectSent == sent }, "a window collect went out at 59 s")
        let gate = try await pairingHeldOut(lease: 600, lost: true, wait: 25)
        phone.uptimeAhead += 20
        service.holdsCollectAnswers = nil
        gate.open()
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "to now + V: \(phone.windowPauses.lengths)")
        // The cut collect's own end (its cut noted) before the clock moves on.
        #expect(await eventually { m.moveFlags.book.windowCollectSent != sent }, "the next window collect went")
        try await advance(60)
        phone.windowPauses.release()
        // To 84 s + V + 15 s (159 s), 20 s past the end.
        #expect(await eventually { phone.windowPauses.lengths == [90, 60, 20] }, "\(phone.windowPauses.lengths)")
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
    }

    /// A stopped collection's request that ends, or fails, after a newer collection's went out leaves the newer one's
    /// send time and its cuts alone (its round is not the collection's any more).
    @Test func aStoppedRoundEndingLateLeavesTheNewerOne() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        let round = d.collectRound
        d.stop()
        #expect(d.collectRound == round + 1, "a stop ends the round")
        // A newer collection, as a start makes it, with no task of its own.
        let new = d.mem.withLock {
            d.collectRound += 1
            return d.collectRound
        }
        d.collectorRequest(true, of: new)
        d.collectorRequest(false, of: new - 1)
        #expect(d.collectRequestUptime != nil, "the newer round's request is still out")
        let cuts = d.collectorCuts.count
        d.collectorFailed(URLError(.networkConnectionLost), of: new - 1)
        #expect(d.collectorCuts.count == cuts, "a stopped round's late failure counts nothing")
        d.collectorFailed(URLError(.networkConnectionLost), of: new)
        #expect(d.collectorCuts.count == cuts + 1)
    }
}
