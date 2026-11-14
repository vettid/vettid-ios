import Foundation
import VettIDData
#if canImport(AVFAudio)
import AVFAudio
#endif

// The microphone gate of calls: no call is placed or answered without the permission. Android has the screen ask for it
// (`CallsController.microphoneNeeded`); on iOS the system asks once only, so the app shows its own screen first (the texts of
// ``CallStrings``), then the system's prompt, and once it is denied only Settings can change it.

public enum MicrophoneStatus: Equatable, Sendable {
    /// Never asked: the system's prompt may be shown.
    case undetermined
    case granted
    /// Refused (or restricted): iOS asks no more.
    case denied
}

/// The microphone permission, as a protocol over `AVAudioApplication.recordPermission` and `requestRecordPermission`, so that the
/// gate can be tested.
@MainActor
package protocol MicrophonePermission: AnyObject {
    var status: MicrophoneStatus { get }
    /// The system's prompt (only when ``status`` is ``MicrophoneStatus/undetermined``); true if the member allowed it.
    func request() async -> Bool
}

#if canImport(AVFAudio)
/// ``MicrophonePermission`` on `AVAudioApplication` (iOS 17).
@MainActor
package final class SystemMicrophonePermission: MicrophonePermission {
    package init() {}

    package var status: MicrophoneStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .undetermined
        default: .denied
        }
    }

    package func request() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}
#endif

/// What was held back for the microphone: a call to [connectionId], or the answer to the ringing call.
public enum MicrophoneAction: Equatable, Sendable {
    case call(connectionId: String)
    /// The answer to the call with this sequence number (``CallMachine``): never another call.
    case answer(seq: Int)
}

/// The gate's state, for the screen: ``explain`` (never asked: our screen, then the system's prompt) or ``blocked`` (denied:
/// Settings). Nil when no screen is asked for.
public enum MicrophonePrompt: Equatable, Sendable {
    case explain(MicrophoneAction)
    case blocked(MicrophoneAction)
}

/// A ``MicrophonePrompt`` with its texts: the screen shows them and calls the controller for each button. In ``explain`` the
/// primary button is "Allow" (``CallsController/allowMicrophone()``) and the other "Not now"; in ``blocked`` the primary is "Open
/// Settings" (the screen opens the Settings URL, then ``CallsController/closeMicrophonePrompt()``) and the other "Close".
public struct MicrophoneScreen: Equatable, Sendable {
    public let prompt: MicrophonePrompt
    public let title: String
    public let body: String
    public let primaryButton: String
    public let secondaryButton: String

    /// [firstName]: the other member's first name, isolated against bidi controls (`AccountNames.isolateOrNull`, as Android's call
    /// screen does); "Your connection" (`calls_name_unknown`) when it is not known.
    init(_ prompt: MicrophonePrompt, firstName: String?) {
        self.prompt = prompt
        switch prompt {
        case .explain:
            title = CallStrings.microphoneTitle
            body = CallStrings.microphoneBody(AccountNames.isolateOrNull(firstName) ?? CallStrings.nameUnknown)
            primaryButton = CallStrings.microphoneAllow
            secondaryButton = CallStrings.microphoneNotNow
        case .blocked:
            title = CallStrings.microphoneBlockedTitle
            body = CallStrings.microphoneBlockedBody
            primaryButton = CallStrings.microphoneOpenSettings
            secondaryButton = CallStrings.microphoneClose
        }
    }
}
