import Foundation

/// A form's time (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): Unix seconds from 0 to 253,402,300,799, shown as
/// date and time in the member's time zone with the zone named, and in UTC, with seconds whenever they are not zero.
public enum DocumentTime {
    /// [seconds] in [zone] (the member's) and in UTC, each with its zone named, for [locale].
    public static func shown(_ seconds: Int64, zone: TimeZone = .current, locale: Locale = .current) -> (local: String, utc: String) {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let withSeconds = seconds % 60 != 0
        let utc = TimeZone(identifier: "UTC") ?? zone
        // The UTC line names its zone "UTC" (a formatter would say "GMT").
        return (format(date, zone, locale, withSeconds), format(date, utc, locale, withSeconds, zoneName: false) + " UTC")
    }

    private static func format(_ date: Date, _ zone: TimeZone, _ locale: Locale, _ withSeconds: Bool, zoneName: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.calendar = Calendar(identifier: .gregorian)
        // The year always in full: a time can be any year to 9999.
        f.setLocalizedDateFormatFromTemplate((withSeconds ? "yyyyMMMdjmmss" : "yyyyMMMdjmm") + (zoneName ? "z" : ""))
        return f.string(from: date)
    }
}
