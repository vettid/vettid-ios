import LocalAuthentication
import SwiftUI

/// Confirms that the iPhone's owner is holding it before something sensitive is shown (a secret item's values,
/// VAULT-MESSAGING §10.7: "revealed on purpose"): Face ID, Touch ID or the passcode (`deviceOwnerAuthentication`). A
/// convenience layer only, like the app lock: it never replaces the vault PIN or the credential password. True when
/// confirmed, or when the iPhone has no passcode to confirm with. Mirrors vettid-android `UserPresence`.
public struct UserPresence: Sendable {
    let confirm: @MainActor @Sendable (_ reason: String) async -> Bool

    public init(_ confirm: @escaping @MainActor @Sendable (_ reason: String) async -> Bool) { self.confirm = confirm }

    /// Asks for the owner with [reason] (what iOS shows in its prompt).
    @MainActor
    public func callAsFunction(_ reason: String) async -> Bool { await confirm(reason) }

    /// This iPhone's Face ID, Touch ID or passcode.
    public static let device = UserPresence { reason in
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Previews, tests and the screen catalog: confirmed at once.
    public static let confirmed = UserPresence { _ in true }
}

public extension EnvironmentValues {
    /// How the owner's presence is confirmed (``UserPresence/device`` unless a preview or a test sets another).
    @Entry var vettIDUserPresence: UserPresence = .device
}
