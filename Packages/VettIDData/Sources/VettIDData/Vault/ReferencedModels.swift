import Foundation

// Models the repositories mention that belong to later features (the profile and the account's names, the signer
// binding, the member's lock): ported here as faithful models only; their managers come with their phases.

/// Where a name change stands (VAULT-MESSAGING §10.8). Mirrors vettid-android `NameRequestState`.
public enum NameRequestState: Equatable, Sendable, CaseIterable {
    /// Sent to VettID; the account's names change once the member API applies it.
    case pending
    case applied
    case refused

    /// The wire state (`pending`, `applied`, `refused`); nil for a state this app does not know.
    public static func of(_ wire: String) -> NameRequestState? {
        switch wire {
        case "pending": .pending
        case "applied": .applied
        case "refused": .refused
        default: nil
        }
    }
}

/// The latest `account.name.set` request (VAULT-MESSAGING §10.8): [reason] (`too_soon`, `invalid`, `account`) only when
/// refused. Mirrors vettid-android `NameRequestView`.
public struct NameRequestView: Equatable, Sendable {
    public static let reasonTooSoon = "too_soon"
    public static let reasonInvalid = "invalid"
    public static let reasonAccount = "account"

    public var seq: Int64
    public var firstName: String
    public var lastName: String
    public var requestedAt: Date?
    public var state: NameRequestState
    public var reason: String?

    public init(seq: Int64, firstName: String, lastName: String, requestedAt: Date?, state: NameRequestState, reason: String? = nil) {
        self.seq = seq
        self.firstName = firstName
        self.lastName = lastName
        self.requestedAt = requestedAt
        self.state = state
        self.reason = reason
    }
}

/// The class of a signer (VAULT-MESSAGING §11.7.1): who holds the key that signed an installation. An identifier from
/// the spec's table; the vault never supplies member-facing wording, the app does. The cases are Android's table; the
/// iOS classes come with the iOS signer binding. Mirrors vettid-android `SignerClass`.
public enum SignerClass: String, Equatable, Sendable, CaseIterable {
    /// Signed with a key only VettID holds: the F-Droid and direct builds.
    case vettid = "vettid"
    /// Signed with the Play app-signing key, which Google holds.
    case googlePlay = "google_play"
    /// A development or automation key (never pinned by a production release).
    case development = "development"

    /// The wire name.
    public var wire: String { rawValue }

    /// The class the vault named, or nil for a name this app does not know (or none).
    public static func of(_ wire: String?) -> SignerClass? { wire.flatMap(SignerClass.init(rawValue:)) }
}

/// The vault's signer binding as the app's own `device.list` entry shows it (VAULT-MESSAGING §10.3): [signerClass] for
/// the "Installed from" line, [digest] (64 lowercase hex digits of the signing certificate's SHA-256, public) for a
/// details view and for support. Mirrors vettid-android `SignerView`.
public struct SignerView: Equatable, Sendable {
    public var signerClass: SignerClass
    public var digest: String

    public init(signerClass: SignerClass, digest: String) {
        self.signerClass = signerClass
        self.digest = digest
    }
}

/// What the member is told about the lock they asked for (VAULT-LOCK). Mirrors vettid-android `LockNotice`.
public enum LockNotice: Equatable, Sendable {
    /// Nothing to say: no lock is waiting, or it was confirmed without ever having been in doubt.
    case none
    /// The lock is not confirmed. This phone is locked all the same and keeps trying. [attempts] is how many tries have
    /// failed: at 0 the first try is running (the member is told that the vault is being locked, without a warning);
    /// from 1 on the vault could not be told and may still be open (``inDoubt``).
    case unconfirmed(askedAt: Date, attempts: Int)
    /// The vault has now confirmed a lock that was in doubt: said once, until dismissed or the next unlock.
    case confirmedLate
    /// (Release L) The vault said that the unlock this lock was for is over: it was opened again since (`stale_lock`, or the
    /// slot's `stale`), and the status did not say it is locked now. The lock is finished and not repeated (VAULT-MESSAGING
    /// §10.2 "Locks"), but the vault is **not** known to be locked: it may be open. This phone stays locked until the member
    /// unlocks it here (``LockKeeper/holdsPhone``). Said until dismissed or the next unlock.
    case openedAgain

    /// At least one try failed: the vault may still be open.
    public var inDoubt: Bool {
        if case .unconfirmed(_, let attempts) = self { return attempts > 0 }
        return false
    }
}
