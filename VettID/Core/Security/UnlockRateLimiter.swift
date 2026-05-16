import Foundation

/// Per-process rate limiter for `vault.warm` / `credential.identity-unlock`
/// and the other password-gated operations that share its UTK pool.
///
/// The vault already enforces single-use UTKs on AEAD success, but the pool
/// is large enough that a stolen-but-locked phone gives an attacker
/// meaningful runway for online password guessing. This limiter adds:
///
///   - Exponential backoff after each consecutive failure (200ms doubling
///     to 30s) to soak up wall-clock time.
///   - A hard ceiling (`hardCap`) after which we refuse to forward the
///     request at all and require the user to relaunch the app. Process
///     restart resets the counter — paired with a hard wipe for repeat
///     offenders.
///
/// SECURITY (auth-H2). Implemented as an `actor` so the counter is safely
/// shared across concurrent unlock attempts; it survives store
/// re-instantiation but resets on app process death.
actor UnlockRateLimiter {

    /// Process-wide shared instance.
    static let shared = UnlockRateLimiter()

    /// Consecutive-failure count at which further attempts are refused.
    static let hardCap = 10

    private var consecutiveFailures = 0
    private var lastFailureAt: Date?

    /// Call before issuing the unlock request. Suspends for the computed
    /// backoff window, then returns `true` if the attempt may proceed, or
    /// `false` if the hard cap has been hit (caller must refuse the op).
    func beforeAttempt() async -> Bool {
        if consecutiveFailures >= Self.hardCap {
            #if DEBUG
            print("[UnlockRateLimiter] Hit hard cap (\(consecutiveFailures)); refusing")
            #endif
            return false
        }
        if consecutiveFailures > 0 {
            let delayMs = backoffMs(failures: consecutiveFailures)
            #if DEBUG
            print("[UnlockRateLimiter] Throttling attempt \(consecutiveFailures) (delay=\(delayMs)ms)")
            #endif
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        return true
    }

    /// Call when the unlock attempt succeeded.
    func recordSuccess() {
        consecutiveFailures = 0
        lastFailureAt = nil
    }

    /// Call when the unlock attempt failed (wrong password, vault rejection).
    func recordFailure() {
        consecutiveFailures = min(consecutiveFailures + 1, Int.max / 2)
        lastFailureAt = Date()
    }

    /// Snapshot for UI ("X attempts remaining").
    var remainingAttempts: Int {
        max(Self.hardCap - consecutiveFailures, 0)
    }

    /// Whether the hard cap has been reached and a relaunch is required.
    var isLocked: Bool {
        consecutiveFailures >= Self.hardCap
    }

    /// 200ms * 2^(failures-1), capped at 30s.
    private func backoffMs(failures: Int) -> Int {
        let exponent = min(failures - 1, 8)
        let ms = 200 << exponent
        return min(ms, 30_000)
    }
}
