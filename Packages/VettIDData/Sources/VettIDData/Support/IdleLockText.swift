import Foundation

/// How the idle lock's time is said (ANDROID-PLAN §4 "Locking the vault" part 2; approved by the owner 2026-10-24): as
/// ``DurationText`` says a duration, but one whole day is "1 day", as the setting names it. Mirrors vettid-android
/// `FeedNotifier.durationText` and the unlock screen's day rule.
public enum IdleLockText {
    public static let secondsPerDay: Int64 = 86_400

    /// [seconds] in words: "1 hour", "1 day", "7 days", "150 seconds".
    public static func duration(_ seconds: Int64) -> String {
        seconds == secondsPerDay ? DataStrings.durationDays(1) : DurationText.of(TimeInterval(seconds))
    }
}
