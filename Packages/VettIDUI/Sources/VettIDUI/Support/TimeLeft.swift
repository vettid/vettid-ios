import Foundation
import SwiftUI

/// A duration as VoiceOver should say it, "4 minutes, 59 seconds": a countdown's `4:59` is read as a time of day.
public func spokenDuration(_ seconds: Int64) -> String {
    let s = max(seconds, 0)
    let f = DateComponentsFormatter()
    f.unitsStyle = .full
    f.allowedUnits = s >= 86_400 ? [.day, .hour, .minute, .second] : s >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
    f.zeroFormattingBehavior = .dropAll
    if s == 0 {
        f.allowedUnits = [.second]
        f.zeroFormattingBehavior = .default
    }
    return f.string(from: TimeInterval(s)) ?? ""
}

/// When a timed window warns that it is running out: at 2 minutes and at 30 seconds (as IOS-PLAN §4.12 asks of the
/// approvals indicator).
public let timeLeftWarnings: [Int64] = [120, 30]

public extension View {
    /// A timed window's line: VoiceOver reads [spoken] (its time in words, ``spokenDuration(_:)``) instead of the clock
    /// text, never re-reads it at each tick, and is told [spoken] when [secondsLeft] crosses one of [warnings].
    func timeLeft(_ secondsLeft: Int64, spoken: String, warnings: [Int64] = timeLeftWarnings) -> some View {
        accessibilityLabel(spoken)
            .onChange(of: secondsLeft) { old, now in
                if warnings.contains(where: { old > $0 && now <= $0 }) { Announcer.announce(spoken) }
            }
    }
}
