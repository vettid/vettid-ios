import Foundation

/// A release's time scale (VAULT-MESSAGING 0.43.0 §11.10.8, §11.10.9; STAGING-TIME-SCALE §5.2): the release constant by
/// which the vault, and the app for its own waits, divide the waits of 1 hour or more that STAGING-TIME-SCALE §2.1 lists,
/// each when its timer starts. It is carried in the attested ETK descriptor (§11.2) and in a transfer's bundle (§6.4),
/// and `vault.status` returns it. A missing member is a release before the scale: 1. Production is exactly 1; staging 1
/// or 24; a development build 1 to 86,400. Which of these a build accepts is the build's choice (VettIDAltChan's
/// `TimeScalePolicy`); this parse refuses only what no release can carry.
public enum TimeScale {
    public static let member = "time_scale"
    /// Real time: production, and every release before the scale.
    public static let real: UInt64 = 1
    /// Staging's value from release 18 (STAGING-TIME-SCALE §6 T2): a day becomes an hour.
    public static let staging: UInt64 = 24
    /// The development build's largest value (the dev stack's `-time-scale`).
    public static let maxDevelopment: UInt64 = 86_400

    /// `time_scale` of [o]: 1 when absent; a value outside 1 to 86,400 is malformed.
    public static func parse(_ o: JsonObject) throws -> UInt64 {
        try o.optUint(member, min: real, max: maxDevelopment) ?? real
    }

    /// Writes `time_scale` (tests and tooling).
    @discardableResult
    public static func write(_ b: JsonBuilder, _ scale: UInt64) -> JsonBuilder { b.uint(member, scale) }

    /// [seconds] divided by [scale], rounded up to a whole second (STAGING-TIME-SCALE §3 rule 1). A scale of 0 is taken as
    /// 1 (never parsed; a guard for callers' defaults).
    public static func scaled(_ seconds: TimeInterval, by scale: UInt64) -> TimeInterval {
        guard scale > 1 else { return seconds }
        return (seconds / Double(scale)).rounded(.up)
    }

    /// [ms] (a whole number of seconds or more, in milliseconds) divided by [scale], rounded up to a whole second.
    public static func scaledMs(_ ms: Int64, by scale: UInt64) -> Int64 {
        guard scale > 1 else { return ms }
        return Int64(scaled(Double(ms) / 1000, by: scale) * 1000)
    }
}
