import Foundation
import Testing
@testable import VettIDRelay

/// More cases of the mailbox collector against fakes (``MailboxCollectorTests``).
extension MailboxCollectorTests {
    final class PauseClock: @unchecked Sendable {
        let lock = NSLock()
        var t = Date(timeIntervalSince1970: 1_000_000)
        var value: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    /// A socket this side ended for an unanswered ping is collected by long-poll for the refusal pause (5 s), not for the
    /// fallback's five minutes.
    @Test func aSocketEndedForAPingFallsBackForTheRefusalPause() async throws {
        let ended = RelayStream.closeError(code: 1001, endedByPing: true, error: URLError(.networkConnectionLost)) as? RelayError
        #expect(ended?.code == "http_ping")
        let clock = PauseClock()
        let src = FakeSource([.messages([Self.msg("01P")]), .messages([Self.msg("01Q")])], stream: FakeStream([], end: ended))
        let got = Recorder<String>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) }).run {
                got.add($0.msgID)
                if $0.msgID == "01P" { clock.advance(6) } // the long-poll round takes longer than the refusal pause
            }
        }
        // The socket is tried again after the 5 s pause (a second open); under the fallback's 300 s it would not be.
        #expect(got.all == ["01P", "01Q"] && src.streamOpens == 2)
        // The pause is the refusal's: the socket is tried again after 5 s, not 300 s.
        #expect(MailboxCollector(source: src).socketPause(ended ?? RelayError(status: 503, code: "x"), 0) == 5)
    }

    /// A session that held for a while before it ended does not count as another refusal in a row.
    @Test func aLongSessionResetsTheRefusalsInARow() {
        #expect(MailboxCollector.refusalsForPause(5, lasted: 0.1) == 5)
        #expect(MailboxCollector.refusalsForPause(5, lasted: MailboxCollector.minSession) == 0)
        #expect(MailboxCollector.refusalsForPause(5, lasted: 60) == 0)
        let c = MailboxCollector(source: FakeSource([]))
        let ping = RelayError(status: 503, code: "http_ping")
        #expect(c.socketPause(ping, MailboxCollector.refusalsForPause(6, lasted: 3_600)) == 5, "after hours on the socket: 5 s, not 300 s")
        #expect(c.socketPause(ping, 6) == 300)
    }

    /// A slow upgrade refusal (3 s each, a late 429) is no session that held: repeated, the pause still backs off to 300 s.
    @Test func aSlowUpgradeRefusalStillBacksOff() {
        let c = MailboxCollector(source: FakeSource([]))
        let refusal = RelayError(status: 429, code: "http_429")
        var refusals = 0
        var pause: TimeInterval = 0
        for _ in 0..<10 {
            refusals = MailboxCollector.refusalsForPause(refusals, lasted: 3, upgradeRefused: true)
            pause = c.socketPause(refusal, refusals)
            refusals += 1
        }
        #expect(pause == 300)
        #expect(MailboxCollector.refusalsForPause(4, lasted: 3, upgradeRefused: true) == 4)
        #expect(MailboxCollector.refusalsForPause(4, lasted: 3, upgradeRefused: false) == 0, "a real session of 3 s does reset")
    }

    /// The ack over the socket comes after the handler returned (the message is stored first).
    @Test func theSocketAckComesAfterTheHandlerReturned() async throws {
        let stream = FakeStream([Self.msg("01K")], end: RelayError(status: 404, code: RelayError.mailboxUnknown))
        let src = FakeSource([], stream: stream)
        let ackedWhenHandled = Recorder<Int>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, mode: .webSocket, sleep: { _ in }).run { _ in
                ackedWhenHandled.add(stream.acked.count)
                try await Task.sleep(for: .milliseconds(50))
                ackedWhenHandled.add(stream.acked.count)
            }
        }
        #expect(ackedWhenHandled.all == [0, 0], "no ack while the handler runs")
        #expect(stream.acked == ["01K"], "acked once it returned")
    }

    /// Every failed round is told (`onFailed`) before the request is marked ended, the terminal one too; the rounds that
    /// succeed are not.
    @Test func everyFailedRoundIsTold() async throws {
        let src = FakeSource([
            .error(URLError(.networkConnectionLost)), .messages([]), .error(RelayError(status: 503, code: "internal")),
        ])
        let told = Recorder<String>()
        let ended = Recorder<Bool>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(
                source: src, sleep: { _ in }, onRequest: { ended.add($0) },
                onFailed: { e in told.add((e as? RelayError)?.code ?? "transport \(ended.all.last == true)") }
            ).run { _ in }
        }
        #expect(told.all == ["transport true", "internal", RelayError.mailboxUnknown], "\(told.all)")
    }
}
