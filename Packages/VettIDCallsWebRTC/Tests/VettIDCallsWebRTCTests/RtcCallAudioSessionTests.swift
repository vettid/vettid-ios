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
        #expect(!audio.speakerApplied, "nothing is applied to the session before CallKit activates it")
        audio.didActivate()
        #expect(audio.speakerApplied, "the request is applied at the activation")
        audio.setSpeaker(false)
        #expect(!audio.speakerApplied)
        audio.setSpeaker(true)
        #expect(audio.speakerApplied)
        audio.didDeactivate()
        #expect(!audio.speakerApplied)
        audio.callEnded()
    }

    /// An interruption (a cellular call) deactivates the session; the speaker the member asked for is back when it activates again,
    /// and the end of the call ends the request.
    @Test func theSpeakerRequestSurvivesADeactivationAndEndsWithTheCall() {
        let audio = RtcCallAudioSession()
        audio.prepare()
        audio.didActivate()
        audio.setSpeaker(true)
        audio.didDeactivate()
        #expect(!audio.speakerApplied)
        audio.didActivate()
        #expect(audio.speakerApplied, "applied again at the next activation")
        audio.didDeactivate()
        audio.callEnded()
        audio.didActivate()
        #expect(!audio.speakerApplied, "the next call starts without it")
        audio.didDeactivate()
    }

    /// CallKit may activate the session before the engine opens (answer, fulfil, then the machine's turn): the engine must not
    /// switch the audio off again.
    @Test func anEngineOpenedAfterTheActivationLeavesTheAudioOn() throws {
        _ = TestStack.ready
        let audio = RtcCallAudioSession()
        audio.prepare()
        audio.didActivate()
        #expect(rtc.isAudioEnabled)
        let engine = try WebRtcMediaEngineFactory(audioSession: audio).create(config: MediaConfig())
        #expect(rtc.useManualAudio && rtc.isAudioEnabled, "left as the session had it")
        engine.close()
        audio.didDeactivate()
    }

    @Test func aSecondDeactivationDoesNothing() {
        let audio = RtcCallAudioSession()
        audio.prepare()
        audio.didActivate()
        audio.didDeactivate()
        rtc.isAudioEnabled = true
        audio.didDeactivate()
        #expect(rtc.isAudioEnabled, "the second call touched nothing")
        rtc.isAudioEnabled = false
    }

    /// Whatever made the engine, and whatever the session object did or did not do, the stack's audio unit is kept from starting.
    @Test func anEngineKeepsTheStackFromStartingItsAudioUnitWhateverThePathToIt() throws {
        _ = TestStack.ready
        rtc.useManualAudio = false
        rtc.isAudioEnabled = true
        let engine = try WebRtcMediaEngineFactory(audioSession: TestAudioSession()).create(config: MediaConfig())
        #expect(rtc.useManualAudio && !rtc.isAudioEnabled)
        engine.close()
    }

    @Test func theStackIsKeptFromStartingItsAudioUnitAsSoonAsTheSessionObjectExists() {
        rtc.useManualAudio = false
        rtc.isAudioEnabled = true
        _ = RtcCallAudioSession()
        #expect(rtc.useManualAudio && !rtc.isAudioEnabled, "set at init, before any engine, not at prepare")
    }

    @Test func theFactoryPreparesTheSessionBeforeItMakesAnEngine() throws {
        @MainActor final class Recorder: CallAudioSession {
            var state = AudioState()
            var onStateChange: (@MainActor (AudioState) -> Void)?
            var log: [String] = []
            func prepare() { log.append("prepare") }
            func didActivate() { log.append("activate") }
            func didDeactivate() { log.append("deactivate") }
            func setSpeaker(_ on: Bool) { log.append("speaker") }
            func callEnded() { log.append("callEnded") }
        }
        _ = TestStack.ready
        let recorder = Recorder()
        let factory = WebRtcMediaEngineFactory(audioSession: recorder)
        let engine = try factory.create(config: MediaConfig())
        #expect(recorder.log == ["prepare"], "prepared, never activated")
        engine.close()
        // A configuration the build refuses makes no engine, and prepares nothing.
        var odd = MediaConfig()
        odd.dtlsPqcTrial = true
        #expect(throws: (any Error).self) { try factory.create(config: odd) }
        #expect(recorder.log == ["prepare"])
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
