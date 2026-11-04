import Foundation
import VettIDData

/// The wait the vault asked for after a PIN or password attempt, kept where it outlives the screen (VAULT-MESSAGING §10.1: the
/// app does not resend before the wait ends): closing and reopening the screen, or the app leaving the foreground, does not end
/// it. One per operation. The app owns one (``shared``) and clears it when the vault is no longer open (a lock, a wipe).
@MainActor
public final class WaitRegistry {
    /// The operations that send a PIN or a password and can be told to wait.
    public enum Operation: Sendable, Hashable {
        case changePin, changePassword, deleteVault, newCredential, newPhoneSecret, rotate, unlockWindow
    }

    /// The registry the screens use.
    public static let shared = WaitRegistry()

    private var waits: [Operation: (kind: FailureKind, deadline: WaitDeadline)] = [:]

    public init() {}

    /// What [operation] was told, while its wait runs; an ended wait is forgotten.
    public func current(_ operation: Operation) -> (kind: FailureKind, deadline: WaitDeadline)? {
        guard let w = waits[operation] else { return nil }
        if w.deadline.isRunning() { return w }
        waits[operation] = nil
        return nil
    }

    /// [operation] failed with [error]: its wait, if it asked for one, is kept; any other failure ends what was kept.
    public func record(_ operation: Operation, error: any Error) -> WaitDeadline? {
        guard let f = error as? VaultFailure, f.kind == .rateLimited || f.kind == .backoff, f.retryAfterSeconds > 0 else {
            waits[operation] = nil
            return nil
        }
        let deadline = WaitDeadline(seconds: f.retryAfterSeconds)
        waits[operation] = (f.kind, deadline)
        return deadline
    }

    /// The vault is no longer open: nothing is kept.
    public func clearAll() { waits = [:] }
}
