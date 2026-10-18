import Foundation

/// Screens a member could not leave (owner decision: a vault problem must have a path forward). Where the vault cannot be
/// reached for a long time, the root screen offers to erase VettID from this phone or to recover the vault, besides "Try
/// again". Mirrors vettid-android `StuckScreens`.
public enum StuckScreens {
    /// How long without any contact with the vault service before erase-or-recover is offered beside "Try again": 7 days.
    public static let longUnreachableMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// A last contact is written at most this often (every start and return reads the status).
    public static let contactWriteEveryMs: Int64 = 60 * 60 * 1000

    /// Failures that already have their own way out, or none to offer (the phone's clock is the member's to fix).
    private static let ownWay: Set<FailureKind> = [.clock, .noVault, .localState, .eraseFailed, .unauthorized]

    /// Whether the root screen for [kind] also offers erase-or-recover because nothing has reached the vault service for
    /// ``longUnreachableMs``: [lastContactMs] is the last contact this phone knows of (nil: none known, nothing offered).
    public static func longUnreachable(_ kind: FailureKind, lastContactMs: Int64?, nowMs: Int64) -> Bool {
        guard !ownWay.contains(kind), let last = lastContactMs else { return false }
        return nowMs - last >= longUnreachableMs
    }

    /// Whether a contact at [nowMs] is worth writing over [lastContactMs].
    public static func writeContact(_ lastContactMs: Int64?, nowMs: Int64) -> Bool {
        guard let last = lastContactMs else { return true }
        return nowMs - last >= contactWriteEveryMs || nowMs < last
    }
}
