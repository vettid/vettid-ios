import Foundation
import VettIDCalls
@testable import VettIDCallsWebRTC

/// The audio session of the engine tests that run on a fake audio device: it does nothing (no real session, no activation).
@MainActor
final class TestAudioSession: CallAudioSession {
    var state = AudioState()
    var onStateChange: (@MainActor (AudioState) -> Void)?
    func prepare() {}
    func didActivate() {}
    func didDeactivate() {}
    func setSpeaker(_ on: Bool) {}
    func callEnded() {}
}

/// An engine factory for the tests that run on a fake audio device.
@MainActor
func testFactory(testBuild: Bool = false) -> WebRtcMediaEngineFactory {
    WebRtcMediaEngineFactory(testBuild: testBuild, audioSession: TestAudioSession())
}
