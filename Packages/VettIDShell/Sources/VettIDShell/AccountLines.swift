import Foundation
import VettIDData

/// The membership as the avatar sheet says it (VAULT-MESSAGING §11.13). Mirrors vettid-android `AccountSheet`'s
/// `membershipLine` and `AccountDetails`.
public enum MembershipLine: Equatable, Sendable {
    /// No snapshot yet: the sheet's header says "VettID account", its details "Shown once…".
    case unknown
    case member
    case registered
    /// Cancelled; [deletesAt] when the vault is deleted.
    case canceled(deletesAt: Date?)

    public static let stateMember = "member"

    public static func of(_ a: AccountInfo?) -> MembershipLine {
        guard let a, a.hasSnapshot else { return .unknown }
        if a.canceled { return .canceled(deletesAt: a.deletesAt) }
        return a.state == stateMember ? .member : .registered
    }
}

/// The subscription as the avatar sheet says it at [now] (VAULT-MESSAGING §11.13): its name (or "Subscription"), its status and until when.
/// Mirrors vettid-android `subscriptionText`.
public enum SubscriptionLine: Equatable, Sendable {
    case none
    case trial(name: String?, until: Date?)
    case active(name: String?, until: Date?)
    case expired(name: String?)
    case canceled(name: String?)
    /// A status this app does not know: the name alone.
    case other(name: String?)

    public static func of(_ s: SubscriptionInfo?, now: Date) -> SubscriptionLine {
        guard let s else { return .none }
        let name = s.typeName.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        switch s.status(at: now) {
        case SubscriptionInfo.statusTrial: return .trial(name: name, until: s.expiresAt)
        case SubscriptionInfo.statusActive: return .active(name: name, until: s.expiresAt)
        case SubscriptionInfo.statusExpired: return .expired(name: name)
        case SubscriptionInfo.statusCanceled: return .canceled(name: name)
        default: return .other(name: name)
        }
    }
}

/// The avatar sheet's header and the top bar (vettid-android `AccountSheet`, `VettIdApp`): the first and last name, else
/// the address, else [placeholder]; under it the address when the names show, else the membership. Only while the vault
/// is open (IOS-PLAN §4.7, ``Optional/shownInShell``): otherwise [placeholder] and the initial tile, never the masked
/// hint (which only the unlock screen shows).
public enum AccountHeader {
    public static func name(_ account: AccountInfo?, placeholder: String) -> String {
        let a = account.shownInShell
        return a?.fullName ?? a?.displayEmail ?? placeholder
    }

    /// The address under the names; nil: the membership line goes there.
    public static func detailEmail(_ account: AccountInfo?) -> String? {
        guard let a = account.shownInShell, a.fullName != nil else { return nil }
        return a.displayEmail
    }
}
