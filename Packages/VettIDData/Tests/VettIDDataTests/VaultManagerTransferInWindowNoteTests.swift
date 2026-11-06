import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// What the settlement window counts as a note, and what holds its last collect (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5;
/// the shared rule with Android #307): a cut during the last collect gives the one more, a bare background does not, a
/// freeze holds the last collect only for a request that was out, no hold is raised once the extra is used or two last
/// collects went, and a device first seen mid-window counts the cuts from then on.
extension VaultManagerTransferInTests {
    /// A window over, its last collect out (an own request of `wait=0` sent now), on a device with no collector.
    private func lastCollectOut(_ d: VaultDevice) async throws -> (VaultManager.WindowClock, TimeInterval) {
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        #expect(await eventually { clock.over }, "the window is over")
        await clock.waitForFinalCollect(m)
        let sent = m.config.uptime()
        clock.own.sent(.init(at: sent, wait: 0))
        return (clock, sent)
    }

    /// A background (and back) while the last collect is out is no cut: a request sent in it is not held for, and the
    /// window goes on to its look and the drop.
    @Test func aBareBackgroundDuringTheLastCollectGivesNoExtra() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, _) = try await lastCollectOut(d)
        m.moveFlags.book.backgrounds += 1
        _ = clock.dropsAfterFinalCollect(m, d)
        #expect(clock.finalNotBefore == nil, "no hold: the extra is unused")
        #expect(await eventually { clock.over }, "the window is over again")
        #expect(clock.dropsAfterFinalCollect(m, d), "the drop")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A cut of the last collect gives the one more, held until the cut request's send + V + 15 s.
    @Test func aCutDuringTheLastCollectGivesTheOneMoreHeld() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, sent) = try await lastCollectOut(d)
        clock.cut(m, d, sent: clock.own.out)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        #expect(clock.finalNotBefore == sent + 75, "held for the cut request's lease")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// Two last collects went (a bare background during each), and the look in the background, whose request is out, is
    /// frozen: the freeze's lease is held for, and the unused extra is given for it, where the window would have dropped
    /// with the lease running.
    @Test func aFreezeInTheLookAfterTwoLastCollectsGivesTheHeldExtra() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, _) = try await lastCollectOut(d)
        for round in 0..<2 {
            if round == 1 {
                await clock.waitForFinalCollect(m)
                clock.own.sent(.init(at: m.config.uptime(), wait: 0))
            }
            m.moveFlags.book.backgrounds += 1
            _ = clock.dropsAfterFinalCollect(m, d)
            #expect(await eventually { clock.over }, "the window is over again")
            #expect(clock.dropsAfterFinalCollect(m, d), "the look, not the extra: a bare background")
        }
        // The look's collect is out, and the phone is suspended.
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        clock.follow(m, d)
        phone.uptimeAhead += 30
        clock.follow(m, d)
        #expect(clock.redoneAfterLook(m, d), "the extra is given")
        #expect(clock.finalNotBefore == m.config.uptime() + 75, "held for the lease from the wake")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The budget: after the extra is given, freezes with a request out are held for (their lease from the wake) while the
    /// hold ends at or below the cap, then the first one past it (free), and no further one.
    @Test func aFreezeAfterTheOneMoreIsHeldForOnce() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, sent) = try await lastCollectOut(d)
        clock.cut(m, d, sent: clock.own.out)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        func freeze() -> TimeInterval {
            phone.uptimeAhead += 2
            clock.own.sent(.init(at: m.config.uptime(), wait: 0))
            clock.follow(m, d)
            phone.uptimeAhead += 20
            clock.follow(m, d)
            return m.config.uptime()
        }
        // Each freeze's hold ends 75 s after its wake: free while it ends at or below the cap (185 s after the start),
        // then the first one past it is held for, and no further one.
        var pastTheCap = 0
        for _ in 0..<8 {
            let hold = freeze() + 75
            let before = clock.finalNotBefore
            if hold <= sent + 185 {
                #expect(clock.finalNotBefore == hold, "free under the cap")
            } else if pastTheCap == 0 {
                pastTheCap = 1
                #expect(clock.finalNotBefore == hold, "the first one past the cap is held for")
            } else {
                #expect(clock.finalNotBefore == before, "no hold more past the cap")
            }
        }
        #expect(pastTheCap == 1)
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The budget: the extra is given by a cut whose hold ends under the cap; a cut noticed during that hold, whose lease
    /// runs past the cap, is still held for (the first hold past the cap is free).
    @Test func aLeasePastTheCapDuringACutExtrasHoldIsHeldFor() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        func step(to seconds: TimeInterval) {
            while m.config.uptime() < t0 + seconds {
                phone.uptimeAhead += min(8, t0 + seconds - m.config.uptime())
                clock.follow(m, d)
            }
        }
        step(to: 90)
        #expect(await eventually { clock.over }, "the window is over")
        await clock.waitForFinalCollect(m)
        // The last collect's reply is lost: the extra, held to 90 + 15 + V = 165 s, under the cap (185 s).
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        clock.cut(m, d, sent: clock.own.out)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        #expect(clock.finalNotBefore == t0 + 165, "under the cap")
        // At 150 s, the collector's long poll (sent at 149 s, wait 25 s) is cut: its lease ends at 249 s.
        step(to: 149)
        clock.cut(m, d, sent: .init(at: m.config.uptime(), wait: 25))
        #expect(clock.finalNotBefore == t0 + 249, "held for, past the cap")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A window of V = 60 (first end 90 s, cap 185 s) whose last collect's reply is lost at 90.5 s: the extra, held to
    /// 90.5 + 15 + V = 165.5 s, under the cap. Returns the clock, its start, and a stepper of the uptime.
    private func extraGivenBeforeTheCap(_ d: VaultDevice) async throws -> (VaultManager.WindowClock, TimeInterval) {
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        step(clock, d, t0, to: 90)
        #expect(await eventually { clock.over }, "the window is over")
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        step(clock, d, t0, to: 90.5)
        clock.cut(m, d, sent: clock.own.out)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        #expect(clock.finalNotBefore == t0 + 165.5, "under the cap")
        return (clock, t0)
    }

    private func step(_ clock: VaultManager.WindowClock, _ d: VaultDevice, _ t0: TimeInterval, to seconds: TimeInterval) {
        while m.config.uptime() < t0 + seconds {
            phone.uptimeAhead += min(8, t0 + seconds - m.config.uptime())
            clock.follow(m, d)
        }
    }

    /// The budget: after an extra given before the cap, a freeze whose hold ends under the cap is free; the first hold past
    /// the cap is free too, and a later cut's lease gets it.
    @Test func aHoldUnderTheCapAfterTheExtraDoesNotUseUpTheOnePastIt() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, t0) = try await extraGivenBeforeTheCap(d)
        // A freeze 95 to 106 s with a stream request out: held to 106 + V + 15 = 181 s, under the cap.
        step(clock, d, t0, to: 95)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        phone.uptimeAhead += 11
        clock.follow(m, d)
        #expect(clock.finalNotBefore == t0 + 181, "the freeze is held for, under the cap")
        // A collect sent at 149 s loses its reply at 150 s: its lease runs to 150 + 15 + V = 225 s, past the cap, and is
        // held for (the first hold past the cap).
        step(clock, d, t0, to: 150)
        clock.cut(m, d, sent: .init(at: t0 + 149, wait: 0))
        #expect(clock.finalNotBefore == t0 + 225, "the first hold past the cap")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The budget: after an extra given before the cap, a cut whose lease ends under the cap, later than the extra's hold,
    /// moves the end out to the end of its lease (free: the cap bounds it), so that the last collect after it is not before.
    @Test func aCutUnderTheCapAfterTheExtraMovesTheEndToItsLease() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, t0) = try await extraGivenBeforeTheCap(d)
        step(clock, d, t0, to: 106)
        clock.cut(m, d, sent: .init(at: t0 + 105, wait: 0))
        #expect(clock.until == t0 + 181, "its lease ends at 106 + 15 + V = 181 s, under the cap")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A hold under the cap raised while the extra's hold is waited for is waited for too.
    @Test func aHoldUnderTheCapRaisedDuringTheWaitIsWaitedFor() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, t0) = try await extraGivenBeforeTheCap(d)
        // The window's timer, moved out to 165 s by the cut, runs out.
        phone.windowPauses.holding = true
        #expect(await eventually { phone.windowPauses.lengths == [75] }, "the timer: \(phone.windowPauses.lengths)")
        phone.windowPauses.release()
        #expect(await eventually { clock.over }, "the window is over")
        let waiting = Task { @MainActor in await clock.waitForFinalCollect(m) }
        #expect(await eventually { phone.windowPauses.lengths == [75, 75] }, "the extra's hold: \(phone.windowPauses.lengths)")
        clock.cut(m, d, sent: .init(at: t0 + 90.5, wait: 5))
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [75, 75, 80] }, "the cut's lease is held: \(phone.windowPauses.lengths)")
        phone.windowPauses.holding = false
        phone.windowPauses.release()
        await waiting.value
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A freeze with no request out (the one before it ended before the last tick) holds nothing; the same freeze with the
    /// request still out holds the last collect for its lease.
    @Test func aFreezeWithNoRequestOutHoldsNothing() async throws {
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
                clock.own.sent(.init(at: sent, wait: 0))
            } else {
                d.collectorRequest(true, of: d.collectRound)
                d.collectorSent(of: d.collectRound, wait: d.collectorWait)
            }
            phone.uptimeAhead += 1
            if own {
                clock.own.ended(at: m.config.uptime())
            } else {
                d.collectorRequest(false, of: d.collectRound)
            }
            // The request ended; ticks follow, then a freeze.
            for _ in 0..<2 {
                phone.uptimeAhead += 3
                clock.follow(m, d)
            }
            phone.uptimeAhead += 20
            clock.follow(m, d)
            #expect(clock.finalNotBefore == nil, own ? "the window's own" : "the collector's")
            clock.stop()
        }
        phone.heartbeatPauses.release()
    }

    /// A long poll of `wait=25` sent at [sendAt] (seconds into the window) is cut at [noticeAt], 60 s later (a timeout):
    /// the relay may have parked it late and leased what it handed it up to then. Returns the clock, its start and the
    /// window's cap.
    private func cutNoticedLate(sendAt: TimeInterval) async throws -> (VaultManager.WindowClock, TimeInterval) {
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        func step(to seconds: TimeInterval) {
            while m.config.uptime() < t0 + seconds {
                phone.uptimeAhead += min(8, t0 + seconds - m.config.uptime())
                clock.follow(m, d)
            }
        }
        step(to: sendAt)
        clock.own.sent(.init(at: m.config.uptime(), wait: 25))
        step(to: sendAt + 60)
        clock.cut(m, d, sent: clock.own.out)
        return (clock, t0)
    }

    /// A cut noticed after its request's answer was due (send + wait): the lease may run from the notice, so the end
    /// moves to the notice + 15 s + V, not to send + wait + 15 s + V.
    @Test func aCutNoticedLateCountsTheLeaseFromTheNotice() async throws {
        defer { phone.close() }
        let (clock, t0) = try await cutNoticedLate(sendAt: 20)
        #expect(clock.until == t0 + 80 + 15 + 60, "the notice (80 s) + 15 + V, not send + wait + 15 + V = 120 s: \(clock.until - t0)")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The same cut, whose lease from the notice reaches past the cap while the estimate from the send does not: the end
    /// goes to the cap and the last collect is held to the end of that lease.
    @Test func aCutNoticedLateHoldsTheLastCollectPastTheCap() async throws {
        defer { phone.close() }
        let (clock, t0) = try await cutNoticedLate(sendAt: 75)
        #expect(clock.until == t0 + 185, "to the cap")
        #expect(clock.finalNotBefore == t0 + 135 + 15 + 60, "the notice (135 s) + 15 + V")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A long poll of `wait=25` sent just after the last tick, then a freeze: the relay may be handed it on the wake and park
    /// it for its wait, so the last collect waits for wake + 25 s + V + 15 s.
    @Test func aFreezeLeasesFromTheWakePlusTheSendsWait() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        clock.follow(m, d)
        phone.uptimeAhead += 0.5
        clock.own.sent(.init(at: m.config.uptime(), wait: 25))
        phone.uptimeAhead += 30
        clock.follow(m, d)
        #expect(clock.finalNotBefore == m.config.uptime() + 25 + 60 + 15, "from the wake, not from the send")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The one more is taken before the cap (a refusal of the last collect, `retry_after` 10 s); a cut noticed during its
    /// hold, whose lease runs past the cap, is held for too, once.
    @Test func aCutNoticedDuringTheOneMoresHoldIsHeldFor() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, _) = try await lastCollectOut(d)
        for _ in 0..<13 {
            phone.uptimeAhead += 8
            clock.follow(m, d)
        }
        clock.refused(m, retryAfter: 10)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        phone.windowPauses.holding = true
        let waiting = Task { @MainActor in await clock.waitForFinalCollect(m) }
        #expect(await eventually { phone.windowPauses.lengths == [10] }, "the hold of the refusal: \(phone.windowPauses.lengths)")
        let now = m.config.uptime()
        clock.cut(m, d, sent: .init(at: now, wait: 25))
        phone.windowPauses.release()
        // (81 s: the window's timer, moved out to the cap by the cut.)
        let lengths = { phone.windowPauses.lengths.sorted() }
        #expect(await eventually { lengths() == [10, 81, 100] }, "the cut's lease is held: \(phone.windowPauses.lengths)")
        phone.windowPauses.holding = false
        phone.windowPauses.release()
        await waiting.value
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The window's second last collect (the one more) goes at [secondAt] after the first, a refusal of the first having
    /// given it: the clock, its start, and the end of the window when the second goes (V = 60, first end 90 s, cap 185 s).
    private func secondLastCollectOut(_ d: VaultDevice) async throws -> (VaultManager.WindowClock, TimeInterval) {
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        step(clock, d, t0, to: 90)
        #expect(await eventually { clock.over }, "the window is over")
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        // The last collect at 90 s is refused (429, `retry_after` 1): the one more, at 91 s.
        clock.refused(m, retryAfter: 1)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        step(clock, d, t0, to: 91)
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        return (clock, t0)
    }

    /// The budget: a cut noticed during the one more's own collect, whose lease ends under the cap, moves the end out to
    /// it (V 60: the collector's poll written at 80 s, wait 25 s, lost, noticed at 92 s: 105 + 15 + V = 180 s): the window
    /// does not drop at 92 s but collects on and makes a last collect at the new end.
    @Test func aCutDuringTheOneMoresCollectUnderTheCapMovesTheEnd() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, t0) = try await secondLastCollectOut(d)
        step(clock, d, t0, to: 92)
        clock.cut(m, d, sent: .init(at: t0 + 80, wait: 25))
        #expect(clock.until == t0 + 180, "the end moves out within the cap: \(clock.until - t0)")
        #expect(!clock.dropsAfterFinalCollect(m, d), "no drop at 92 s, with the lease running to 180 s")
        step(clock, d, t0, to: 180)
        #expect(await eventually { clock.over }, "the window is over at 180 s")
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        #expect(clock.dropsAfterFinalCollect(m, d), "the last collect after the lease: the drop")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The budget: the window's end is at the cap already (a freeze early on), the one more is given (a refusal), and a
    /// freeze during its collect leases past the cap: the first hold past the cap is free, so the window waits for it and
    /// makes one `wait=0` look before the drop (the end cannot move any more), once.
    @Test func aFreezeDuringTheOneMoresCollectIsHeldForWithALook() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        step(clock, d, t0, to: 20)
        // A freeze to 190 s: the end goes to the cap (185 s), nothing was out to hold the last collect for.
        phone.uptimeAhead += 170
        clock.follow(m, d)
        #expect(clock.until == t0 + 185, "the cap")
        #expect(clock.finalNotBefore == nil)
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        clock.refused(m, retryAfter: 1)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        await clock.waitForFinalCollect(m)
        let sent = m.config.uptime()
        clock.own.sent(.init(at: sent, wait: 0))
        // A freeze of 20 s with that collect out: its lease runs to the wake + V + 15 s, past the cap.
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == sent + 20 + 75, "the first hold past the cap")
        #expect(clock.dropsAfterFinalCollect(m, d), "the end cannot move: the drop is next")
        phone.windowPauses.holding = true
        let waiting = Task { @MainActor in await clock.holdAfterExtra(m) }
        #expect(await eventually { phone.windowPauses.lengths == [75] }, "the hold of the freeze: \(phone.windowPauses.lengths)")
        phone.windowPauses.release()
        #expect(await waiting.value, "the hold is waited for, then a look")
        #expect(await !clock.holdAfterExtra(m), "once")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The budget: a hold past the cap that was taken before the one more is the first one (free); after the one more, no
    /// other hold past the cap is taken (the one more is the extra).
    @Test func noSecondHoldPastTheCapIsTakenAfterTheOneMore() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        let t0 = m.config.uptime()
        clock.start(m, d)
        step(clock, d, t0, to: 150)
        // A request out at 150 s, a freeze to 190 s (past the cap): the first hold past the cap, 190 + 25 + 75.
        clock.own.sent(.init(at: m.config.uptime(), wait: 25))
        phone.uptimeAhead += 40
        clock.follow(m, d)
        let first = clock.finalNotBefore
        #expect(first == t0 + 190 + 25 + 75, "the first hold past the cap")
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        clock.refused(m, retryAfter: 1)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 25))
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == first, "no other hold past the cap")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A request sent between a late tick and a freeze (after the last tick by more than a tick, but longer ago than the
    /// freeze gap) was out when the freeze began: its lease is held for.
    @Test func aSendBetweenALateTickAndTheFreezeIsHeldFor() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        clock.follow(m, d)
        // The next tick is late: a request goes out 5 s after the last one, and 20 s later the freeze is seen.
        phone.uptimeAhead += 5
        clock.own.sent(.init(at: m.config.uptime(), wait: 25))
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == m.config.uptime() + 25 + 60 + 15, "the freeze holds the last collect for it")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// A device first seen mid-window, as the window left the session: [cutBeforeTheTick] a cut of its own that the window's
    /// last tick (a tick that did not see it) came after, else one in the moment before it is seen. Returns the end
    /// before and after it is seen.
    private func deviceSeenAfterACut(cutBeforeTheTick: Bool) async throws -> (TimeInterval, TimeInterval) {
        _ = try await scanned()
        let old = try #require(m.session?.device)
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.session != nil }, "a session of the new process")
        let held = m.session
        let new = try #require(held?.device)
        new.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        phone.windowPauses.holding = true
        m.session = nil
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, old)
        for _ in 0..<4 {
            phone.uptimeAhead += 8
            clock.follow(m, old)
        }
        let until = clock.until
        // A cut of its own, whose lease would outlast the end.
        new.collectorRequest(true, of: new.collectRound)
        new.collectorSent(of: new.collectRound, wait: new.collectorWait)
        // (A long poll sent well before the last tick, and noticed cut after it.)
        phone.uptimeAhead += 5
        new.collectorFailed(URLError(.networkConnectionLost), of: new.collectRound)
        if cutBeforeTheTick {
            // A tick that did not see the device went by since.
            phone.uptimeAhead += 1
            clock.follow(m, old)
        }
        m.session = held
        clock.follow(m, old)
        let after = clock.until
        clock.stop()
        m.session = nil
        phone.heartbeatPauses.release()
        phone.windowPauses.release()
        return (until, after)
    }

    /// A device first seen mid-window counts the cuts from then on, not every cut of its life.
    @Test func aDeviceFirstSeenMidWindowCountsNoEarlierCut() async throws {
        defer { phone.close() }
        let (until, after) = try await deviceSeenAfterACut(cutBeforeTheTick: true)
        #expect(after == until, "no cut of the window's")
    }

    /// The cut of a device in the moment before it is first seen (noticed at or after the last tick, though its request was
    /// sent long before) is counted.
    @Test func aDeviceFirstSeenJustAfterACutCountsIt() async throws {
        defer { phone.close() }
        let (until, after) = try await deviceSeenAfterACut(cutBeforeTheTick: false)
        #expect(after > until, "the end moved out for the cut")
    }
}
