import Foundation
import Testing
@testable import VettIDCalls
@testable import VettIDVault

/// Every outcome of vettid-android `CallsController.entry` (the history rows), the two-minute rule for a record still `ringing`,
/// and the skipped count. `now` is two minutes after the records' start unless a test says otherwise.
@Suite struct CallHistoryTests {
    let now = at(300_000)

    func outcome(_ r: CallRecord) -> CallOutcome? { CallHistoryRows.outcome(r, now: now) }

    func rows(_ list: CallList, _ connection: String = "conn-1") -> CallHistory {
        CallHistoryRows.history(list, connectionId: connection, now: now)
    }

    @Test func aCallThatWasAnsweredAndEndedTalked() {
        #expect(outcome(record(state: "ended", reason: "hangup", answeredAtMs: 1000, endedAtMs: 61_000)) == .talked)
        #expect(outcome(record(direction: "in", state: "ended", reason: "hangup", answeredAtMs: 1000, endedAtMs: 61_000)) == .talked)
        let h = rows(CallList(calls: [record(state: "ended", answeredAtMs: 1000, endedAtMs: 61_000)], skipped: 0))
        #expect(h.entries.first?.duration == .seconds(60))
    }

    @Test func anAnsweredCallNotOverIsGoingOnAndHasNoRow() {
        #expect(outcome(record(state: "active", answeredAtMs: 1000)) == nil)
    }

    @Test func anOutgoingCallEndsAsItsReasonSays() {
        #expect(outcome(record(state: "ended", reason: "decline")) == .declined)
        #expect(outcome(record(state: "ended", reason: "busy")) == .busy)
        #expect(outcome(record(state: "ended", reason: "timeout")) == .notAnswered)
        #expect(outcome(record(state: "ended", reason: "hangup")) == .notAnswered)
        #expect(outcome(record(state: "ended", reason: "failed")) == .failed)
        #expect(outcome(record(state: "ended", reason: "unavailable")) == .failed)
        #expect(outcome(record(state: "ended", reason: "answered_elsewhere")) == .failed)
        #expect(outcome(record(state: "ended", reason: nil)) == .failed)
        #expect(outcome(record(state: "ended", reason: "something_new")) == .failed)
    }

    @Test func anIncomingCallEndsAsItsReasonSays() {
        #expect(outcome(record(direction: "in", state: "ended", reason: "decline")) == .declinedHere)
        #expect(outcome(record(direction: "in", state: "ended", reason: "failed")) == .failed)
        #expect(outcome(record(direction: "in", state: "ended", reason: "timeout")) == .missed)
        #expect(outcome(record(direction: "in", state: "ended", reason: "hangup")) == .missed)
        #expect(outcome(record(direction: "in", state: "ended", reason: "busy")) == .missed)
        #expect(outcome(record(direction: "in", state: "ended", reason: nil)) == .missed)
    }

    @Test func aCallAnsweredOnAnotherDeviceHasNoRow() {
        #expect(outcome(record(direction: "in", state: "ended", reason: "answered_elsewhere")) == nil)
        let h = rows(CallList(calls: [record(direction: "in", state: "ended", reason: "answered_elsewhere")], skipped: 0))
        #expect(h.entries.isEmpty && !h.someNotShown, "no row, and that is not a call that could not be shown")
    }

    @Test func aRecordStillRingingIsRingingForTwoMinutesThenOver() {
        // Started at 180 s: 120 s old at `now`: still ringing; one millisecond more and it is over.
        #expect(outcome(record(direction: "out", state: "ringing", startedAtMs: 180_000)) == nil)
        #expect(outcome(record(direction: "in", state: "ringing", startedAtMs: 180_000)) == nil)
        #expect(outcome(record(direction: "out", state: "ringing", startedAtMs: 179_999)) == .notAnswered)
        #expect(outcome(record(direction: "in", state: "ringing", startedAtMs: 179_999)) == .missed)
        #expect(outcome(record(direction: "out", state: "ringing", startedAtMs: 0)) == .notAnswered)
    }

    @Test func theRowsKeepTheVaultsOrderAndCarryTheirFields() {
        let list = CallList(calls: [
            record("A", direction: "in", state: "ended", reason: "decline", startedAtMs: 20_000),
            record("B", direction: "out", state: "ended", reason: "busy", startedAtMs: 10_000),
        ], skipped: 0)
        let h = rows(list)
        #expect(h.entries.map(\.callId) == ["A", "B"])
        #expect(h.entries.map(\.outcome) == [.declinedHere, .busy])
        #expect(h.entries.map(\.outgoing) == [false, true])
        #expect(h.entries[0].startedAt == at(20_000) && h.entries[0].duration == nil)
        #expect(!h.someNotShown)
    }

    @Test func aSkippedEntryShowsSomeCallsCouldntBeShown() {
        #expect(rows(CallList(calls: [], skipped: 1)).someNotShown)
        #expect(rows(CallList(calls: [record(state: "ended", reason: "hangup")], skipped: 3)).someNotShown)
        #expect(!rows(CallList(calls: [record(state: "ended", reason: "hangup")], skipped: 0)).someNotShown)
        #expect(rows(CallList(calls: [], skipped: 1), "conn-2").someNotShown, "the vault does not say whose: every conversation")
    }

    @Test func noListMeansNoRowsAndNoNote() {
        #expect(CallHistoryRows.history(nil, connectionId: "conn-1", now: now) == CallHistory())
    }
}
