import Foundation
import VettIDData

/// The one-time notice of a lost answer's decision reached while its screen was closed (VAULT-MESSAGING §11.14.9 "A lost
/// answer": the member is told). The shell shows it above every screen until the member acknowledges it
/// (``VaultRepository/acknowledgeChangeCheck()``); a change screen that was waiting shows and acknowledges it itself, and
/// one opened later does not show it again (chosen; not in the spec).
public enum ChangeCheckNotice {
    /// The text of a decided change, nil while undecided; a refusal's text at the vault's [timeScale].
    public static func text(_ c: ChangeCheck, timeScale: UInt64 = 1) -> String? {
        switch (c.type, c.status) {
        case (_, .checking), (_, .unreachable): nil
        case (.pin, .applied): ChangeNoticeTexts.pinApplied
        case (.password, .applied): ChangeNoticeTexts.passwordApplied
        case (.pin, .notApplied): ChangeNoticeTexts.pinNotChanged
        case (.password, .notApplied): ChangeNoticeTexts.passwordNotChanged
        case (_, .refused(let kind, _)): kind.message(timeScale: timeScale)
        case (.pin, .ended): ChangeNoticeTexts.pinEnded
        case (.password, .ended): ChangeNoticeTexts.passwordEnded
        }
    }

    /// Whether the notice offers "Lock and unlock now" (§11.14.9 step 3): a PIN change's check ended without a decision,
    /// so the PIN is uncertain until the unlock's two prompts settle it.
    public static func offersLockAndUnlock(_ c: ChangeCheck) -> Bool { c.type == .pin && c.status == .ended }

    /// "Lock and unlock now" (Android's `root_change_lock_unlock`).
    public static var lockAndUnlock: String { ChangeNoticeTexts.lockUnlock }

    /// A refusal, or a check that ended without a decision.
    public static func urgent(_ c: ChangeCheck) -> Bool {
        switch c.status {
        case .refused, .ended: true
        default: false
        }
    }
}

/// The one-time notice's texts (ANDROID-PLAN 0.1.46 and 0.1.47 "Telling the member", shared with the Android app, under
/// its keys).
enum ChangeNoticeTexts {
    static var lockUnlock: String {
        String(localized: "root_change_lock_unlock", defaultValue: "Lock and unlock now", bundle: .module)
    }

    static var pinApplied: String {
        String(
            localized: "root_change_pin_applied", defaultValue: "Your PIN change went through. Use your new PIN from now on.",
            bundle: .module
        )
    }

    static var passwordApplied: String {
        String(
            localized: "root_change_password_applied",
            defaultValue: "Your password change went through. Use your new password from now on.", bundle: .module
        )
    }

    static var pinNotChanged: String {
        String(
            localized: "root_change_pin_not_changed",
            defaultValue: "Your PIN change didn't go through. Your previous PIN is still your PIN.", bundle: .module
        )
    }

    static var passwordNotChanged: String {
        String(
            localized: "root_change_password_not_changed",
            defaultValue: "Your password change didn't go through. Your previous password is still your password.", bundle: .module
        )
    }

    static var pinEnded: String {
        String(
            localized: "root_change_pin_ended",
            defaultValue: """
                VettID couldn't confirm whether your PIN was changed, because something else changed in your vault at the \
                same time. To find out without using an attempt, lock your vault and unlock it again: VettID will ask for \
                each PIN in turn.
                """,
            bundle: .module
        )
    }

    static var passwordEnded: String {
        String(
            localized: "root_change_password_ended",
            defaultValue: """
                VettID couldn't confirm whether your password was changed, because something else changed in your vault at \
                the same time. Either your previous or your new password may be the current one.
                """,
            bundle: .module
        )
    }
}
