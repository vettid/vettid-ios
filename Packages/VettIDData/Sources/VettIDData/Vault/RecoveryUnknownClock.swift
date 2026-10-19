import Foundation
import VettIDCrypto

/// (VAULT-MESSAGING §11.14.5, §11.14.11) A recovery counter unavailable at every read of `vault.status` for 24 hours is
/// shown with the urgency of a used attempt. Every status read that carries `recovery` moves this clock; one that finds
/// the counter available stops it. Times are this phone's clock (Unix ms).
///
/// (STAGING-TIME-SCALE 0.1.1 S8; IOS-PLAN 0.1.7 §6.6) The 24 hours are divided by the vault's time scale when the clock
/// starts (``periodMs(timeScale:)``: 1 hour at 24), and the period is kept with the start: a clock started under one
/// scale ends at the time it was given. Mirrors vettid-android `RecoveryUnknownClock`.
enum RecoveryUnknownClock {
    /// The real-time period: 24 hours.
    static let urgentMs = Int64(TimeScales.recoveryUnknownDay) * 1_000

    /// The urgency's period for a clock that starts on a vault of [timeScale].
    static func periodMs(timeScale: UInt64) -> Int64 { TimeScale.scaledMs(urgentMs, by: timeScale) }

    /// `recovery.counter` `unavailable`, or the recovery `unknown`.
    static func unavailable(state: String?, counter: String?) -> Bool {
        counter == VaultManager.counterUnavailable || state == "unknown"
    }

    /// The clock as the account record keeps it: [since] (``LocalAccount/recoveryUnknownSinceMs``) and the period stored
    /// with it (``LocalAccount/recoveryUnknownForMs``; nil: 24 hours, a clock started in real time or before the scale).
    struct State: Equatable, Sendable {
        var since: Int64?
        var periodMs: Int64?

        init(since: Int64? = nil, periodMs: Int64? = nil) {
            self.since = since
            self.periodMs = periodMs
        }

        /// The period this clock runs for: the stored one, never longer than 24 hours nor shorter than at the largest
        /// scale any build takes.
        var period: Int64 { Self.clamp(periodMs ?? urgentMs, maxScale: TimeScale.maxDevelopment) }

        /// This clock as a build that accepts at most [maxScale] reads it: a stored period shorter than that scale gives
        /// is lengthened to it, so that a record written elsewhere never shortens the wait (in a production build, 24
        /// hours whatever is stored).
        func validated(maxScale: UInt64) -> State {
            guard let p = periodMs else { return self }
            let v = Self.clamp(p, maxScale: maxScale)
            return State(since: since, periodMs: v == urgentMs ? nil : v)
        }

        private static func clamp(_ p: Int64, maxScale: UInt64) -> Int64 {
            min(max(p, RecoveryUnknownClock.periodMs(timeScale: maxScale)), urgentMs)
        }

        func urgent(nowMs: Int64) -> Bool {
            guard let since else { return false }
            return nowMs - since >= period
        }
    }

    /// The clock after a read at [nowMs] on a vault of [timeScale]. A clock that starts (or starts again, after the
    /// phone's clock was set back) takes its period from [timeScale]; a running one keeps the period it started with.
    static func advance(_ cur: State, unavailable: Bool, nowMs: Int64, timeScale: UInt64) -> State {
        guard unavailable else { return State() }
        if let since = cur.since, since <= nowMs { return cur }
        let period = periodMs(timeScale: timeScale)
        return State(since: nowMs, periodMs: period == urgentMs ? nil : period)
    }
}
