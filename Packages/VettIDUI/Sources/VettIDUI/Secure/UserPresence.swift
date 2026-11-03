import LocalAuthentication
import SwiftUI

/// Confirms that the iPhone's owner is holding it before something sensitive is shown (a secret item's values,
/// VAULT-MESSAGING §10.7: "revealed on purpose"): Face ID, Touch ID or the passcode (`deviceOwnerAuthentication`). A
/// convenience layer only, like the app lock: it never replaces the vault PIN or the credential password. True when
/// confirmed, or when the iPhone has no passcode to confirm with (``hasPasscode`` tells that case apart, so that a screen
/// can say once that revealed items are then unprotected). Mirrors vettid-android `UserPresence`.
public struct UserPresence: Sendable {
    let confirm: @MainActor @Sendable (_ reason: String) async -> Bool
    /// Whether the iPhone has a passcode (or biometry) to confirm with; false is the case in which [confirm] is true at once.
    let passcodeSet: @MainActor @Sendable () -> Bool

    public init(
        hasPasscode: @escaping @MainActor @Sendable () -> Bool = { true },
        _ confirm: @escaping @MainActor @Sendable (_ reason: String) async -> Bool
    ) {
        passcodeSet = hasPasscode
        self.confirm = confirm
    }

    /// False on an iPhone with no passcode, where "confirmed" means nothing.
    @MainActor
    public var hasPasscode: Bool { passcodeSet() }

    /// Asks for the owner with [reason] (what iOS shows in its prompt).
    @MainActor
    public func callAsFunction(_ reason: String) async -> Bool { await confirm(reason) }

    /// This iPhone's Face ID, Touch ID or passcode. Only "no passcode set" lets the reveal go on unasked: there is nothing
    /// to confirm with, and the app lock cannot exist either (its key needs a passcode or biometrics). Any other reason the
    /// policy cannot be evaluated refuses (fails closed).
    public static let device = UserPresence(
        hasPasscode: { canAsk(LAContext()) != .noPasscode },
        { reason in
            let context = LAContext()
            switch canAsk(context) {
            case .noPasscode: return true
            case .unavailable: return false
            case .available:
                return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
            }
        }
    )

    /// Whether the owner can be asked on this iPhone.
    enum Availability: Equatable { case available, noPasscode, unavailable }

    /// The answer of `canEvaluatePolicy`: only `LAError.passcodeNotSet` means the iPhone has no passcode.
    static func availability(canEvaluate: Bool, error: Error?) -> Availability {
        if canEvaluate { return .available }
        return (error as? LAError)?.code == .passcodeNotSet ? .noPasscode : .unavailable
    }

    private static func canAsk(_ context: LAContext) -> Availability {
        var error: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return availability(canEvaluate: can, error: error)
    }

    /// Tests: an iPhone with no passcode (confirmed at once, as ``device`` is there).
    public static let noPasscode = UserPresence(hasPasscode: { false }, { _ in true })

    /// Previews, tests and the screen catalog: confirmed at once.
    public static let confirmed = UserPresence { _ in true }
}

public extension EnvironmentValues {
    /// How the owner's presence is confirmed (``UserPresence/device`` unless a preview or a test sets another).
    @Entry var vettIDUserPresence: UserPresence = .device
}
