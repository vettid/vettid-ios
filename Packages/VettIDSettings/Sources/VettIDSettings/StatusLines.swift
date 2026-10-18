import Foundation
import VettIDData

/// Where this build of the app was installed from (IOS-PLAN ID15): App Attest reports no signer and an iPhone's vault
/// binding has none (VAULT-MESSAGING §11.7.1), so Settings → Vault status says it from the build configuration: Apple for
/// the Release and Staging builds, Xcode for the development builds (Debug, DevStack). The app decides; the screen only
/// shows it.
public enum InstalledFrom: Equatable, Sendable {
    /// The App Store or TestFlight (Release, Staging).
    case apple
    /// Xcode (Debug, DevStack): the line's text is the app's own, in its development builds only.
    case development(label: String)
}

/// The Recovery line of Settings → Vault status from `vault.status` (ANDROID-PLAN §4 "Recovery and unlock from release R", "Owner check and status"): on
/// with the attempts used, the used-attempts warning, all ten used, set up at the next check, off, a new password needed,
/// and "cannot be checked right now" for `unknown`, never "0 of 10". Mirrors vettid-android `recoveryStatusText`.
public enum RecoveryLine: Equatable, Sendable {
    case armed(used: Int)
    case used(Int)
    case exhausted
    case changeRequired
    case needsCheck
    case off
    case unknown

    public static let attempts = 10

    public static func of(_ r: RecoveryStatusView) -> RecoveryLine {
        let used = r.used
        switch r.state {
        case "armed":
            guard let used else { return .unknown }
            if used >= attempts { return .exhausted }
            return used > 0 ? .used(used) : .armed(used: 0)
        case "change_required":
            if let used, used >= attempts { return .exhausted }
            return .changeRequired
        case "needs_check": return .needsCheck
        case "off": return .off
        default: return .unknown
        }
    }
}
