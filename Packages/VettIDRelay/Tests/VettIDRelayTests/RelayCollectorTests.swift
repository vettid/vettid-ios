import Foundation
import Testing
@testable import VettIDRelay

// swiftlint:disable line_length

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
            try await MailboxCollector(source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) }).run { got.add($0.msgID) }
        }
        #expect(got.all == ["01P", "01Q"] && src.streamOpens == 1)
        // The pause is the refusal's: the socket is tried again after 5 s, not 300 s.
        #expect(MailboxCollector(source: src).socketPause(ended ?? RelayError(status: 503, code: "x"), 0) == 5)
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
}

// swiftlint:enable line_length
