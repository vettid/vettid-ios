#if os(iOS)
import AVFoundation
import Foundation
import VettIDCalls
@preconcurrency import WebRTC

/// ``CallAudioSession`` on `AVAudioSession` and the stack's `RTCAudioSession`, the standard WebRTC-with-CallKit arrangement:
/// the stack does not start its audio unit by itself (`useManualAudio`), and `isAudioEnabled` is true only between the
/// activation CallKit gives (`provider(_:didActivate:)`) and the deactivation it takes back. This type never activates the
/// session: `setActive` is not called anywhere.
///
/// Configuration (spec-silent, chosen): category `playAndRecord`, mode `voiceChat` (echo cancellation, the earpiece by default),
/// and the option for Bluetooth hands-free. A Bluetooth headset, then a wired one, then the earpiece is what the system's
/// `voiceChat` routing does by itself; the speaker is used only through ``setSpeaker(_:)``.
@MainActor
public final class RtcCallAudioSession: CallAudioSession {
    public private(set) var state = AudioState()
    public var onStateChange: (@MainActor (AudioState) -> Void)?

    private let rtc = RTCAudioSession.sharedInstance()
    private var activated = false
    private var speakerWanted = false
    /// Whether the speaker override is on the session now (false before the activation, whatever was asked).
    private(set) var speakerApplied = false
    private var routeObserver: (any NSObjectProtocol)?

    /// The stack must not start its audio unit by itself, from the first track of the first engine: so the switches are set here,
    /// before any engine exists. (The audio unit starts only when CallKit has activated the session.)
    public init() {
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
    }

    /// Bluetooth hands-free (HFP). iOS 26 renamed `allowBluetooth` to `allowBluetoothHFP`, with the same value (4); the raw
    /// value serves the iOS 17 floor and the new name alike without a deprecation warning.
    static let categoryOptions = AVAudioSession.CategoryOptions(rawValue: 0x4)

    public func prepare() {
        rtc.useManualAudio = true
        // The audio unit stays stopped until CallKit activates the session.
        if !activated { rtc.isAudioEnabled = false }
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try? rtc.setCategory(.playAndRecord, mode: .voiceChat, options: Self.categoryOptions)
    }

    public func didActivate() {
        activated = true
        rtc.audioSessionDidActivate(AVAudioSession.sharedInstance())
        rtc.isAudioEnabled = true
        applySpeaker()
        observeRoutes()
        refresh()
    }

    public func didDeactivate() {
        activated = false
        speakerWanted = false
        speakerApplied = false
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        if let o = routeObserver { NotificationCenter.default.removeObserver(o) }
        routeObserver = nil
        publish(AudioState())
    }

    public func setSpeaker(_ on: Bool) {
        speakerWanted = on
        guard activated else { return }
        applySpeaker()
        refresh()
    }

    private func applySpeaker() {
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try? rtc.overrideOutputAudioPort(speakerWanted ? .speaker : .none)
        speakerApplied = speakerWanted
    }

    private func observeRoutes() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))) }
        }
    }

    /// A headset that is plugged in or goes away changes the route (as on Android): the member's speaker request ends then.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard activated else { return }
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { speakerWanted = false }
        refresh()
    }

    private func refresh() { publish(Self.snapshot(AVAudioSession.sharedInstance())) }

    private func publish(_ s: AudioState) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

    // MARK: ports to routes

    static func route(of port: AVAudioSession.Port) -> AudioRoute? {
        switch port {
        case .builtInReceiver: .earpiece
        case .builtInSpeaker: .speaker
        case .headphones, .headsetMic, .usbAudio: .wired
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: .bluetooth
        default: nil
        }
    }

    /// The route in use (the first output) and the routes there are: the earpiece and the speaker always, a headset when its
    /// input or output is there.
    static func snapshot(_ session: AVAudioSession) -> AudioState {
        let current = session.currentRoute.outputs.first.flatMap { route(of: $0.portType) }
        var found: Set<AudioRoute> = [.earpiece, .speaker]
        for port in (session.availableInputs ?? []).map(\.portType) + session.currentRoute.outputs.map(\.portType) {
            if let r = route(of: port) { found.insert(r) }
        }
        return AudioState(route: current, available: found.sorted { $0.rawValue < $1.rawValue })
    }
}
#endif
