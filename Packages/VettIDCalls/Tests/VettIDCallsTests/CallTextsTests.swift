import Foundation
import Testing
@testable import VettIDCalls

// swiftlint:disable line_length

/// Port of vettid-android `CallTextsTest` (texts, the endings that stay open, the clock, the calls-off name), and of the overlay's
/// rule for what is on screen.
@Suite struct CallTextsTests {
    static let ada = "Ada Lovelace"

    /// The owner's approved texts, word for word, one for every ending.
    @Test func everyEndingHasItsApprovedLine() {
        let approved: [CallEnd: String] = [
            .hungUp: "Call ended",
            .peerHungUp: "Ada Lovelace ended the call",
            .declined: "Ada Lovelace declined",
            .declinedHere: "Call declined",
            .busy: "Ada Lovelace is on another call",
            .noAnswer: "No answer",
            .missed: "Missed call from Ada Lovelace",
            .answeredElsewhere: "Answered on another device",
            .unavailable: "This call is no longer available",
            .ownVaultBusy: "You are already on a call",
            .ownerCheckRequired: "Confirm it's you before calling. Your daily check is due.",
            .notSupported: "Calls are not available for your vault yet",
            .noAddress: "VettID cannot reach the network for calls. Check that this phone is online and that VettID is allowed to use the network.",
            .couldNotConnect: "Couldn't connect the call. Try calling again.",
            .connectionLost: "Connection lost",
            .notEncrypted: "This call couldn't be encrypted, so it was ended. Try calling again.",
            .locked: "Call ended because your vault was locked",
            .failed: "The call failed. Try again.",
            .callsOff: "Calls with Ada Lovelace are off.",
        ]
        #expect(Set(CallEnd.allCases) == Set(approved.keys))
        for (reason, text) in approved { #expect(CallStrings.ended(reason, name: Self.ada) == text, "\(reason)") }
        #expect(Set(approved.values).count == approved.count, "no two endings share a line")
    }

    @Test func everyPhaseHasItsLine() {
        #expect(CallTexts.phase(.incoming, reconnecting: false, name: Self.ada) == "Ada Lovelace is calling")
        #expect(CallTexts.phase(.starting, reconnecting: false, name: Self.ada) == "Calling…")
        #expect(CallTexts.phase(.calling, reconnecting: false, name: Self.ada) == "Calling…")
        #expect(CallTexts.phase(.ringing, reconnecting: false, name: Self.ada) == "Ringing…")
        #expect(CallTexts.phase(.connecting, reconnecting: false, name: Self.ada) == "Connecting…")
        // An active call shows its time, until the path is interrupted.
        #expect(CallTexts.phase(.active, reconnecting: false, name: Self.ada) == nil)
        #expect(CallTexts.phase(.active, reconnecting: true, name: Self.ada) == "Reconnecting…")
        // Reconnecting is only said of an active call.
        #expect(CallTexts.phase(.ringing, reconnecting: true, name: Self.ada) == "Ringing…")
    }

    @Test func theOtherApprovedTexts() {
        #expect(CallStrings.encryption(Self.ada) == "End-to-end encrypted. Only you and Ada Lovelace can hear this call.")
        #expect(
            [CallStrings.answer, CallStrings.decline, CallStrings.mute, CallStrings.speaker, CallStrings.hangUp]
                == ["Answer", "Decline", "Mute", "Speaker", "Hang up"]
        )
        #expect(CallStrings.durationSpoken("4:12") == "Call time 4:12")
        #expect(CallStrings.mutedOn == "Muted" && CallStrings.speakerOn == "Speaker on" && CallStrings.close == "Close")
    }

    /// The endings the member has to read stay until closed; every other one closes at once.
    @Test func theStaysOpenSetIsExactlyTheEndingsThatSayWhatToDo() {
        let stays: Set<CallEnd> = [.ownerCheckRequired, .notSupported, .noAddress, .couldNotConnect, .notEncrypted, .failed, .ownVaultBusy, .callsOff]
        for reason in CallEnd.allCases { #expect(CallTexts.staysOpen(reason) == stays.contains(reason), "\(reason)") }
        #expect(CallTexts.staysOpenSet == stays)
        for reason in [CallEnd.hungUp, .peerHungUp, .declined, .declinedHere, .busy, .noAnswer, .missed, .answeredElsewhere, .unavailable, .connectionLost, .locked] {
            #expect(!CallTexts.staysOpen(reason), "\(reason)")
        }
    }

    @Test func onlyTheNotEncryptedEndingIsShownAsAnError() {
        for reason in CallEnd.allCases { #expect(CallTexts.isError(reason) == (reason == .notEncrypted), "\(reason)") }
    }

    @Test func theClock() {
        #expect(CallTexts.clock(0) == "0:00")
        #expect(CallTexts.clock(9) == "0:09")
        #expect(CallTexts.clock(252) == "4:12")
        #expect(CallTexts.clock(3599) == "59:59")
        #expect(CallTexts.clock(3852) == "1:04:12")
        #expect(CallTexts.clock(12 * 3600) == "12:00:00")
        #expect(CallTexts.clock(-3) == "0:00")
    }

    /// "Calls with <First> are off." takes the first name (the full one without it); every other ending the full one.
    @Test func theCallsOffEndingNamesTheFirstName() {
        #expect(CallTexts.endedName(.callsOff, name: Self.ada, firstName: "Ada") == "\u{2068}Ada\u{2069}")
        #expect(CallTexts.endedName(.callsOff, name: Self.ada, firstName: nil) == Self.ada)
        #expect(CallTexts.endedName(.callsOff, name: Self.ada, firstName: "\u{2800}") == Self.ada)
        for reason in CallEnd.allCases where reason != .callsOff {
            #expect(CallTexts.endedName(reason, name: Self.ada, firstName: "Ada") == Self.ada, "\(reason)")
        }
        #expect(CallTexts.ended(.callsOff, name: Self.ada, firstName: "Ada") == "Calls with \u{2068}Ada\u{2069} are off.")
        #expect(CallTexts.ended(.missed, name: Self.ada, firstName: "Ada") == "Missed call from Ada Lovelace")
    }

    /// The name is the connection's, bidi-isolated; "Your connection" when none is known.
    @Test func theShownName() {
        #expect(CallUiState(name: "Ada Lovelace").shownName == "\u{2068}Ada Lovelace\u{2069}")
        #expect(CallUiState(name: nil).shownName == "Your connection")
        #expect(CallUiState(name: "\u{2800}").shownName == "Your connection")
        #expect(CallUiState(name: "Ada\u{202E}Lovelace").shownName == "\u{2068}AdaLovelace\u{2069}")
        #expect(CallUiState(name: "Ada\u{202E}Lovelace").tileName == "AdaLovelace")
    }

    /// What is on screen: a live call, an ending that stays; nothing for an idle state or an ending that closes at once.
    @Test func whatIsOnScreen() {
        func live(_ phase: CallPhase) -> CallUiState {
            CallUiState(call: .live(CallState.Live(connectionId: "c1", direction: .outgoing, phase: phase)))
        }
        func ended(_ reason: CallEnd) -> CallUiState {
            CallUiState(call: .ended(CallState.Ended(connectionId: "c1", direction: .outgoing, reason: reason)))
        }
        #expect(!CallUiState().showsScreen && !CallUiState().callOpen)
        for phase in [CallPhase.starting, .calling, .ringing, .incoming, .connecting, .active] { #expect(live(phase).showsScreen) }
        for reason in CallEnd.allCases {
            #expect(ended(reason).showsScreen == CallTexts.staysOpen(reason), "\(reason)")
            #expect(ended(reason).callOpen, "the shell knows a call screen is over it until the call is dismissed")
        }
    }
}
// swiftlint:enable line_length
