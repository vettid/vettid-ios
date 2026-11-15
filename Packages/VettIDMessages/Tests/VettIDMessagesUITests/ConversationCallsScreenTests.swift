#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMessages
@testable import VettIDMessagesUI
import VettIDUI

/// The calls in a conversation's screen (vettid-android `CallEntry`, `CallsNotShownLine`, the Call button): the lines with each
/// outcome and duration format, the texts (vettid-android's, word for word), the note, and the action's visibility.
@MainActor
@Suite struct ConversationCallsScreenTests {
    static let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    func call(_ id: String, _ outcome: ConversationCallOutcome, outgoing: Bool = false, duration: TimeInterval? = nil) -> ConversationCall {
        ConversationCall(callId: id, outgoing: outgoing, outcome: outcome, startedAt: Self.t0, duration: duration)
    }

    func state(calls: [ConversationCall] = [], notShown: Bool = false, availability: ConversationCallAvailability = .ready)
        -> ConversationState {
        var s = ConversationState(connectionID: "c1")
        s.loading = false
        s.connection = MessagesScreensTests.connection("c1")
        s.messages = [MessagesScreensTests.message("m1", at: Self.t0.addingTimeInterval(-60), read: true)]
        s.calls = calls
        s.callsNotShown = notShown
        s.callAvailability = availability
        return s
    }

    // MARK: the texts

    /// Every outcome says what vettid-android says, word for word.
    @Test func everyOutcomeSaysAndroidsWords() {
        let said: [(ConversationCallOutcome, String)] = [
            (.declined, "Call declined"), (.declinedHere, "Call you declined"), (.busy, "Call not answered: busy"),
            (.notAnswered, "Call not answered"), (.missed, "Missed call"), (.failed, "Call failed"),
        ]
        for (outcome, text) in said { #expect(MessagesStrings.callLine(call("k", outcome)) == text) }
        #expect(MessagesStrings.call == "Call")
        #expect(MessagesStrings.callsNotShown == "Some calls couldn't be shown.")
    }

    /// A talked call says its duration as its two largest parts.
    @Test func aTalkedCallSaysHowLong() {
        func line(_ d: TimeInterval?) -> String { MessagesStrings.callLine(call("k", .talked, duration: d)) }
        #expect(line(12) == "Call, 12 s" && line(0) == "Call, 0 s")
        #expect(line(252) == "Call, 4 min 12 s" && line(60) == "Call, 1 min 0 s")
        #expect(line(3_840) == "Call, 1 h 4 min" && line(3_600) == "Call, 1 h 0 min")
        #expect(line(36_000) == "Call, 10 h 0 min")
    }

    /// The line is the outcome, then the time (as the messages' time).
    @Test func theLineHasTheTime() {
        #expect(CallEntry.text(call("k", .missed)) == "Missed call · \(MessageTimes.time(Self.t0))")
    }

    // MARK: the screen

    /// The Call action is the top bar's only when the state says so and the screen has the action: hidden, never disabled.
    @Test func theCallActionIsHiddenUnlessTheProbeSaysReady() {
        var actions = ConversationActions()
        actions.onCall = {}
        #expect(ConversationScreen.callAction(state(), actions) != nil)
        #expect(ConversationScreen.callAction(state(availability: .inCall), actions) == nil, "hidden during a call")
        #expect(ConversationScreen.callAction(state(availability: .unavailable), actions) == nil, "hidden: no calls, or not asked")
        #expect(ConversationScreen.callAction(state(), ConversationActions()) == nil, "a screen without the action")
        var inactive = state()
        inactive.connection?.state = .blocked
        #expect(ConversationScreen.callAction(inactive, actions) == nil)
    }

    /// The calls' rows are in the list with the messages, by day; a conversation with only a call is not empty.
    @Test func theRowsAreInTheListByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let s = state(calls: [call("k1", .missed), call("k2", .talked, duration: 5)])
        #expect(MessageList.days(s.rows, calendar: calendar).map { $0.rows.map(\.id) } == [["m1", "call-k1", "call-k2"]])
        var only = state(calls: [call("k1", .missed)])
        only.messages = []
        #expect(ConversationBody.phase(only) != .empty)
        only.calls = []
        #expect(ConversationBody.phase(only) == .empty)
    }

    /// Every state of the conversation with calls is drawn (the screens' texts and presence on the simulator are the catalog's
    /// UI test: the accessibility tree of a hosted view is not built outside it).
    @Test func everyStateIsDrawn() {
        let calls = [call("k1", .missed), call("k2", .talked, outgoing: true, duration: 252), call("k3", .failed, outgoing: true)]
        var actions = ConversationActions()
        actions.onCall = {}
        for s in [state(calls: calls, notShown: true), state(calls: calls, availability: .inCall), state(availability: .unavailable)] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UIHostingController(rootView: ConversationScreen(state: s, actions: actions).vettIDTheme())
            window.isHidden = false
            window.layoutIfNeeded()
            window.isHidden = true
        }
        for c in calls { #expect(height(CallEntry(call: c)) > 0) }
        #expect(height(CallsNotShownLine()) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
