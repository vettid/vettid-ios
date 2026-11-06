import Foundation
import Testing
import VettIDRelay
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
        new.collectorSent(of: new.collectRound)
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
}
