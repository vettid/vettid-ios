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

    /// A session that held for a while before it failed does not count as another refusal in a row.
    @Test func aLongSessionResetsTheRefusalsInARow() {
        #expect(MailboxCollector.refusalsForPause(5, lasted: 0.1) == 5)
        #expect(MailboxCollector.refusalsForPause(5, lasted: MailboxCollector.minSession) == 0)
        #expect(MailboxCollector.refusalsForPause(5, lasted: 60) == 0)
        let c = MailboxCollector(source: FakeSource([]))
        let lost = RelayError(status: 503, code: "http_503")
        #expect(c.socketPause(lost, MailboxCollector.refusalsForPause(6, lasted: 3_600)) == 5, "after hours on the socket: 5 s, not 300 s")
        #expect(c.socketPause(lost, 6) == 300)
    }

    /// A network that keeps dropping the socket (each ended by an unanswered ping, after a minute each) backs off to the
    /// fallback period: a ping end never resets the refusals in a row, however long the session held.
    @Test func aPingEndKeepsTheRefusalsInARow() {
        #expect(MailboxCollector.refusalsForPause(6, lasted: 3_600, keepsCount: true) == 6)
        let c = MailboxCollector(source: FakeSource([]))
        let ping = RelayError(status: 503, code: "http_ping")
        var refusals = 0
        var pauses: [TimeInterval] = []
        for _ in 0..<8 {
            refusals = MailboxCollector.refusalsForPause(refusals, lasted: 60, keepsCount: true)
            pauses.append(c.socketPause(ping, refusals))
            refusals += 1
        }
        #expect(pauses == [5, 10, 20, 40, 80, 160, 300, 300])
    }

    /// The same through the collector: three sessions of a minute, each ended by a ping; the second socket is tried after
    /// 5 s of long-poll, the third after 10 s (with the count reset, both would come after 5 s).
    @Test func socketsEndedByPingsBackOffInTheCollector() async throws {
        let clock = PauseClock()
        let ping = RelayError(status: 503, code: "http_ping")
        let sockets = (1...3).map { FakeStream([Self.msg("01S\($0)")], end: ping) }
        let polls = (0..<200).map { SourceStep.messages([Self.msg("01P\($0)")]) }
        let src = FakeSource(polls, stream: sockets[0], later: Array(sockets.dropFirst()))
        let opened = Recorder<Date>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) }).run {
                if $0.msgID.hasPrefix("01S") {
                    opened.add(clock.value)
                    clock.advance(60) // the session holds a minute, then its ping goes unanswered
                } else {
                    clock.advance(1) // a long-poll round
                }
            }
        }
        let gaps = zip(opened.all.dropFirst(), opened.all).map { $0.timeIntervalSince($1) - 60 }
        // Each gap is the pause rounded up to the next whole long-poll round.
        #expect(gaps.count == 2 && gaps[0] > 5 && gaps[0] <= 6 && gaps[1] > 10 && gaps[1] <= 11, "\(gaps)")
    }

    /// A session that held and then closed normally (a relay restart) is collected by long-poll for the first refusal
    /// pause (5 s) before the socket is tried again, not reopened at once.
    @Test func aSessionClosedNormallyAfterItHeldPausesTheSocket() async throws {
        let clock = PauseClock()
        let src = FakeSource([.messages([Self.msg("01B")])], stream: FakeStream([Self.msg("01A")], end: nil))
        let opensWhenHandled = Recorder<Int>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) }).run {
                opensWhenHandled.add(src.lock.withLock { src.streamOpens })
                if $0.msgID == "01A" { clock.advance(10) } // the session holds 10 s, then the relay closes it normally
            }
        }
        // 01B came by long-poll before the socket was opened again: the pause, not an immediate reconnect.
        #expect(opensWhenHandled.all == [1, 1])
        #expect(MailboxCollector(source: src).socketPause(MailboxCollector.closedNormally, 0) == 5)
    }

    /// The relay's close code 4404 wins over this side's ping end: the collection ends with `mailbox_unknown`, and is not
    /// carried on by long-poll as a ping end would be.
    @Test func aMailboxUnknownCloseWinsOverAPingEnd() async throws {
        let gone = RelayError(status: 404, code: RelayError.mailboxUnknown)
        let lost = URLError(.networkConnectionLost)
        let ended = RelayStream.closeError(code: RelayStream.closeMailboxUnknown, endedByPing: true, error: lost)
        #expect(ended as? RelayError == gone)
        let src = FakeSource([.messages([Self.msg("01L")])], stream: FakeStream([], end: ended))
        let got = Recorder<String>()
        await #expect(throws: gone) {
            try await MailboxCollector(source: src, mode: .webSocket, sleep: { _ in }).run { got.add($0.msgID) }
        }
        #expect(got.all.isEmpty, "no long-poll after the mailbox's end")
    }

    /// A slow upgrade refusal (3 s each, a late 429) is no session that held: repeated, the pause still backs off to 300 s.
    @Test func aSlowUpgradeRefusalStillBacksOff() {
        let c = MailboxCollector(source: FakeSource([]))
        let refusal = RelayError(status: 429, code: "http_429")
        var refusals = 0
        var pause: TimeInterval = 0
        for _ in 0..<10 {
            refusals = MailboxCollector.refusalsForPause(refusals, lasted: 3, keepsCount: true)
            pause = c.socketPause(refusal, refusals)
            refusals += 1
        }
        #expect(pause == 300)
        #expect(MailboxCollector.refusalsForPause(4, lasted: 3, keepsCount: true) == 4)
        #expect(MailboxCollector.refusalsForPause(4, lasted: 3, keepsCount: false) == 0, "a real session of 3 s does reset")
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
