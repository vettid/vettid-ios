import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// The settlement window's collects (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5): their `wait`, its length, and what may cut
/// them before the decision (a background stopping the collector, a freeze).
extension VaultManagerTransferInTests {
    /// The `wait` of every collect of the mailbox since [from], in order.
    func collectWaits(from: Int) -> [Int] {
        service.relay.requests.dropFirst(from).filter { $0.method == "GET" && $0.path == "/v1/mailbox" }.compactMap { r in
            r.query?.split(separator: "&").first { $0.hasPrefix("wait=") }.flatMap { Int($0.dropFirst(5)) }
        }
    }

    /// The window's length: the relay's visibility timeout clamped to 0–300, 60 when it gives none, + 25 + 5.
    @Test func theWindowsLengthClampsTheRelaysValue() {
        #expect(VaultManager.settleWindow(visibility: nil) == 90)
        #expect(VaultManager.settleWindow(visibility: 60) == 90)
        #expect(VaultManager.settleWindow(visibility: 400) == 330)
        #expect(VaultManager.settleWindow(visibility: -5) == 30)
        #expect(VaultManager.maxEndPastFirst(visibility: 60) == 95, "V + 25 + 5 + 5")
    }

    /// Moves the phone's uptime on by [seconds] (its clocks frozen), in steps a window's heartbeat sees as no freeze: each
    /// waits for two of its ticks (one may have been under way).
    func advance(_ seconds: TimeInterval) async throws {
        var left = seconds
        while left > 0 {
            let step = min(left, 3)
            let beats = m.moveFlags.book.windowBeats
            phone.uptimeAhead += step
            left -= step
            #expect(await eventually { m.moveFlags.book.windowBeats >= beats + 2 }, "the heartbeat ticks")
        }
    }

    /// Waits until the collector's request out now went at the frozen uptime: none sent earlier is still out (the
    /// collector has one at a time), so a lease of what it is handed counts from now. Nothing when no collector runs.
    func freshCollectorRequest() async {
        guard m.session?.device.collecting == true else { return }
        let now = m.config.uptime()
        #expect(await eventually { m.session?.device.collectRequestUptime == now }, "a collector request went out now")
    }

    /// The window running on frozen clocks, its first pause (90 s) held.
    func windowOnFrozenClocks() async throws {
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { phone.windowPauses.lengths == [90] }, "the window runs")
        phone.freezeClocks()
    }

    /// With only the window collecting: long polls of min(25, time left − 5) s, and one `wait=0` collect at its end.
    @Test func theWindowsCollectsWaitFromTheTimeLeftAndEndWithWaitZero() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        m.session?.device.stop()
        let from = service.relay.requests.count
        // The window's own long polls (a collector's request already on its way, `wait=1`, is left out).
        #expect(await eventually { collectWaits(from: from).contains(25) }, "a long poll of 25 s")
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil }, "dropped at its end")
        let waits = collectWaits(from: from).filter { $0 != 1 }
        #expect(waits.last == 0 && waits.allSatisfy { $0 == 25 || $0 == 0 }, "\(waits)")
    }

    /// While the device's collector long-polls (`wait=1` here), the window's own collects are `wait=0`.
    @Test func theWindowCollectsWithWaitZeroWhileTheCollectorRuns() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        #expect(m.session?.device.collecting == true, "the collector runs")
        let from = service.relay.requests.count
        #expect(await eventually { collectWaits(from: from).contains(0) }, "the window's `wait=0` collects")
        #expect(!collectWaits(from: from).contains(25), "\(collectWaits(from: from))")
        phone.windowPauses.release()
    }

    /// A background while the window waits for the collector's round at its end: the collector's long poll, handed the
    /// pairing, is cut (and the pairing leased); the window decides nothing then, moves its end out (within the cap) in
    /// the foreground, and applies the pairing when it reappears.
    @Test func aBackgroundDuringTheCollectorsRoundDecidesNothing() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(90)
        #expect(m.session?.device.collecting == true, "the collector runs")
        await freshCollectorRequest()
        service.leasesCollected = 600
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 1
        service.holdsCollectAnswers = gate
        service.approveTransferIn()
        #expect(await eventually { gate.waiting > 0 }, "the collector's long poll holds the pairing")
        let rounds = m.moveFlags.book.collectorRounds
        phone.windowPauses.release()
        #expect(await eventually { m.moveFlags.book.collectorRounds > rounds }, "the window waits for the collector's round")
        // The window is at its end, waiting for the collector's round: a background stops the collector.
        await m.onBackground(budget: .seconds(1))
        service.holdsCollectAnswers = nil
        gate.open()
        m.onForeground()
        // The collector's long poll (sent at 90 s, `wait=1`) cut: to 91 s + V + 15 s.
        #expect(await eventually { phone.windowPauses.lengths == [90, 76] }, "the end moved out: \(phone.windowPauses.lengths)")
        service.endLeases()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        phone.windowPauses.release()
    }

    /// A freeze during the window (a suspension the app was not told of: the monotonic clock jumps) moves its end out
    /// within the cap: woken long past it, the window makes its last collect and drops, without another pause.
    @Test func aFreezePastTheCapEndsTheWindow() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        phone.uptimeAhead += 1_000
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil }, "dropped")
        #expect(phone.windowPauses.lengths == [90], "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// The iPhone locked during the window (to the manager, a background: the vault lock is no step of a move not yet
    /// paired) neither pauses nor ends it: the pairing that comes is applied, and "Finish the move" is asked after the unlock.
    @Test func aPhoneLockDuringTheWindowThenFinishTheMove() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        // The lock stops the collection, whose long poll may be held at the relay: what that takes is leased, as a relay does.
        service.leasesCollected = 1
        await m.onBackground(budget: .seconds(1))
        service.approveTransferIn()
        m.onForeground()
        // The phase follows on the refresh after the window.
        #expect(await eventually(within: .seconds(30)) {
            m.finishMovePending && m.record.value.transferStartedMs == nil && m.phase == .setup(.finishing)
        }, "Finish the move is asked")
        phone.windowPauses.release()
    }

    /// A freeze shorter than a visibility timeout (30 s), 40 s into the window, is caught by the heartbeat: the end moves
    /// to now + 60 s.
    @Test func aFreezeOfLessThanAVisibilityTimeoutIsCaught() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(40)
        phone.uptimeAhead += 30
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// A freeze moves the end out to max(end, now + V), not to a full window again: woken 70 s in, 60 s are left (not 90).
    @Test func aFreezeMovesTheEndOutRatherThanRestarting() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        phone.uptimeAhead += 70
        #expect(await eventually { phone.windowPauses.lengths.count == 2 }, "\(phone.windowPauses.lengths)")
        #expect(phone.windowPauses.lengths == [90, 60], "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// Backgrounds again and again cannot move the end past the cap (the first end + V + 35 s, 185 s in): each cuts the
    /// collector's long poll (`wait=1`), so at 70 s the end moves to 71 s + V + 15 s (146 s), at 150 s to the cap (35 s
    /// left), and at 170 s no more.
    @Test func repeatedBackgroundsStopAtTheCap() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        for to in [70.0, 150, 170] {
            try await advance(to - phone.uptimeAhead)
            await freshCollectorRequest()
            await m.onBackground(budget: .seconds(1))
            m.onForeground()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(phone.windowPauses.lengths == [90, 76, 35], "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// When the relay cannot be asked for its visibility timeout, the window takes the one the mailbox's registration gave
    /// (kept with the device), not the default.
    @Test func theStoredVisibilityTimeoutIsTheFallback() async throws {
        defer { phone.close() }
        service.relayVisibility = 120
        _ = try await scanned()
        try await phone.restart()
        service.refusesRegistration = true
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually(within: .seconds(30)) { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        #expect(phone.windowPauses.lengths == [150], "120 s + 25 s + 5 s: \(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }
}
