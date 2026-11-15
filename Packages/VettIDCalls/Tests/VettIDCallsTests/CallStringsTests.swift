import Foundation
import Testing
@testable import VettIDCalls

// swiftlint:disable line_length

/// The microphone texts of the calls, word for word (the owner approved them in Ground Control #10653, answer a); a changed text
/// is the owner's to approve. Each row is a text's key, what its accessor gives (the name "Example"), and the expected text.
@Suite struct CallStringsTests {
    struct Row {
        let key: String
        let got: String
        let want: String

        init(_ key: String, _ got: String, _ want: String) {
            self.key = key
            self.got = got
            self.want = want
        }
    }

    static let table: [Row] = [
        Row("calls_microphone_title", CallStrings.microphoneTitle, "Allow the microphone"),
        Row("calls_microphone_body", CallStrings.microphoneBody("Example"), "VettID needs the microphone so Example can hear you. It is used only during calls."),
        Row("calls_name_unknown", CallStrings.nameUnknown, "Your connection"),
        Row("calls_microphone_allow", CallStrings.microphoneAllow, "Allow"),
        Row("calls_microphone_not_now", CallStrings.microphoneNotNow, "Not now"),
        Row("calls_microphone_blocked_title", CallStrings.microphoneBlockedTitle, "The microphone is turned off for VettID"),
        Row("calls_microphone_blocked_body", CallStrings.microphoneBlockedBody, "iOS doesn't ask again. To make and answer calls, allow the microphone for VettID in Settings."),
        Row("calls_microphone_open_settings", CallStrings.microphoneOpenSettings, "Open Settings"),
        Row("calls_microphone_close", CallStrings.microphoneClose, "Close"),
        // The call screens' texts: Android's English (vettid-android `feature/calls` strings.xml), word for word.
        Row("calls_end_hung_up", CallStrings.ended(.hungUp, name: "Example"), "Call ended"),
        Row("calls_end_peer_hung_up", CallStrings.ended(.peerHungUp, name: "Example"), "Example ended the call"),
        Row("calls_end_declined", CallStrings.ended(.declined, name: "Example"), "Example declined"),
        Row("calls_end_declined_here", CallStrings.ended(.declinedHere, name: "Example"), "Call declined"),
        Row("calls_end_busy", CallStrings.ended(.busy, name: "Example"), "Example is on another call"),
        Row("calls_end_no_answer", CallStrings.ended(.noAnswer, name: "Example"), "No answer"),
        Row("calls_end_missed", CallStrings.ended(.missed, name: "Example"), "Missed call from Example"),
        Row("calls_end_answered_elsewhere", CallStrings.ended(.answeredElsewhere, name: "Example"), "Answered on another device"),
        Row("calls_end_unavailable", CallStrings.ended(.unavailable, name: "Example"), "This call is no longer available"),
        Row("calls_end_own_vault_busy", CallStrings.ended(.ownVaultBusy, name: "Example"), "You are already on a call"),
        Row("calls_end_calls_off", CallStrings.ended(.callsOff, name: "Example"), "Calls with Example are off."),
        Row("calls_end_owner_check_required", CallStrings.ended(.ownerCheckRequired, name: "Example"), "Confirm it's you before calling. Your daily check is due."),
        Row("calls_end_not_supported", CallStrings.ended(.notSupported, name: "Example"), "Calls are not available for your vault yet"),
        Row("calls_end_no_address", CallStrings.ended(.noAddress, name: "Example"), "VettID cannot reach the network for calls. Check that this phone is online and that VettID is allowed to use the network."),
        Row("calls_end_could_not_connect", CallStrings.ended(.couldNotConnect, name: "Example"), "Couldn't connect the call. Try calling again."),
        Row("calls_end_connection_lost", CallStrings.ended(.connectionLost, name: "Example"), "Connection lost"),
        Row("calls_end_not_encrypted", CallStrings.ended(.notEncrypted, name: "Example"), "This call couldn't be encrypted, so it was ended. Try calling again."),
        Row("calls_end_locked", CallStrings.ended(.locked, name: "Example"), "Call ended because your vault was locked"),
        Row("calls_end_failed", CallStrings.ended(.failed, name: "Example"), "The call failed. Try again."),
        Row("calls_encryption", CallStrings.encryption("Example"), "End-to-end encrypted. Only you and Example can hear this call."),
        Row("calls_state_calling", CallStrings.stateCalling, "Calling…"),
        Row("calls_state_ringing", CallStrings.stateRinging, "Ringing…"),
        Row("calls_state_connecting", CallStrings.stateConnecting, "Connecting…"),
        Row("calls_state_reconnecting", CallStrings.stateReconnecting, "Reconnecting…"),
        Row("calls_incoming", CallStrings.incoming("Example"), "Example is calling"),
        Row("calls_answer", CallStrings.answer, "Answer"),
        Row("calls_decline", CallStrings.decline, "Decline"),
        Row("calls_mute", CallStrings.mute, "Mute"),
        Row("calls_speaker", CallStrings.speaker, "Speaker"),
        Row("calls_hang_up", CallStrings.hangUp, "Hang up"),
        Row("calls_close", CallStrings.close, "Close"),
        Row("calls_muted_on", CallStrings.mutedOn, "Muted"),
        Row("calls_speaker_on", CallStrings.speakerOn, "Speaker on"),
        Row("calls_cd_duration", CallStrings.durationSpoken("Example"), "Call time Example"),
    ]

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 9 + 34)
        for row in Self.table { #expect(row.got == row.want, "\(row.key)") }
    }

    /// The catalog holds exactly the keys of the table: no text without a row, no row without a text.
    @Test func theTableHoldsEveryKeyOfTheCatalog() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any])
        let keys = Set(try #require((doc["strings"] as? [String: Any])?.keys))
        #expect(keys == Set(Self.table.map(\.key)))
        // The catalog's own values, not only the defaults in the code.
        let strings = try #require(doc["strings"] as? [String: [String: Any]])
        for row in Self.table {
            let en = (((strings[row.key]?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])
            #expect(en?["value"] as? String == Self.catalogValue(row), "\(row.key)")
        }
    }

    /// The catalog's value: the same text, with `%@` where the code has the name.
    static func catalogValue(_ row: Row) -> String {
        row.want.replacingOccurrences(of: "Example", with: "%@")
    }

    static var catalog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDCalls/Resources/Localizable.xcstrings")
    }

    /// The system prompt's text is for the build that links calls: not in the app's Info.plist yet.
    @Test func theUsageDescriptionIsTheApprovedText() {
        #expect(CallStrings.microphoneUsageDescription == "VettID uses the microphone only during calls, so the person you're talking to can hear you.")
    }
}
// swiftlint:enable line_length
