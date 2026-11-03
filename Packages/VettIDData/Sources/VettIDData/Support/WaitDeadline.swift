import Foundation

/// The end of a wait the vault asked for (`retry_after`), on a monotonic clock that goes on while the phone sleeps
/// (``ContinuousClock``), so that a countdown counted in one-second ticks shows what is left after the app was suspended,
/// not a wait that is too long (chosen; not in the spec). Each tick takes at least one second off, so a clock that has not
/// moved (a test's virtual ticks) still counts down.
public struct WaitDeadline: Sendable {
    private let end: ContinuousClock.Instant

    /// The wait ends [seconds] from now.
    public init(seconds: Int64, now: ContinuousClock.Instant = .now) {
        end = now.advanced(by: .seconds(max(seconds, 0)))
    }

    /// The seconds left after a tick, when [current] were shown before it: at most one less, and no more than the clock says.
    public func left(after current: Int64, now: ContinuousClock.Instant = .now) -> Int64 {
        let parts = (end - now).components
        let real = parts.seconds + (parts.attoseconds > 0 ? 1 : 0)
        return max(min(current - 1, real), 0)
    }
}
