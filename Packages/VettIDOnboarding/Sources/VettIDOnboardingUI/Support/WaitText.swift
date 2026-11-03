#if os(iOS)
import Foundation
import SwiftUI
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

    /// The wait as `m:ss`, and as `h:mm:ss` from an hour (not "120:00"; chosen, not in the spec).
    public static func clock(_ seconds: Int64) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60) : formatWait(seconds)
    }

    public static func message(_ kind: FailureKind, retryAt: Date?, timeScale: UInt64, now: Date = Date()) -> String {
        guard let wait = waits(kind, retryAt, now: now) else { return kind.message(timeScale: timeScale) }
        return RecoveryStrings.recoverRateLimitedWait(clock(wait))
    }

    /// What a field's error says to VoiceOver while its visible wait counts down: the failure's own text, the same at every tick
    /// (VoiceOver is told once, not every second), or nil when no wait is shown.
    public static func steadySpoken(_ kind: FailureKind, retryAt: Date?, timeScale: UInt64, now: Date = Date()) -> String? {
        waits(kind, retryAt, now: now) == nil ? nil : kind.message(timeScale: timeScale)
    }

    /// What VoiceOver speaks instead of ``message(_:retryAt:timeScale:now:)``, or nil when it is the same text.
    public static func spoken(_ kind: FailureKind, retryAt: Date?, now: Date = Date()) -> String? {
        waits(kind, retryAt, now: now).map { RecoveryStrings.recoverRateLimitedWait(spokenDuration($0)) }
    }
}

/// A failure's notice that counts its wait down: the text is made again each second from the end of the wait, and VoiceOver
/// is told the failure once (not every second).
public struct WaitNotice: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    private let kind: FailureKind
    private let title: String
    private let retryAt: Date?
    private let notice: NoticeKind

    public init(_ kind: FailureKind, title: String, retryAt: Date?, notice: NoticeKind = .urgent) {
        self.kind = kind
        self.title = title
        self.retryAt = retryAt
        self.notice = notice
    }

    public var body: some View {
        if WaitText.seconds(until: retryAt) != nil, kind == .rateLimited || kind == .backoff {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                card(at: context.date)
            }
        } else {
            card(at: Date())
        }
    }

    private func card(at now: Date) -> some View {
        NoticeCard(
            notice, title: title, message: WaitText.message(kind, retryAt: retryAt, timeScale: timeScale, now: now),
            announce: .assertive, announcement: "\(title). \(kind.message(timeScale: timeScale))",
            spokenMessage: WaitText.spoken(kind, retryAt: retryAt, now: now)
        )
    }
}
#endif
