import Foundation
import Testing
@testable import VettID

/// The calls in the app (CALLS-PLAN C1): in every configuration, over the vault that is open, with the audio background mode
/// and no other.
@MainActor
@Suite struct CallsWiringTests {
    /// A live call keeps going when VettID leaves the foreground (owner decision #10740 a): `audio`, never `voip` or anything else.
    @Test func theAppRunsInTheBackgroundOnlyForAudio() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio"])
    }

    @Test func theMicrophoneTextIsInEveryBuild() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        #expect(text == "VettID uses the microphone only during calls, so the person you're talking to can hear you.")
    }

    /// Nothing of a call runs until the vault is open: the composition's calls have no call logic, no screen and no Call button
    /// while the vault is not open (the tests' vault is never opened).
    @Test func noCallLogicWhileTheVaultIsNotOpen() {
        let calls = AppComposition.shared.calls
        #expect(!calls.canCall && !calls.screenShown)
    }
}
