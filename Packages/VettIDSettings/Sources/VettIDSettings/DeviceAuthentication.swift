import Foundation
import LocalAuthentication

/// What this iPhone can ask for (LocalAuthentication): Face ID or Touch ID set up, a passcode set. Read before the app
/// lock is turned on, so that a method the iPhone cannot use is not tried.
public struct DeviceAuthentication: Equatable, Sendable {
    public var biometrics: Bool
    public var passcode: Bool

    public init(biometrics: Bool, passcode: Bool) {
        self.biometrics = biometrics
        self.passcode = passcode
    }

    /// This iPhone's, now.
    public static func current() -> DeviceAuthentication {
        let c = LAContext()
        var error: NSError?
        let biometrics = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return of(
            biometrics: biometrics, biometricsError: error.map { LAError.Code(rawValue: $0.code) } ?? nil,
            passcode: c.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        )
    }

    /// From LocalAuthentication's answers. Face ID or Touch ID locked after too many attempts is set up all the same: the
    /// member unlocks the iPhone with its passcode and tries again (never told to switch to the passcode method).
    static func of(biometrics: Bool, biometricsError: LAError.Code?, passcode: Bool) -> DeviceAuthentication {
        DeviceAuthentication(biometrics: biometrics || biometricsError == .biometryLockout, passcode: passcode)
    }
}
