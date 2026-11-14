import Foundation

// A call's audio on the phone (vettid-android `CallAudio.kt`: `AudioRoute`, `AudioState`, `CallAudio`, `CallTones`, `ToneSlot`).
// On iOS CallKit owns the audio session: it is configured before a call and activated only when CallKit says so
// (`provider(_:didActivate:)`), and released when CallKit says so (`didDeactivate`).

/// Where a call's sound goes.
public enum AudioRoute: Int, Sendable, CaseIterable { case earpiece, speaker, wired, bluetooth }

public struct AudioState: Equatable, Sendable {
    /// The route in use; nil when no call has the audio.
    public var route: AudioRoute?
    /// The routes this phone has right now.
    public var available: [AudioRoute]

    public init(route: AudioRoute? = nil, available: [AudioRoute] = []) {
        self.route = route
        self.available = available
    }
}

/// The audio session and the media stack's audio unit, for one call at a time. The implementation (the WebRTC glue) must not
/// activate the session itself: only ``didActivate()`` (CallKit gave it) starts audio.
@MainActor
public protocol CallAudioSession: AnyObject {
    /// The route in use and the routes there are. Empty until ``didActivate()``.
    var state: AudioState { get }
    /// Called when ``state`` changes.
    var onStateChange: (@MainActor (AudioState) -> Void)? { get set }
    /// Before a call: category, mode and options are set. Nothing is activated and no audio unit is started.
    func prepare()
    /// CallKit activated the session: the audio unit may start.
    func didActivate()
    /// CallKit deactivated the session: the audio unit stops.
    func didDeactivate()
    /// The speaker, only when the member asks for it; false returns to the headset or the earpiece.
    func setSpeaker(_ on: Bool)
}

/// The sounds the app plays around a call: the ring-back only. CallKit plays the ringtone of an incoming call, and when it
/// refuses one (Do Not Disturb, a block list) nothing rings.
@MainActor
public protocol CallTones: AnyObject {
    /// The caller's ring-back tone while the other phone rings.
    func ringBack(_ on: Bool)
}

/// One sound that is either playing or not. The call's state is reported at every change, so most reports say "on" while it
/// already is (or "off" while it is not): those do nothing. Restarting a tone that plays would cut and restart it.
/// `begin` returns what plays (nil: it could not start, and the next "on" tries again); `end` stops it.
@MainActor
public final class ToneSlot<Player: AnyObject> {
    private var playing: Player?
    private let begin: () -> Player?
    private let end: (Player) -> Void

    public init(begin: @escaping () -> Player?, end: @escaping (Player) -> Void) {
        self.begin = begin
        self.end = end
    }

    public var isPlaying: Bool { playing != nil }

    public func set(_ on: Bool) {
        if on == (playing != nil) { return }
        if on {
            playing = begin()
        } else if let p = playing {
            playing = nil
            end(p)
        }
    }
}
