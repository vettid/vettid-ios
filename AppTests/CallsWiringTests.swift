import Foundation
import Testing
@testable import VettID

/// The calls in the app (CALLS-PLAN C1): in every configuration, over the vault that is open, with the audio and voip
/// background modes and no other.
@MainActor
@Suite struct CallsWiringTests {
    /// Calls (owner decisions #10740 a and #12192 a): `audio`, so that a live call keeps going when VettID leaves the
    /// foreground, and `voip`, without which CallKit refuses the app's provider; nothing else.
    @Test func theAppRunsInTheBackgroundOnlyForCalls() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio", "voip"])
    }

    /// The local network text (owner decision #12588 a): iOS asks before a call's direct path to a phone on the same network.
    @Test func theLocalNetworkTextIsInEveryBuild() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        #expect(text == "VettID connects calls directly to the other phone when you're on the same network.")
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
