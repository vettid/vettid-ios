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
        try await Task.sleep(for: .milliseconds(300))
        let waits = collectWaits(from: from)
        #expect(waits.contains(0) && !waits.contains(25), "\(waits)")
        phone.windowPauses.release()
    }

    /// A background while the window waits for the collector's round at its end: the collector's long poll, handed the
    /// pairing, is cut (and the pairing leased); the window decides nothing then, runs a full window again in the
    /// foreground, and applies the pairing when it reappears.
    @Test func aBackgroundDuringTheCollectorsRoundDecidesNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        #expect(m.session?.device.collecting == true, "the collector runs")
        service.leasesCollected = 1
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 1
        service.holdsCollectAnswers = gate
        service.approveTransferIn()
        #expect(await eventually { gate.waiting > 0 }, "the collector's long poll holds the pairing")
        phone.windowPauses.release()
        try await Task.sleep(for: .milliseconds(200))
        // The window is at its end, waiting for the collector's round: a background stops the collector.
        await m.onBackground(budget: .seconds(1))
        service.holdsCollectAnswers = nil
        gate.open()
        m.onForeground()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(phone.windowPauses.lengths.count >= 2, "a full window again: \(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// A freeze during the window (a suspension the app was not told of: the monotonic clock jumps): a full window again.
    @Test func aFreezeDuringTheWindowRunsAFullWindowAgain() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { phone.windowPauses.lengths == [90] }, "the window runs")
        phone.uptimeAhead += 1_000
        #expect(await eventually { phone.windowPauses.lengths == [90, 90] }, "\(phone.windowPauses.lengths)")
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
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(m.phase == .setup(.finishing), "Finish the move is asked")
        phone.windowPauses.release()
    }
}
