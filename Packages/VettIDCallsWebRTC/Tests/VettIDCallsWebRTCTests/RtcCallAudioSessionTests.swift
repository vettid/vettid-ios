#if os(iOS)
import AVFoundation
import Foundation
import Testing
import VettIDCalls
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// The audio glue on the simulator: the stack's manual-audio switches follow CallKit's activation, and the session is never
/// activated by this type. Serialized: the stack's audio session is a singleton.
@Suite(.serialized) @MainActor
struct RtcCallAudioSessionTests {
    let rtc = RTCAudioSession.sharedInstance()

    @Test func prepareSetsTheModeAndLeavesTheAudioUnitOffAndTheSessionInactive() {
        let audio = RtcCallAudioSession()
        audio.prepare()
        #expect(rtc.useManualAudio)
        #expect(!rtc.isAudioEnabled)
        #expect(!rtc.isActive, "never activated by the app")
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playAndRecord)
        #expect(session.mode == .voiceChat)
        #expect(session.categoryOptions.contains(RtcCallAudioSession.categoryOptions))
        #expect(!session.categoryOptions.contains(.defaultToSpeaker), "the speaker only when the member asks")
    }

    @Test func theAudioUnitRunsOnlyBetweenCallKitsActivationAndDeactivation() {
        let audio = RtcCallAudioSession()
        audio.prepare()
        audio.didActivate()
        #expect(rtc.isAudioEnabled)
        audio.didDeactivate()
        #expect(!rtc.isAudioEnabled)
        #expect(audio.state == AudioState())
    }

    @Test func aSpeakerRequestBeforeTheActivationWaitsForIt() {
        let audio = RtcCallAudioSession()
        audio.prepare()
        audio.setSpeaker(true)
        #expect(!rtc.isAudioEnabled)
        audio.didActivate()
        audio.setSpeaker(false)
        audio.didDeactivate()
    }

    @Test func portsMapToRoutes() {
        let expected: [(AVAudioSession.Port, AudioRoute?)] = [
            (.builtInReceiver, .earpiece), (.builtInSpeaker, .speaker), (.headphones, .wired), (.headsetMic, .wired),
            (.usbAudio, .wired), (.bluetoothHFP, .bluetooth), (.bluetoothLE, .bluetooth), (.bluetoothA2DP, .bluetooth),
            (.airPlay, nil), (.builtInMic, nil),
        ]
        for (port, route) in expected { #expect(RtcCallAudioSession.route(of: port) == route, "\(port.rawValue)") }
    }
}
#endif
