import Foundation
import Testing
@testable import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// The settlement window's last collects and the background (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5; the shared rule with
/// Android #307): a cut noted in the background after the one more last collect moves the end out on the return, and a
/// 4xx of the last collect is neither a cut nor a refusal.
extension VaultManagerTransferInTests {
    /// The last collect (90 s) refused `429` (`Retry-After: 7`), the one more goes at 97 s and holds the pairing, its
    /// answer lost; the app goes to the background and the collector's long poll (`wait=25`, sent at 97 s) is cut there.
    /// Back in the foreground the end moves out to the cap (185 s), the window collects on to it, and its last collect is
    /// held to the lease of the cut (97 s + 25 s + 15 s + V = 197 s), then applies the pairing.
    @Test func aCutInTheBackgroundAfterTheOneMoreMovesTheEndOnTheReturn() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        let d = try #require(m.session?.device)
        d.stop()
        try await advance(90)
        service.refuseNextCollects(10_000)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 7] }, "the refusal: \(phone.windowPauses.lengths)")
        service.refuseNextCollects(0)
        try await advance(7)
        service.leasesCollected = 600
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswersOfWait = 0
        service.holdsCollectAnswers = gate
        service.losesCollectAnswers = 1
        service.approveTransferIn()
        let finals = m.moveFlags.book.finalCollects
        phone.windowPauses.release()
        #expect(await eventually { gate.waiting > 0 && m.moveFlags.book.finalCollects == finals + 1 }, "the one more goes")
        await m.onBackground(budget: .seconds(1))
        // The collector's long poll, sent just before, is cut in the background: nothing moves the end there.
        d.collectorRequest(true, of: d.collectRound)
        d.collectorSent(of: d.collectRound, wait: 25)
        d.collectorFailed(URLError(.networkConnectionLost), of: d.collectRound)
        service.holdsCollectAnswers = nil
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.record.value.transferStartedMs != nil, "nothing decided in the background")
        m.onForeground()
        #expect(await eventually { phone.windowPauses.lengths == [90, 7, 88] }, "to the cap: \(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped")
        try await advance(88)
        phone.windowPauses.release()
        #expect(await eventually { phone.windowPauses.lengths == [90, 7, 88, 12] }, "held: \(phone.windowPauses.lengths)")
        #expect(m.record.value.transferStartedMs != nil, "not dropped before the hold")
        try await advance(12)
        service.endLeases()
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending }, "the pairing applied")
    }

    /// A 4xx that is neither a throttle nor a stale signature (403) on the last collect is no cut and no refusal: there is
    /// no hold, no one more last collect, and the window drops.
    @Test func aForbiddenLastCollectGivesNoMore() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        m.session?.device.stop()
        try await advance(90)
        let finals = m.moveFlags.book.finalCollects
        service.forbidNextCollects(10_000)
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil }, "dropped")
        service.forbidNextCollects(0)
        #expect(m.moveFlags.book.finalCollects == finals + 1, "one last collect")
        #expect(phone.windowPauses.lengths == [90], "no hold: \(phone.windowPauses.lengths)")
    }
}
