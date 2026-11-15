import Foundation
import Testing
import VettIDCalls
import VettIDMessages
import VettIDShellUI
@testable import VettID

/// The calls' history and availability as a conversation gets them (the mapping between the calls package and the messages
/// package, which do not depend on each other). The rules that make the history (the two-minute rule for a ringing record,
/// answered elsewhere and ongoing calls having no row, the skipped count) are tested in the calls package.
@MainActor
@Suite struct CallsConversationTests {
    static let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    @Test func everyOutcomeIsMappedAndNoneIsLost() {
        let pairs: [(CallOutcome, ConversationCallOutcome)] = [
            (.talked, .talked), (.declined, .declined), (.declinedHere, .declinedHere), (.busy, .busy),
            (.notAnswered, .notAnswered), (.missed, .missed), (.failed, .failed),
        ]
        for (from, to) in pairs { #expect(ConversationCallOutcome(from) == to) }
    }

    @Test func theHistoryKeepsDirectionTimeDurationAndTheNote() {
        let h = CallHistory(
            entries: [
                CallHistoryEntry(
                    callId: "k1", connectionId: "c1", outgoing: true, outcome: .talked, startedAt: Self.t0, duration: .milliseconds(252_500)
                ),
                CallHistoryEntry(
                    callId: "k2", connectionId: "c1", outgoing: false, outcome: .missed, startedAt: Self.t0.addingTimeInterval(9)
                ),
            ],
            someNotShown: true
        )
        let m = ConversationCallHistory(h)
        #expect(m.someNotShown && m.calls.map(\.callId) == ["k1", "k2"])
        #expect(m.calls[0].outgoing && m.calls[0].duration == 252.5 && m.calls[0].startedAt == Self.t0)
        #expect(!m.calls[1].outgoing && m.calls[1].duration == nil && m.calls[1].outcome == .missed)
        #expect(ConversationCallHistory(CallHistory()) == ConversationCallHistory())
    }

    /// Only a vault the probe said has calls, with no call going on, offers the action; a vault without calls and one not asked
    /// look the same: no action (owner decision #10677).
    @Test func availabilityIsReadyInCallOrNothing() {
        #expect(ConversationCallAvailability(.ready) == .ready && ConversationCallAvailability(.inCall) == .inCall)
        #expect(ConversationCallAvailability(.unknown) == .unavailable && ConversationCallAvailability(.notInVault) == .unavailable)
    }

    /// With no vault open (the tests' vault is never opened) the shell's calls offer nothing and read nothing.
    @Test func theShellsCallsWithNoVaultOpen() async {
        let calls = ShellCalls(AppComposition.shared.calls)
        #expect(!calls.canCall() && calls.availability() == .unavailable)
        #expect(await calls.history("c1") == ConversationCallHistory())
        calls.call("c1")
    }
}
