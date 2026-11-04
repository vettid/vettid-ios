#if os(iOS)
import Foundation
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

/// A failure with the wait the vault asked for (`retry_after`, a `429` or a backoff): "Too many attempts. Try again in …" in
/// Android's words of the recovery (`recover_rate_limited_wait`), with the spoken form; any other failure, or no wait left,
/// is the failure's own text. Shared by every screen that sends a PIN, a password or a code. The wait is a
/// ``WaitDeadline`` (a monotonic clock), and a screen holds its send back while it runs (VAULT-MESSAGING §10.1).
public enum WaitText {
    /// The seconds still to wait, or nil when none are left.
    public static func seconds(until wait: WaitDeadline?, now: ContinuousClock.Instant = .now) -> Int64? {
        guard let wait else { return nil }
        let s = wait.remaining(now: now)
        return s > 0 ? s : nil
    }

    static func waits(_ kind: FailureKind, _ wait: WaitDeadline?, now: ContinuousClock.Instant) -> Int64? {
        kind == .rateLimited || kind == .backoff ? seconds(until: wait, now: now) : nil
    }

    /// The wait as `m:ss`, and as `h:mm:ss` from an hour (not "120:00"; chosen, not in the spec).
    public static func clock(_ seconds: Int64) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60) : formatWait(seconds)
    }

    public static func message(
        _ kind: FailureKind, retryAt: WaitDeadline?, timeScale: UInt64, now: ContinuousClock.Instant = .now
    ) -> String {
        guard let wait = waits(kind, retryAt, now: now) else { return kind.message(timeScale: timeScale) }
        return RecoveryStrings.recoverRateLimitedWait(clock(wait))
    }

    /// What a field's error says to VoiceOver while its visible wait counts down: the failure's own text, the same at every tick
    /// (VoiceOver is told once, not every second), or nil when no wait is shown.
    public static func steadySpoken(
        _ kind: FailureKind, retryAt: WaitDeadline?, timeScale: UInt64, now: ContinuousClock.Instant = .now
    ) -> String? {
        waits(kind, retryAt, now: now) == nil ? nil : kind.message(timeScale: timeScale)
    }

    /// What VoiceOver speaks instead of ``message(_:retryAt:timeScale:now:)``, or nil when it is the same text.
    public static func spoken(_ kind: FailureKind, retryAt: WaitDeadline?, now: ContinuousClock.Instant = .now) -> String? {
        waits(kind, retryAt, now: now).map { RecoveryStrings.recoverRateLimitedWait(spokenDuration($0)) }
    }
}

/// A failure's notice that counts its wait down: the text is made again each second from the end of the wait, and VoiceOver
/// is told the failure once (not every second).
public struct WaitNotice: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    private let kind: FailureKind
    private let title: String
    private let retryAt: WaitDeadline?
    private let notice: NoticeKind

    public init(_ kind: FailureKind, title: String, retryAt: WaitDeadline?, notice: NoticeKind = .urgent) {
        self.kind = kind
        self.title = title
        self.retryAt = retryAt
        self.notice = notice
    }

    public var body: some View {
        if WaitText.seconds(until: retryAt) != nil, kind == .rateLimited || kind == .backoff {
            TimelineView(.periodic(from: .now, by: 1)) { _ in card(at: .now) }
        } else {
            card(at: .now)
        }
    }

    private func card(at now: ContinuousClock.Instant) -> some View {
        NoticeCard(
            notice, title: title, message: WaitText.message(kind, retryAt: retryAt, timeScale: timeScale, now: now),
            announce: .assertive, announcement: "\(title). \(kind.message(timeScale: timeScale))",
            spokenMessage: WaitText.spoken(kind, retryAt: retryAt, now: now)
        )
    }
}

/// Builds [content] again each second while [wait] runs, with whether it still runs, so that a screen can hold its send back
/// for the whole wait and release it when the wait ends (VAULT-MESSAGING §10.1: the app does not resend before it ends).
public struct WaitingContent<Content: View>: View {
    private let wait: WaitDeadline?
    private let content: (Bool) -> Content

    public init(until wait: WaitDeadline?, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.wait = wait
        self.content = content
    }

    /// One `TimelineView` always, so that the content keeps its identity (a scanner's camera is not torn down when the wait ends):
    /// it ticks each second while the wait runs and not at all otherwise.
    public var body: some View {
        let schedule: AnyTimelineSchedule = wait?.isRunning() == true
            ? AnyTimelineSchedule(PeriodicTimelineSchedule(from: .now, by: 1)) : AnyTimelineSchedule(ExplicitTimelineSchedule([Date]()))
        TimelineView(schedule) { _ in content(wait?.isRunning() == true) }
    }
}
#endif
