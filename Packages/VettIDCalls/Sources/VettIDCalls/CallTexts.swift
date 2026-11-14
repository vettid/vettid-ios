import Foundation
import VettIDData

/// What a call screen says and does about a state of the call. Mirrors vettid-android `CallTexts`, `endedName` and the
/// overlay's rule for an ending, without a view, so that `swift test` runs it.
public enum CallTexts {
    /// The endings the member has to read: they say what to do or that something was wrong, so their screen stays until it is
    /// closed. Every other ending closes the screen at once; the conversation's call line says how it ended.
    public static let staysOpenSet: Set<CallEnd> = [
        .ownerCheckRequired, .notSupported, .noAddress, .couldNotConnect, .notEncrypted, .failed, .ownVaultBusy, .callsOff,
    ]

    public static func staysOpen(_ reason: CallEnd) -> Bool { staysOpenSet.contains(reason) }

    /// The state line of a live call before media flows; nil once it does (the screen then shows the time). [name] is the
    /// connection's name, isolated.
    public static func phase(_ phase: CallPhase, reconnecting: Bool, name: String) -> String? {
        switch phase {
        case .starting, .calling: CallStrings.stateCalling
        case .ringing: CallStrings.stateRinging
        case .connecting: CallStrings.stateConnecting
        case .incoming: CallStrings.incoming(name)
        case .active: reconnecting ? CallStrings.stateReconnecting : nil
        }
    }

    /// `4:12`, `1:04:12`; never negative.
    public static func clock(_ seconds: Int64) -> String {
        let s = max(seconds, 0)
        let h = s / 3600
        let m = s % 3600 / 60
        let sec = s % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, sec) : String(format: "%lld:%02lld", m, sec)
    }

    /// The name an ending's text takes: "Calls with <First> are off." takes the first name (as the owner approved it), every other
    /// ending the full name. [name] and [firstName] are as the screen has them; the result is isolated against bidi controls.
    public static func endedName(_ reason: CallEnd, name: String, firstName: String?) -> String {
        reason == .callsOff ? AccountNames.isolateOrNull(firstName) ?? name : name
    }

    /// The text of an ended call.
    public static func ended(_ reason: CallEnd, name: String, firstName: String?) -> String {
        CallStrings.ended(reason, name: endedName(reason, name: name, firstName: firstName))
    }

    /// Whether the screen shows the ending in the error colour: only a call that could not be encrypted.
    public static func isError(_ reason: CallEnd) -> Bool { reason == .notEncrypted }
}

/// What the call screen is given: the call and the connection's names as the app shows them, and the audio route
/// (vettid-android `CallUiState`).
public struct CallUiState: Equatable, Sendable {
    public var call: CallState
    /// The connection's name as the app shows it; nil when it has none.
    public var name: String?
    /// The connection's first name, for the endings that name it so; nil when it has none.
    public var firstName: String?
    public var speaker: Bool
    /// Whether this phone can switch to its speaker right now.
    public var canSpeaker: Bool

    public init(call: CallState = .idle, name: String? = nil, firstName: String? = nil, speaker: Bool = false, canSpeaker: Bool = false) {
        self.call = call
        self.name = name
        self.firstName = firstName
        self.speaker = speaker
        self.canSpeaker = canSpeaker
    }

    /// The name in the screen's sentences: isolated, "Your connection" when none is known.
    public var shownName: String { AccountNames.isolateOrNull(name) ?? CallStrings.nameUnknown }

    /// The name on the tile and the heading's initial: cleaned, without the isolation.
    public var tileName: String { AccountNames.cleaned(name) ?? CallStrings.nameUnknown }

    /// Whether a call screen is shown for [call] at all (vettid-android `CallOverlay`): a call that is live, and an ending that
    /// stays until it is closed. Any other ending closes at once.
    public var showsScreen: Bool {
        switch call {
        case .idle: false
        case .live: true
        case .ended(let e): CallTexts.staysOpen(e.reason)
        }
    }

    /// Something is on the screen of a call, ended or not: the shell under it knows (vettid-android `LocalCallScreenShown`).
    public var callOpen: Bool { call != .idle }
}
