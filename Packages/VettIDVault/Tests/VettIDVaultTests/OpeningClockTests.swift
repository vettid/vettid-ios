import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

/// The clock an opening's moment is read on (ANDROID-PLAN 0.1.134 Notification modes 7, IOS-PLAN §6.7): set by the first
/// answer from the vault after ``VaultDevice/beginOpening()``, never by an event's `ts` (at a cold start the mailbox's
/// backlog can be days old) or by a vault time learnt before the opening.
extension LostAnswerTests {
    func event(_ ts: Date) -> Inner {
        Inner(id: Ulid.new(), type: "feed.event", ts: ts, body: Array("{}".utf8))
    }

    func answer(_ ts: Date) -> Inner {
        Inner(id: Ulid.new(), type: "vault.status", ts: ts, re: Ulid.new(), status: Inner.statusOK, body: Array("{}".utf8))
    }

    @Test func theFirstAnswerOfTheOpeningSetsItsClockNeverAnEvent() async throws {
        let up = Uptime()
        let h = try await holder(uptime: up)
        let (d, v) = (h.d, h.v)
        // Answers came while the device was set up, before any opening: none counts.
        #expect(d.vaultTime(atUptime: up.now) == nil)
        d.beginOpening()
        let opened = d.uptimeNow()
        try await deliver(v, d, event(Date().addingTimeInterval(-3 * 86_400)))
        #expect(d.vaultTime(atUptime: opened) == nil, "an event's ts never sets it")
        up.advance(5)
        let first = Date().addingTimeInterval(120)
        try await deliver(v, d, answer(first))
        // The opening was 5 s before the answer arrived, on the vault's clock.
        let mark = try #require(d.vaultTime(atUptime: opened))
        #expect(abs(mark.timeIntervalSince(first) + 5) < 0.001)
        up.advance(5)
        try await deliver(v, d, answer(first.addingTimeInterval(60)))
        #expect(d.vaultTime(atUptime: opened) == mark, "only the first answer of the opening")
        // A new opening waits for its own first answer.
        d.beginOpening()
        #expect(d.vaultTime(atUptime: d.uptimeNow()) == nil)
    }
}
