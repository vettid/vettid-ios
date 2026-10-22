import Foundation
import VettIDData

/// Why the credential password is asked for (every read or change of a critical item is a credential operation, §10.7).
/// Mirrors vettid-android `PasswordPurpose`.
public enum PasswordPurpose: Sendable {
    case open, save, delete, protection
}

/// The credential-password step of a critical operation. [error] is the last refusal (`bad_password`, or another
/// failure); [retryUntil] the end of a password backoff (`retry_after`, VAULT-MESSAGING 0.17.0), during which the send
/// button stays off. The password lives in view-model state only, is cleared after every answer, and is never printed or
/// reflected. Mirrors vettid-android `PasswordPrompt`.
public struct PasswordPrompt: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var purpose: PasswordPurpose
    public var password = ""
    public var busy = false
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?
    public var retryUntil: Date?

    public init(_ purpose: PasswordPurpose) { self.purpose = purpose }

    public func canSend(_ now: Date) -> Bool { !password.isEmpty && !busy && (retryUntil.map { now >= $0 } ?? true) }

    /// After a refusal: the password cleared, the error and any backoff kept.
    public func refused(_ e: VaultFailure, now: Date) -> PasswordPrompt {
        var p = self
        p.password = ""
        p.busy = false
        p.error = e.kind
        p.errorCode = e.code
        p.retryUntil = e.kind == .backoff && e.retryAfterSeconds > 0 ? now.addingTimeInterval(TimeInterval(e.retryAfterSeconds)) : nil
        return p
    }

    /// The seconds of a running backoff at [now] (rounded up), 0 when none.
    public func waiting(_ now: Date) -> Int {
        guard let retryUntil, retryUntil > now else { return 0 }
        return Int(retryUntil.timeIntervalSince(now).rounded(.up))
    }

    /// The line under the password field: a running backoff, a wrong password, an undated backoff, another failure.
    public func errorText(_ now: Date) -> String? {
        let w = waiting(now)
        if w > 0 { return ItemsStrings.passwordBackoff(w) }
        switch error {
        case .badPassword?: return ItemsStrings.passwordWrong
        case .backoff?: return ItemsStrings.passwordBackoffUndated
        case let e?:
            if e == .other, let errorCode { return FailureKind.vaultCode(ItemsText.shown(errorCode)).message }
            return e.message
        case nil: return nil
        }
    }

    /// The step's title, by its purpose.
    public var title: String {
        switch purpose {
        case .open: ItemsStrings.passwordOpenTitle
        case .save: ItemsStrings.passwordSaveTitle
        case .delete: ItemsStrings.passwordDeleteTitle
        case .protection: ItemsStrings.passwordProtectionTitle
        }
    }

    public var description: String { "PasswordPrompt(\(purpose), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
