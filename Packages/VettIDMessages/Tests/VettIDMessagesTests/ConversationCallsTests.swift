import Foundation
import Observation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDMessages

/// The calls of a conversation (vettid-android `CallEntries` and the calls of `ConversationViewModel`): the Call action follows
/// the vault's probe (hidden, not disabled, where the vault has no calls: owner decision #10677), the call lines go in with the
/// messages by time, and the note for calls that did not read is in every conversation (Ground Control #10659 a). The two-minute
/// rule and the outcomes of `call.list` rows are the calls package's (`CallHistoryTests`).
@MainActor
@Observable
final class FakeConversationCalls {
    var availability: ConversationCallAvailability = .unavailable
    /// nil: the read fails.
    @ObservationIgnored var history: ConversationCallHistory? = ConversationCallHistory()
    @ObservationIgnored private(set) var reads: [String] = []
    /// Reads from this many on fail (nil), whatever ``history`` says: a read that answers, then a re-read that fails.
    @ObservationIgnored var failFrom: Int?
    @ObservationIgnored private(set) var called: [String] = []
    /// While true, a read waits for ``release()``.
    @ObservationIgnored var holding = false
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

    func release() {
        holding = false
        let all = waiting
        waiting = []
        for c in all { c.resume() }
    }

    var calls: ConversationCalls {
        ConversationCalls(
            availability: { [self] in availability },
            history: { [self] id in
                reads.append(id)
                let answer = failFrom.map { reads.count > $0 } == true ? nil : history
                if holding { await withCheckedContinuation { waiting.append($0) } }
                return answer
            },
            call: { [self] id in called.append(id) }
        )
    }
}

@MainActor
@Suite struct ConversationCallsTests {
    let messages = FakeMessages()
    let connections = FakeConnections()
    let fake = FakeConversationCalls()
    static let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    init() {
        connections.connections = [Samples.connection("c1"), Samples.connection("c2")]
        messages.connections = connections.connections
    }

    func model(_ id: String = "c1", calls: Bool = true) async -> ConversationViewModel {
        let m = ConversationViewModel(
            connectionID: id, messages: messages, connections: connections, calls: calls ? fake.calls : nil, historyAgain: .zero
        )
        await m.settle()
        return m
    }

    func call(
        _ id: String, _ outcome: ConversationCallOutcome = .missed, at: TimeInterval = 0, outgoing: Bool = false,
        duration: TimeInterval? = nil
    ) -> ConversationCall {
        ConversationCall(callId: id, outgoing: outgoing, outcome: outcome, startedAt: Self.t0.addingTimeInterval(at), duration: duration)
    }

    // MARK: the Call action

    /// Shown only when the vault's probe says it has calls; hidden (not disabled) while the vault was not asked, has none, or a
    /// call is going on. A tap calls through the host.
    @Test func theCallActionFollowsTheProbe() async {
        let m = await model()
        #expect(!m.state.callShown && fake.reads.isEmpty, "not before the vault answered, and its history is not read")
        m.call()
        #expect(fake.called.isEmpty)

        fake.availability = .ready
        await m.settle()
        #expect(m.state.callShown)
        m.call()
        #expect(fake.called == ["c1"])

        fake.availability = .inCall
        await m.settle()
        #expect(!m.state.callShown, "hidden during a call")
        m.call()
        #expect(fake.called == ["c1"])

        fake.availability = .ready
        await m.settle()
        #expect(m.state.callShown)

        fake.availability = .unavailable
        await m.settle()
        #expect(!m.state.callShown)
        m.call()
        #expect(fake.called == ["c1"], "no note for a vault without calls: the action is not there")
    }

    /// A conversation opened without the calls (a build or a screen that has none) has neither the action nor a read.
    @Test func noCallsNoAction() async {
        fake.availability = .ready
        let m = await model(calls: false)
        #expect(!m.state.callShown && fake.reads.isEmpty)
        m.call()
        #expect(fake.called.isEmpty)
    }

    /// Only an active person has the action: not a connection that is not active, and not a service.
    @Test func onlyAnActivePersonCanBeCalled() async {
        fake.availability = .ready
        var service = Samples.connection("svc")
        service.isService = true
        connections.connections = [Samples.connection("c3", state: .blocked), service]
        messages.connections = connections.connections
        let inactive = await model("c3")
        let svc = await model("svc")
        #expect(!inactive.state.callShown && !svc.state.callShown)
        svc.call()
        #expect(fake.called.isEmpty)
    }

    // MARK: the lines

    /// Messages and calls in one list by time, oldest first; a call before the oldest loaded message is left out while older
    /// messages remain, and comes back with the older page.
    @Test func callLinesGoInByTimeAndNotAboveTheOldestMessage() async {
        messages.byConnection = ["c1": [Samples.message("m2", at: Self.t0.timeIntervalSince1970 + 100, read: true)]]
        messages.olderPages = ["c1": [[Samples.message("m1", at: Self.t0.timeIntervalSince1970 + 10, read: true)]]]
        fake.history = ConversationCallHistory(calls: [
            call("late", at: 150), call("between", .declined, at: 50), call("early", at: 5),
        ])
        fake.availability = .ready
        let m = await model()
        #expect(m.state.olderAvailable)
        #expect(m.state.rows.map(\.id) == ["m2", "call-late"], "the calls before the oldest message are left out")
        m.loadOlder()
        await m.settle()
        #expect(m.state.rows.map(\.id) == ["call-early", "m1", "call-between", "m2", "call-late"])
    }

    /// A call at the same moment as a message goes after it; messages are sorted by time too.
    @Test func orderOfRows() {
        let a = Samples.message("a", at: Self.t0.timeIntervalSince1970 + 5)
        let b = Samples.message("b", at: Self.t0.timeIntervalSince1970)
        #expect(CallEntries.rows([a, b], []).map(\.id) == ["b", "a"], "messages by time always, as Android")
        let rows = CallEntries.rows([a, b], [call("x", at: 5), call("y", at: 0)])
        #expect(rows.map(\.id) == ["b", "call-y", "a", "call-x"])
        #expect(CallEntries.rows([], [call("x", at: 5)], notBefore: Self.t0.addingTimeInterval(6)).isEmpty)
        #expect(CallEntries.rows([], [call("x", at: 5)], notBefore: Self.t0.addingTimeInterval(5)).count == 1)
    }

    /// Every outcome has a line, and a call and its direction are kept as they are.
    @Test func everyOutcomeIsARow() async {
        let outcomes: [ConversationCallOutcome] = [.talked, .declined, .declinedHere, .busy, .notAnswered, .missed, .failed]
        fake.history = ConversationCallHistory(calls: outcomes.enumerated().map { i, o in
            call("k\(i)", o, at: TimeInterval(i), outgoing: i % 2 == 0, duration: o == .talked ? 61 : nil)
        })
        fake.availability = .ready
        let m = await model()
        #expect(m.state.calls.map(\.outcome) == outcomes && m.state.rows.count == 7)
        #expect(m.state.calls.first?.duration == 61 && m.state.calls.first?.outgoing == true)
    }

    /// A call's duration as its two largest parts (CallEntries.parts).
    @Test func durationParts() {
        func parts(_ h: Int, _ m: Int, _ s: Int) -> CallDurationParts { CallDurationParts(hours: h, minutes: m, seconds: s) }
        let cases: [(TimeInterval, CallDurationParts)] = [
            (0, parts(0, 0, 0)), (12, parts(0, 0, 12)), (59.9, parts(0, 0, 59)), (60, parts(0, 1, 0)), (252, parts(0, 4, 12)),
            (3_600, parts(1, 0, 0)), (3_840, parts(1, 4, 0)), (3_899, parts(1, 4, 59)), (-5, parts(0, 0, 0)),
        ]
        for (d, expected) in cases { #expect(CallDurationParts(d) == expected, "\(d)") }
    }

    // MARK: the note

    /// "Some calls couldn't be shown." goes with the calls that read, in every conversation (the vault only counts them); the
    /// second read decides again; a lock drops it; a call going on keeps it.
    @Test func theNoteIsInEveryConversation() async {
        fake.history = ConversationCallHistory(calls: [call("k1")], someNotShown: true)
        fake.availability = .ready
        let c1 = await model("c1")
        let c2 = await model("c2")
        #expect(c1.state.callsNotShown && c2.state.callsNotShown)
        #expect(fake.reads.sorted() == ["c1", "c1", "c2", "c2"], "read, and once more a moment later")

        fake.history = ConversationCallHistory(calls: [call("k1")], someNotShown: false)
        fake.availability = .inCall
        await c1.settle()
        #expect(c1.state.callsNotShown && c1.state.calls.count == 1, "during a call the list stays")
        fake.availability = .ready
        await c1.settle()
        #expect(!c1.state.callsNotShown, "read again after the call: none skipped now")

        fake.history = ConversationCallHistory(calls: [call("k1")], someNotShown: true)
        fake.availability = .unavailable // locked
        await c1.settle()
        #expect(!c1.state.callsNotShown && c1.state.calls.isEmpty, "nothing of the history stays in memory")
        fake.availability = .ready
        await c1.settle()
        #expect(c1.state.callsNotShown, "skipped again after the unlock")
    }

    /// A read that fails keeps the lines shown and the note, on the first read after a call and on the re-read a moment later
    /// (no silent emptying).
    @Test func aFailedReadKeepsTheLinesShown() async {
        fake.history = ConversationCallHistory(calls: [call("k1")], someNotShown: true)
        fake.availability = .ready
        let m = await model()
        #expect(m.state.calls.map(\.callId) == ["k1"] && m.state.callsNotShown)

        fake.history = nil
        fake.availability = .inCall
        await m.settle()
        fake.availability = .ready
        await m.settle()
        #expect(fake.reads.count == 4, "both reads after the call were made")
        #expect(m.state.calls.map(\.callId) == ["k1"] && m.state.callsNotShown, "the lines and the note stay")
    }

    /// "Calls may be out of date.": the case behind it is a call that just ended whose re-read, a moment after the read that
    /// answered, failed. The lines stay and the note says so; the next read that answers clears it (owner decision #11240 a).
    @Test func aFailedReReadSaysTheCallsMayBeOutOfDate() async {
        fake.history = ConversationCallHistory(calls: [call("k1")])
        fake.failFrom = 1
        fake.availability = .ready
        let m = await model()
        #expect(fake.reads.count == 2, "the read answered, the re-read failed")
        #expect(m.state.calls.map(\.callId) == ["k1"] && m.state.callsOutOfDate)

        fake.failFrom = nil
        fake.availability = .inCall
        await m.settle()
        #expect(m.state.callsOutOfDate, "during a call the note stays with the lines")
        fake.availability = .ready
        await m.settle()
        #expect(!m.state.callsOutOfDate, "a read that answers clears it")
    }

    /// Nothing read yet: no lines and no note, whatever fails; a lock clears the note and what was read, so a failed read after
    /// the unlock says nothing either.
    @Test func noOutOfDateNoteWhenNothingWasRead() async {
        fake.history = nil
        fake.availability = .ready
        let m = await model()
        #expect(m.state.calls.isEmpty && !m.state.callsOutOfDate, "never read: nothing to say")

        fake.history = ConversationCallHistory(calls: [call("k1")])
        fake.availability = .inCall
        await m.settle()
        fake.availability = .ready
        await m.settle()
        fake.history = nil
        fake.availability = .inCall
        await m.settle()
        fake.availability = .ready
        await m.settle()
        #expect(m.state.callsOutOfDate)

        fake.availability = .unavailable // locked
        await m.settle()
        #expect(!m.state.callsOutOfDate && m.state.calls.isEmpty, "a lock clears the note with the lines")
        fake.availability = .ready
        await m.settle()
        #expect(!m.state.callsOutOfDate, "nothing read since the unlock")
    }

    /// A conversation whose only content is a call is not "Say hello".
    @Test func aCallAloneIsNotAnEmptyConversation() async {
        fake.history = ConversationCallHistory(calls: [call("k1")])
        fake.availability = .ready
        let m = await model()
        #expect(m.state.messages.isEmpty && m.state.rows.count == 1)
    }

    /// The state does not print the calls (names and times are the member's own).
    @Test func theCallsAreNotPrinted() async {
        fake.history = ConversationCallHistory(calls: [call("secret-call-id")], someNotShown: true)
        fake.availability = .ready
        let m = await model()
        #expect(!"\(m.state)".contains("secret-call-id") && !String(reflecting: m.state).contains("secret-call-id"))
    }

    // MARK: leaving and changing mid-read

    /// A model dropped with its re-read waiting is not kept alive by it, and sends no second read.
    @Test func leavingTheScreenEndsTheReReadAndFreesTheModel() async {
        fake.availability = .ready
        weak var weakModel: ConversationViewModel?
        do {
            let m = ConversationViewModel(
                connectionID: "c1", messages: messages, connections: connections, calls: fake.calls, historyAgain: .seconds(30)
            )
            weakModel = m
            for _ in 0..<50 { await Task.yield() }
            #expect(fake.reads == ["c1"])
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(weakModel == nil, "the re-read does not hold the model")
        #expect(fake.reads == ["c1"], "and sends no second call.list")
    }

    /// A read in flight when the vault locks, or a call starts, does not put its answer in the list.
    @Test func aReadInFlightWhenTheAvailabilityChangesIsDropped() async {
        fake.history = ConversationCallHistory(calls: [call("k1")], someNotShown: true)
        fake.holding = true
        fake.availability = .ready
        let m = await modelNotSettled()
        fake.availability = .unavailable // a lock, mid-read
        for _ in 0..<20 { await Task.yield() }
        fake.release()
        await m.settle()
        #expect(m.state.calls.isEmpty && !m.state.callsNotShown)

        // A call starting mid-read: the list stays as it was (empty here), not filled by the read dropped.
        fake.holding = true
        fake.availability = .ready
        for _ in 0..<20 { await Task.yield() }
        fake.availability = .inCall
        for _ in 0..<20 { await Task.yield() }
        fake.release()
        await m.settle()
        #expect(m.state.calls.isEmpty && !m.state.callsNotShown)
    }

    func modelNotSettled() async -> ConversationViewModel {
        let m = ConversationViewModel(
            connectionID: "c1", messages: messages, connections: connections, calls: fake.calls, historyAgain: .zero
        )
        for _ in 0..<20 { await Task.yield() }
        return m
    }
}
