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
            let collector = MailboxCollector(
                source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) }, random: { $0.lowerBound }
            )
            try await collector.run {
                got.add($0.msgID)
                if $0.msgID == "01P" { clock.advance(6) } // the long-poll round takes longer than the refusal pause
            }
        }
        // The socket is tried again after the 5 s pause (a second open); under the fallback's 300 s it would not be.
        #expect(got.all == ["01P", "01Q"] && src.streamOpens == 2)
        // The pause is the refusal's: the socket is tried again after 5 s, not 300 s.
        #expect(MailboxCollector(source: src, random: { $0.lowerBound }).socketPause(ended ?? RelayError(status: 503, code: "x"), 0) == 5)
    }

    /// A session that held for a while before it failed does not count as another refusal in a row.
    @Test func aLongSessionResetsTheRefusalsInARow() {
        #expect(MailboxCollector.refusalsForPause(5, lasted: 0.1) == 5)
        #expect(MailboxCollector.refusalsForPause(5, lasted: MailboxCollector.minSession) == 0)
        #expect(MailboxCollector.refusalsForPause(5, lasted: 60) == 0)
        let c = MailboxCollector(source: FakeSource([]), random: { $0.lowerBound })
        let lost = RelayError(status: 503, code: "http_503")
        #expect(c.socketPause(lost, MailboxCollector.refusalsForPause(6, lasted: 3_600)) == 5, "after hours on the socket: 5 s, not 300 s")
        #expect(c.socketPause(lost, 6) == 300)
    }

    /// A network that keeps dropping the socket (each ended by an unanswered ping, after a minute each) backs off to the
    /// fallback period: a ping end never resets the refusals in a row, however long the session held.
    @Test func aPingEndKeepsTheRefusalsInARow() {
        #expect(MailboxCollector.refusalsForPause(6, lasted: 3_600, keepsCount: true) == 6)
        let c = MailboxCollector(source: FakeSource([]), random: { $0.lowerBound })
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
        let gaps = await socketGaps(sessions: 3, held: 60, end: RelayError(status: 503, code: "http_ping"))
        #expect(gaps.count == 2 && gaps[0] > 5 && gaps[0] <= 6 && gaps[1] > 10 && gaps[1] <= 11, "\(gaps)")
    }

    /// The times the sockets' messages were handled, with [sessions] sockets that each hold [held] seconds (their message's
    /// handling) and then end with [end] (nil: closed normally); every long-poll round takes 1 s, and each pause's jitter
    /// is its largest with [fullJitter], else none. Gaps between them less [held] are the pauses, rounded up to the next
    /// whole round.
    func socketGaps(sessions: Int, held: TimeInterval, end: Error?, fullJitter: Bool = false) async -> [TimeInterval] {
        let clock = PauseClock()
        let sockets = (1...sessions).map { FakeStream([Self.msg("01S\($0)")], end: end) }
        let polls = (0..<2_000).map { SourceStep.messages([Self.msg("01P\($0)")]) }
        let src = FakeSource(polls, stream: sockets[0], later: Array(sockets.dropFirst()))
        let opened = Recorder<Date>()
        let collector = MailboxCollector(
            source: src, mode: .webSocket, now: { clock.value }, sleep: { clock.advance($0) },
            random: { fullJitter ? $0.upperBound : $0.lowerBound }
        )
        await #expect(throws: RelayError.self) {
            try await collector.run {
                if $0.msgID.hasPrefix("01S") {
                    opened.add(clock.value)
                    clock.advance(held)
                } else {
                    clock.advance(1)
                }
            }
        }
        return zip(opened.all.dropFirst(), opened.all).map { $0.timeIntervalSince($1) - held }
    }

    /// A session that held a minute and then closed normally (a relay restart) is collected by long-poll for the first
    /// refusal pause (5 s) and its jitter before the socket is tried again: not reopened at once, and reopened after it.
    @Test func aSessionClosedNormallyAfterItHeldPausesTheSocket() async throws {
        let gaps = await socketGaps(sessions: 3, held: 60, end: nil, fullJitter: true)
        #expect(gaps.count == 2 && gaps.allSatisfy { $0 > 6.25 && $0 <= 7.25 }, "5 s and 1.25 s of jitter each time: \(gaps)")
        #expect(MailboxCollector(source: FakeSource([]), random: { $0.lowerBound }).socketPause(MailboxCollector.normalClose, 0) == 5)
    }

    /// A relay that closes normally every few seconds backs off: a session shorter than ``MailboxCollector/heldSession``
    /// adds to the pauses in a row.
    @Test func aRelayThatKeepsClosingBacksOff() async throws {
        let gaps = await socketGaps(sessions: 4, held: 3, end: nil)
        #expect(gaps.count == 3 && gaps[0] > 5 && gaps[0] <= 6 && gaps[1] > 10 && gaps[1] <= 11 && gaps[2] > 20 && gaps[2] <= 21, "\(gaps)")
    }

    /// A ping end after a session longer than the fallback period starts the refusals in a row again: an occasional
    /// one in a long run is paused 5 s each time, not more each time.
    @Test func aPingEndAfterAVeryLongSessionResetsTheRefusals() async throws {
        let gaps = await socketGaps(sessions: 3, held: 400, end: RelayError(status: 503, code: "http_ping"))
        #expect(gaps.count == 2 && gaps.allSatisfy { $0 > 5 && $0 <= 6 }, "\(gaps)")
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
        let c = MailboxCollector(source: FakeSource([]), random: { $0.lowerBound })
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

    /// RELAY-PROTOCOL §7.2's backoff with jitter: every socket pause is lengthened at random by up to a quarter of it (at
    /// most 5 s), never shortened, so the relay's retry_after stays the floor.
    @Test func everySocketPauseIsJitteredAboveItsFloor() {
        let low = MailboxCollector(source: FakeSource([]), random: { $0.lowerBound })
        let high = MailboxCollector(source: FakeSource([]), random: { $0.upperBound })
        let told = RelayError(status: 429, code: "http_429", retryAfterSeconds: 7)
        #expect(low.socketPause(told, 0) == 7 && high.socketPause(told, 0) == 8.75)
        let shed = RelayError(status: 503, code: "http_503")
        #expect(low.socketPause(shed, 0) == 5 && high.socketPause(shed, 0) == 6.25)
        #expect(low.socketPause(shed, 20) == 300 && high.socketPause(shed, 20) == 305, "at most 5 s more")
        #expect(high.socketPause(MailboxCollector.normalClose, 1) == 12.5)
    }
}
