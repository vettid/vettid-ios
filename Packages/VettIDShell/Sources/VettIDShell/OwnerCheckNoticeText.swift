import Foundation
import VettIDData

/// What an `owner_check.*` feed item says in the shell's banner (VAULT-MESSAGING §3.6.4, §3.6.7). Mirrors vettid-android
/// `OwnerCheckBanners`' `noticeText` and `holdChangedText`.
public enum OwnerCheckNoticeText: Equatable, Sendable {
    case locked
    /// `ref` `pin`: a wrong PIN on a daily check or on another operation that checks the PIN as one does
    /// (VAULT-MESSAGING §3.6.1, e.g. a wallet limit raise), so the text doesn't say "daily".
    case failedPin
    case failedPassword
    case failed
    case holdOff
    case holdOffUntil(Date)
    case holdOn
    case holdExpired

    static let offUntil = "off_until:"

    public static func of(_ n: OwnerCheckNotice) -> OwnerCheckNoticeText {
        switch n.kind {
        case "owner_check.locked": return .locked
        case "owner_check.failed":
            switch n.ref {
            case "pin": return .failedPin
            case "password": return .failedPassword
            default: return .failed
            }
        default: return holdChanged(n.ref)
        }
    }

    /// `owner_check.hold_changed`'s `ref` (VAULT-MESSAGING §3.6.7): `on`, `off`, `off_until:<ts>` or `on:expired`.
    static func holdChanged(_ ref: String?) -> OwnerCheckNoticeText {
        if let ref, ref.hasPrefix(offUntil) {
            return OwnerCheckManager.instant(String(ref.dropFirst(offUntil.count))).map { .holdOffUntil($0) } ?? .holdOff
        }
        switch ref {
        case "off": return .holdOff
        case "on:expired": return .holdExpired
        default: return .holdOn
        }
    }
}
