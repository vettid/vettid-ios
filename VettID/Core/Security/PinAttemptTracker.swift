import Foundation

/// SECURITY (Area E #97): durable client-side rate-limit on PIN unlock
/// attempts. Mirrors Android `PinAttemptTracker`.
///
/// The enclave does coarse rate-limiting at the NATS layer, and
/// `UnlockRateLimiter` already smears per-process attempts with
/// exponential backoff — but neither survives a process kill. A
/// stolen device can be UI-automation-driven against the PIN form,
/// killing + relaunching the app between batches to drop the
/// in-memory counter. `PinAttemptTracker` is the wall-clock penalty
/// that survives restart by persisting to UserDefaults.
///
/// Lockout schedule (matches Android 4f29f48):
///   • attempts 1-4:  no lockout
///   • attempt 5:     30s lockout
///   • attempt 10:    5 min lockout
///   • attempt 15:    30 min lockout
///   • attempt 20+:   60 min lockout (caps here)
///
/// A successful warm zeroes both the counter and the lockout
/// deadline via `reset()`.
final class PinAttemptTracker {

    /// Process-wide shared instance.
    static let shared = PinAttemptTracker()

    private static let suiteName = "com.vettid.app.pin.attempts"
    private static let keyFailedAttempts = "failed_attempts"
    private static let keyLockedUntilEpoch = "locked_until_epoch_seconds"

    /// Backing store. A dedicated suite keeps these keys out of the
    /// app's main UserDefaults so a separate component clearing
    /// `UserDefaults.standard` can't accidentally reset the lockout.
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.suiteName)
            ?? .standard
    }

    /// Seconds until unlock attempts are allowed again; 0 if unlocked.
    func remainingLockoutSeconds(now: Date = Date()) -> TimeInterval {
        let until = defaults.double(forKey: Self.keyLockedUntilEpoch)
        guard until > 0 else { return 0 }
        return max(until - now.timeIntervalSince1970, 0)
    }

    /// True when the user must wait before trying another PIN.
    func isLockedOut(now: Date = Date()) -> Bool {
        remainingLockoutSeconds(now: now) > 0
    }

    /// Total failed attempts since the last successful unlock.
    func failedAttempts() -> Int {
        defaults.integer(forKey: Self.keyFailedAttempts)
    }

    /// Record a failed PIN attempt and apply the matching lockout if
    /// any. Returns the lockout duration applied in seconds (0 = no
    /// lockout yet, more attempts allowed).
    @discardableResult
    func recordFailure(now: Date = Date()) -> TimeInterval {
        let attempts = failedAttempts() + 1
        let lockoutSeconds = Self.lockoutForAttempts(attempts)
        defaults.set(attempts, forKey: Self.keyFailedAttempts)
        if lockoutSeconds > 0 {
            defaults.set(
                now.timeIntervalSince1970 + lockoutSeconds,
                forKey: Self.keyLockedUntilEpoch
            )
        } else {
            defaults.removeObject(forKey: Self.keyLockedUntilEpoch)
        }
        return lockoutSeconds
    }

    /// Reset all tracking after a successful unlock.
    func reset() {
        defaults.removeObject(forKey: Self.keyFailedAttempts)
        defaults.removeObject(forKey: Self.keyLockedUntilEpoch)
    }

    /// Human-readable lockout label for the UI ("30 seconds", "5 minutes").
    func lockoutLabel(now: Date = Date()) -> String {
        let remaining = remainingLockoutSeconds(now: now)
        if remaining <= 0 { return "" }
        if remaining < 60 {
            return "\(Int(remaining.rounded(.up))) seconds"
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// Lockout schedule. Matches Android's `lockoutForAttempts`.
    private static func lockoutForAttempts(_ attempts: Int) -> TimeInterval {
        switch attempts {
        case let n where n >= 20: return 60 * 60   // 60 min
        case let n where n >= 15: return 30 * 60   // 30 min
        case let n where n >= 10: return 5 * 60    // 5 min
        case let n where n >= 5:  return 30        // 30s
        default: return 0
        }
    }
}
