import Foundation
import VettIDCrypto

/// The app's own waits that the staging time scale divides (STAGING-TIME-SCALE §2.1, §5.2; IOS-PLAN §6.6; ANDROID-PLAN
/// §4 "Staging time scale"), in real time, and the waits of the vault the screens name. Each app-side timer divides its
/// wait by the vault's time scale (``LocalAccount/timeScale``) when it starts and keeps the absolute time it got, so that
/// a timer started before the app knew the scale keeps its time. Rate limits, retries and the durations the member
/// chooses are never scaled (§2.2).
public enum TimeScales {
    /// S2: the owner check's early warning, from 1 h before the deadline (VAULT-MESSAGING §3.6.5).
    public static let ownerCheckWarning: TimeInterval = 3_600
    /// S8: the recovery counter unavailable at every read for 24 h is shown as urgent (§11.14.5; STAGING-TIME-SCALE
    /// 0.1.1; IOS-PLAN 0.1.7 §6.6): ``RecoveryUnknownClock``, which keeps the period with the clock's start.
    public static let recoveryUnknownDay: TimeInterval = 86_400
    /// S9: replaced phone-secret records are deleted 7 days after the confirmation (§11.14.1 rule 6; IOS-PLAN §6.3).
    public static let replacedRecordsKeepMs: Int64 = 7 * 86_400_000
    /// S10: the old phone keeps its keys for at most 7 days after approving a transfer (§11.14.10). The transfer comes
    /// with I3, which starts this timer with ``scaled(_:by:)``.
    public static let oldPhoneKeep: TimeInterval = 7 * 86_400
    /// S12: no contact with the vault service for 7 days offers erase-or-recover (``StuckScreens``).
    public static let longUnreachableMs: Int64 = 7 * 86_400_000
    /// S16: the release update banner stays dismissed for at most 24 h (``ReleaseNotices``).
    public static let updateBannerDismiss: TimeInterval = 86_400
    /// S5: the vault's recovery code delay (§11.11.2, §11.14.5), as the screens name it.
    public static let recoveryDelay: TimeInterval = 86_400
    /// S7: the vault's recovery quiet period (§11.14.5), as the presence notice names it.
    public static let recoveryQuiet: TimeInterval = 72 * 3_600

    /// [seconds] at [scale] (STAGING-TIME-SCALE §3 rule 1: divided, rounded up to a whole second).
    public static func scaled(_ seconds: TimeInterval, by scale: UInt64) -> TimeInterval { TimeScale.scaled(seconds, by: scale) }

    /// [seconds] at [scale] as the screens say it ("24 hours", "1 hour", "7 days", "3 minutes").
    public static func text(_ seconds: TimeInterval, by scale: UInt64) -> String {
        DurationText.of(TimeScale.scaled(seconds, by: scale))
    }

    /// [seconds] at [scale] as the screens say it, for a text whose approved words name the wait in real time ("three
    /// days", "within the hour"): nil in real time, where the screen shows those words verbatim, and the computed duration
    /// only on a scaled vault (the owner's decision of 2026-10-19; each such text has a `_scaled` key).
    public static func scaledText(_ seconds: TimeInterval, by scale: UInt64) -> String? {
        scale > TimeScale.real ? text(seconds, by: scale) : nil
    }

    /// A setting in its real units with its scaled value beside it on a scaled vault: "24 hours (staging: 1 hour)"
    /// (STAGING-TIME-SCALE §3 rule 3); just "24 hours" in real time.
    public static func setting(_ seconds: TimeInterval, by scale: UInt64) -> String {
        withStaging(DurationText.of(seconds), seconds, by: scale)
    }

    /// [realText] (a setting's text in real units, "Every 24 hours") with [seconds] at [scale] beside it on a scaled vault:
    /// "Every 24 hours (staging: 1 hour)"; [realText] alone in real time.
    public static func withStaging(_ realText: String, _ seconds: TimeInterval, by scale: UInt64) -> String {
        guard scale > TimeScale.real else { return realText }
        return DataStrings.timeScaleSetting(realText, DurationText.of(TimeScale.scaled(seconds, by: scale)))
    }

    /// The small note shown where a scaled wait is shown on a staging vault: "Staging: 1 day = 1 hour"; nil in real time
    /// and at any scale the text does not describe (the dev stack's; chosen; not in the spec).
    public static func stagingNote(_ scale: UInt64) -> String? {
        scale == TimeScale.staging ? DataStrings.timeScaleStaging : nil
    }
}

/// A duration as the screens say it (chosen; not in the spec): whole days from 2 days ("7 days", "3 days"), whole hours
/// ("24 hours", "1 hour"), minutes rounded up from 10 minutes ("90 minutes"), seconds below ("150 seconds", not a
/// rounded "3 minutes").
public enum DurationText {
    public static func of(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds.rounded(.up), 0))
        if s >= 2 * 86_400, s.isMultiple(of: 86_400) { return DataStrings.durationDays(s / 86_400) }
        if s >= 3_600, s.isMultiple(of: 3_600) { return DataStrings.durationHours(s / 3_600) }
        if s >= 600 { return DataStrings.durationMinutes((s + 59) / 60) }
        return DataStrings.durationSeconds(s)
    }
}

/// The vault's time scale for the code that runs off the main actor (the phone-secret records): set from the account
/// record each time it is read or changed.
final class TimeScaleCell: @unchecked Sendable {
    private let lock = NSLock()
    private var scale = TimeScale.real

    var value: UInt64 { lock.withLock { scale } }

    func set(_ s: UInt64) { lock.withLock { scale = max(s, TimeScale.real) } }
}
