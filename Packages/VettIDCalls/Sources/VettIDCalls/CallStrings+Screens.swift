import Foundation

// swiftlint:disable line_length

// The texts of the call screens: Android's English, word for word (vettid-android `feature/calls` `strings.xml`, approved by the
// owner on 2026-10-12, `calls_end_calls_off` on 2026-11-12), in `Localizable.xcstrings`. A changed text is the owner's to approve
// (``CallStringsTests``). Android's `%1$s` is `%@` in the catalog: the other member's name, bidi-isolated by the screen.
extension CallStrings {
    // swiftlint:disable cyclomatic_complexity
    /// The line of an ended call: one per ending, none shared. [name] is the connection's name, or its first name for
    /// ``CallEnd/callsOff``; the texts without a name ignore it.
    public static func ended(_ reason: CallEnd, name: String) -> String {
        switch reason {
        case .hungUp: String(localized: "calls_end_hung_up", defaultValue: "Call ended", bundle: .module)
        case .peerHungUp: String(localized: "calls_end_peer_hung_up", defaultValue: "\(name) ended the call", bundle: .module)
        case .declined: String(localized: "calls_end_declined", defaultValue: "\(name) declined", bundle: .module)
        case .declinedHere: String(localized: "calls_end_declined_here", defaultValue: "Call declined", bundle: .module)
        case .busy: String(localized: "calls_end_busy", defaultValue: "\(name) is on another call", bundle: .module)
        case .noAnswer: String(localized: "calls_end_no_answer", defaultValue: "No answer", bundle: .module)
        case .missed: String(localized: "calls_end_missed", defaultValue: "Missed call from \(name)", bundle: .module)
        case .answeredElsewhere:
            String(localized: "calls_end_answered_elsewhere", defaultValue: "Answered on another device", bundle: .module)
        case .unavailable:
            String(localized: "calls_end_unavailable", defaultValue: "This call is no longer available", bundle: .module)
        case .ownVaultBusy: String(localized: "calls_end_own_vault_busy", defaultValue: "You are already on a call", bundle: .module)
        case .callsOff: String(localized: "calls_end_calls_off", defaultValue: "Calls with \(name) are off.", bundle: .module)
        case .ownerCheckRequired:
            String(
                localized: "calls_end_owner_check_required",
                defaultValue: "Confirm it's you before calling. Your daily check is due.", bundle: .module
            )
        case .notSupported:
            String(localized: "calls_end_not_supported", defaultValue: "Calls are not available for your vault yet", bundle: .module)
        case .noAddress:
            String(
                localized: "calls_end_no_address",
                defaultValue: "VettID cannot reach the network for calls. Check that this phone is online and that VettID is allowed to use the network.",
                bundle: .module
            )
        case .couldNotConnect:
            String(localized: "calls_end_could_not_connect", defaultValue: "Couldn't connect the call. Try calling again.", bundle: .module)
        case .connectionLost: String(localized: "calls_end_connection_lost", defaultValue: "Connection lost", bundle: .module)
        case .notEncrypted:
            String(
                localized: "calls_end_not_encrypted",
                defaultValue: "This call couldn't be encrypted, so it was ended. Try calling again.", bundle: .module
            )
        case .locked:
            String(localized: "calls_end_locked", defaultValue: "Call ended because your vault was locked", bundle: .module)
        case .failed: String(localized: "calls_end_failed", defaultValue: "The call failed. Try again.", bundle: .module)
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// The encryption line of an active call.
    public static func encryption(_ name: String) -> String {
        String(localized: "calls_encryption", defaultValue: "End-to-end encrypted. Only you and \(name) can hear this call.", bundle: .module)
    }

    public static var stateCalling: String { String(localized: "calls_state_calling", defaultValue: "Calling…", bundle: .module) }
    public static var stateRinging: String { String(localized: "calls_state_ringing", defaultValue: "Ringing…", bundle: .module) }
    public static var stateConnecting: String { String(localized: "calls_state_connecting", defaultValue: "Connecting…", bundle: .module) }
    /// The path is interrupted during a call; the media stack is trying to get it back.
    public static var stateReconnecting: String {
        String(localized: "calls_state_reconnecting", defaultValue: "Reconnecting…", bundle: .module)
    }

    public static func incoming(_ name: String) -> String {
        String(localized: "calls_incoming", defaultValue: "\(name) is calling", bundle: .module)
    }

    public static var answer: String { String(localized: "calls_answer", defaultValue: "Answer", bundle: .module) }
    public static var decline: String { String(localized: "calls_decline", defaultValue: "Decline", bundle: .module) }
    public static var mute: String { String(localized: "calls_mute", defaultValue: "Mute", bundle: .module) }
    public static var speaker: String { String(localized: "calls_speaker", defaultValue: "Speaker", bundle: .module) }
    public static var hangUp: String { String(localized: "calls_hang_up", defaultValue: "Hang up", bundle: .module) }
    /// Closes the screen of a call that has ended.
    public static var close: String { String(localized: "calls_close", defaultValue: "Close", bundle: .module) }
    /// Spoken for the two toggles when they are on.
    public static var mutedOn: String { String(localized: "calls_muted_on", defaultValue: "Muted", bundle: .module) }
    public static var speakerOn: String { String(localized: "calls_speaker_on", defaultValue: "Speaker on", bundle: .module) }

    /// The duration of a call on the in-call screen, read aloud ([time]: `4:12`).
    public static func durationSpoken(_ time: String) -> String {
        String(localized: "calls_cd_duration", defaultValue: "Call time \(time)", bundle: .module)
    }
}
// swiftlint:enable line_length
