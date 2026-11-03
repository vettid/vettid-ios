import LocalAuthentication
import Testing
@testable import VettIDUI

@MainActor
@Suite struct UserPresenceTests {
    /// A passcode is assumed unless the presence says otherwise; the no-passcode presence still confirms.
    @Test func noPasscodeIsToldApartAndStillConfirms() async {
        #expect(UserPresence.confirmed.hasPasscode)
        #expect(!UserPresence.noPasscode.hasPasscode)
        #expect(await UserPresence.noPasscode("reason"))
    }

    /// Only `passcodeNotSet` is "no passcode"; any other reason the owner cannot be asked refuses.
    @Test func onlyPasscodeNotSetIsNoPasscode() {
        #expect(UserPresence.availability(canEvaluate: true, error: nil) == .available)
        #expect(UserPresence.availability(canEvaluate: false, error: LAError(.passcodeNotSet)) == .noPasscode)
        #expect(UserPresence.availability(canEvaluate: false, error: LAError(.biometryLockout)) == .unavailable)
        #expect(UserPresence.availability(canEvaluate: false, error: LAError(.notInteractive)) == .unavailable)
        #expect(UserPresence.availability(canEvaluate: false, error: nil) == .unavailable)
    }
}
