import Foundation

/// Time for the call state machine and the signalling: the wall clock, a clock that only moves forward (for the
/// measurements) and sleeping. The tests give them a clock they drive (virtual time; no real sleeps).
@MainActor
package protocol CallClock: AnyObject {
    /// The wall clock (the vault's `exp` is compared with it).
    func now() -> Date

    /// A clock that only moves forward, in milliseconds.
    func elapsedMs() -> Int64

    /// Sleeps for [duration]; throws `CancellationError` if the task is cancelled meanwhile.
    func sleep(for duration: Duration) async throws
}

/// The real clock.
package final class SystemCallClock: CallClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    package init() { origin = clock.now }

    package func now() -> Date { Date() }

    package func elapsedMs() -> Int64 { (clock.now - origin).wholeMilliseconds }

    package func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
