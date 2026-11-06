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

    /// Once two last collects went, nothing holds a further one: a freeze with a request out raises no hold.
    @Test func aFreezeAfterTwoLastCollectsHoldsNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, _) = try await lastCollectOut(d)
        await clock.waitForFinalCollect(m)
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == nil, "no hold after two last collects")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// After the one more is given, a freeze with a request out raises no hold either.
    @Test func aFreezeAfterTheOneMoreHoldsNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        let (clock, _) = try await lastCollectOut(d)
        clock.cut(m, d, sent: clock.own.out)
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        let hold = clock.finalNotBefore
        phone.uptimeAhead += 2
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        clock.follow(m, d)
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == hold, "no hold more")
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

    /// A cut noticed after its request's answer was due (send + wait + 15 s): the lease may run from the notice, so the end
    /// moves to the notice + V, not to send + wait + 15 s + V.
    @Test func aCutNoticedLateCountsTheLeaseFromTheNotice() async throws {
        defer { phone.close() }
        let (clock, t0) = try await cutNoticedLate(sendAt: 20)
        #expect(clock.until == t0 + 80 + 60, "the notice (80 s) + V, not send + wait + 15 + V = 120 s: \(clock.until - t0)")
        clock.stop()
        phone.heartbeatPauses.release()
    }

    /// The same cut, whose lease from the notice reaches past the cap while the estimate from the send does not: the end
    /// goes to the cap and the last collect is held to the end of that lease.
    @Test func aCutNoticedLateHoldsTheLastCollectPastTheCap() async throws {
        defer { phone.close() }
        let (clock, t0) = try await cutNoticedLate(sendAt: 75)
        #expect(clock.until == t0 + 185, "to the cap")
        #expect(clock.finalNotBefore == t0 + 135 + 60, "the notice (135 s) + V")
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
        #expect(await eventually { phone.windowPauses.lengths == [10, 100] }, "the cut's lease is held: \(phone.windowPauses.lengths)")
        phone.windowPauses.holding = false
        phone.windowPauses.release()
        await waiting.value
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
