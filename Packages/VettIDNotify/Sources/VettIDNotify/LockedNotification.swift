import Foundation
import VettIDData

/// What the notification for a locked vault says (Security channel): "Your vault is locked" when it was locked from another
/// device, and (VAULT-MESSAGING §3.6.8, release L) "Your vault locked itself" with the time past the deadline when no check
/// was passed in time. Nothing posts it yet (no system notifications before phase P, IOS-PLAN §6.7). Mirrors vettid-android
/// `FeedNotifier.onLocked` and `durationText`; the idle lock's texts as ANDROID-PLAN §4 "Locking the vault" part 2 (approved
/// by the owner 2026-10-24).
public struct LockedNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    /// What the lock screen shows when the member hides previews.
    public let publicTitle: String

    /// The notification for a vault that locked: [idle] when it locked itself (``OwnerCheckRepository/idleLockedNow(_:)``).
    public static func of(idle: IdleLocked?) -> LockedNotification {
        let publicTitle = text("notify_public_attention", "VettID needs your attention")
        guard let idle else {
            return LockedNotification(
                title: text("notify_locked_title", "Your vault is locked"),
                body: text("notify_locked_body", "You won’t be notified until you unlock it"), publicTitle: publicTitle
            )
        }
        let body = if let after = idle.afterSeconds {
            String(
                format: text(
                    "notify_idle_locked_body",
                    "You hadn’t checked in for %@, so your vault locked. Unlock it with your PIN to carry on. "
                        + "New messages wait for up to 14 days."
                ),
                IdleLockText.duration(after)
            )
        } else {
            text(
                "notify_idle_locked_body_unknown",
                "You hadn’t checked in, so your vault locked. Unlock it with your PIN to carry on. New messages wait for up to 14 days."
            )
        }
        return LockedNotification(title: text("notify_idle_locked_title", "Your vault locked itself"), body: body, publicTitle: publicTitle)
    }

    private static func text(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: nil)
    }
}
