import Foundation
import Observation

/// "Allow screenshots" (IOS-PLAN §4 Settings → App, ID10; vettid-android `ScreenshotAllowance`, owner decision
/// 2026-10-11). It turns off only the secure layer of the screens that hold it (VettIDUI `SecureContainer`); the
/// app-switcher cover and capture hiding stay. Kept in memory only: never on at app start, never written to disk, never
/// sent to the vault. It turns itself off when the vault locks and ``lifetime`` after it was turned on, whichever comes
/// first.
///
/// [onByDefault] is for the development builds (Debug, DevStack), whose screens are screenshotted all the time (the
/// screen catalog): there the allowance is on from the start and nothing but the switch turns it off.
@MainActor
@Observable
public final class ScreenshotAllowance {
    public static let lifetime: TimeInterval = 3600

    /// Screenshots and screen recordings may show the screens that are otherwise secure.
    public private(set) var allowed: Bool
    /// True in the builds where the allowance does not end by itself (shown by the Settings row).
    public let staysOn: Bool

    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private var until: TimeInterval?
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// [now]: a clock that also runs while the phone sleeps (seconds; ``continuousSeconds()`` by default).
    public init(onByDefault: Bool, now: @escaping @Sendable () -> TimeInterval = ScreenshotAllowance.continuousSeconds) {
        allowed = onByDefault
        staysOn = onByDefault
        self.now = now
    }

    /// The member confirmed: on, for at most an hour.
    public func allow() {
        allowed = true
        guard !staysOn else { return }
        until = now() + Self.lifetime
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime), clock: .continuous)
            self?.check()
        }
    }

    /// The member turned it off.
    public func disallow() {
        timer?.cancel()
        timer = nil
        until = nil
        allowed = false
    }

    /// The vault is no longer open (locked, signed out, unreachable): the allowance ends.
    public func vaultClosed() {
        if !staysOn { disallow() }
    }

    /// Ends an allowance whose hour is over. Called by the timer and on every return to the app.
    public func check() {
        guard let end = until, now() >= end else { return }
        disallow()
    }

    private nonisolated static let origin = ContinuousClock.now

    /// Seconds on `ContinuousClock`, which keeps advancing while the system sleeps.
    public nonisolated static func continuousSeconds() -> TimeInterval {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
