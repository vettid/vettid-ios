#if os(iOS)
import Foundation
import VettIDData
import VettIDOnboarding
import VettIDUI

/// A failure with the wait the vault asked for (`retry_after`, a `429` or a backoff): "Too many attempts. Try again in …" in
/// Android's words of the recovery (`recover_rate_limited_wait`), with the spoken form; any other failure, or no wait left,
/// is the failure's own text. Shared by every screen that sends a PIN, a password or a code.
public enum WaitText {
    /// The seconds still to wait until [retryAt], or nil when none are left.
    public static func seconds(until retryAt: Date?, now: Date = Date()) -> Int64? {
        guard let retryAt else { return nil }
        let s = Int64(retryAt.timeIntervalSince(now).rounded(.up))
        return s > 0 ? s : nil
    }

    static func waits(_ kind: FailureKind, _ retryAt: Date?, now: Date) -> Int64? {
        kind == .rateLimited || kind == .backoff ? seconds(until: retryAt, now: now) : nil
    }

    public static func message(_ kind: FailureKind, retryAt: Date?, timeScale: UInt64, now: Date = Date()) -> String {
        guard let wait = waits(kind, retryAt, now: now) else { return kind.message(timeScale: timeScale) }
        return RecoveryStrings.recoverRateLimitedWait(formatWait(wait))
    }

    /// What VoiceOver speaks instead of ``message(_:retryAt:timeScale:now:)``, or nil when it is the same text.
    public static func spoken(_ kind: FailureKind, retryAt: Date?, now: Date = Date()) -> String? {
        waits(kind, retryAt, now: now).map { RecoveryStrings.recoverRateLimitedWait(spokenDuration($0)) }
    }
}
#endif
