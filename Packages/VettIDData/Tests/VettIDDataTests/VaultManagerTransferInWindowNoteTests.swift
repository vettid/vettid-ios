import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// What the settlement window counts as a note, and what holds its last collect (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5;
/// the shared rule with Android #307): a background while the last collect is out uses up the one more, a freeze holds the
/// last collect only for a request that was out, and a device first seen mid-window counts the cuts from then on.
extension VaultManagerTransferInTests {
    /// A background while the last collect is out is a note: it uses up the one more last collect, where it would have
    /// dropped at once (a last look after the background is only the extra's, so it cannot hold the drop off for good), and
    /// a freeze after it holds nothing more (so held last collects cannot repeat).
    @Test func aBackgroundDuringTheLastCollectGivesTheOneMore() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        d.stop()
        phone.freezeClocks()
        phone.heartbeatPauses.holding = true
        let clock = VaultManager.WindowClock(visibility: 60, backgrounds: m.moveFlags.book.backgrounds, background: false)
        clock.start(m, d)
        #expect(await eventually { clock.over }, "the window is over")
        await clock.waitForFinalCollect(m)
        // The app went to the background and back while the last collect was out.
        m.moveFlags.book.backgrounds += 1
        #expect(!clock.dropsAfterFinalCollect(m, d), "the one more last collect")
        // A freeze in the next one, with a request out: nothing holds it further.
        clock.own.sent(.init(at: m.config.uptime(), wait: 0))
        phone.uptimeAhead += 20
        clock.follow(m, d)
        #expect(clock.finalNotBefore == nil, "no hold after the one more")
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

    /// A device first seen mid-window counts the cuts from then on, not every cut of its life.
    @Test func aDeviceFirstSeenMidWindowCountsNoEarlierCut() async throws {
        defer { phone.close() }
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
        // A cut of its own before the window saw it, whose lease would outlast the end.
        new.collectorRequest(true, of: new.collectRound)
        new.collectorSent(of: new.collectRound, wait: new.collectorWait)
        new.collectorFailed(URLError(.networkConnectionLost), of: new.collectRound)
        m.session = held
        clock.follow(m, old)
        #expect(clock.until == until, "no cut of the window's")
        clock.stop()
        m.session = nil
        phone.heartbeatPauses.release()
        phone.windowPauses.release()
    }
}
