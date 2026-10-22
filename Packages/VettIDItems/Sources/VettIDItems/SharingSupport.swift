import Foundation
import VettIDData

/// A sharing screen's state that can show a vault failure: the kind, the code an unmapped refusal names (shown with it) and
/// the limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
protocol Failing {
    var error: FailureKind? { get set }
    var errorCode: String? { get set }
    var limit: VaultLimit? { get set }
}

extension Failing {
    /// Shows [e] (anything but a vault failure reads as `other`).
    mutating func fail(_ e: Error) {
        let f = e as? VaultFailure ?? VaultFailure(.other)
        error = f.kind
        errorCode = f.code
        limit = f.limit
    }
}

/// Active grants first, then by name (case-insensitive); equal ones keep their order. Mirrors vettid-android `GRANT_ORDER`.
func grantOrder(_ grants: [GrantView]) -> [GrantView] {
    grants.enumerated().sorted { a, b in
        if a.element.active != b.element.active { return a.element.active }
        let (x, y) = (a.element.name.lowercased(), b.element.name.lowercased())
        return x != y ? x < y : a.offset < b.offset
    }.map(\.element)
}

/// The connection's title for the sharing screens: its display name (the account's "First Last"), nil when blank.
@MainActor
func connectionName(_ connections: any ConnectionsRepository, _ id: String) -> String? {
    let n = connections.connections.first { $0.id == id }?.displayName ?? ""
    return n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : n
}

/// How long a rule lasts (§10.12 `expires_at`: in the future, at most 3,650 days ahead; absent, until deleted). The presets
/// count from now in the member's time zone; ``custom`` is a date and time the member picked. Mirrors vettid-android
/// `RuleExpiry`. The end is a wall-clock date sent to the vault (the staging time scale does not change it).
public enum RuleExpiry: Equatable, Sendable, CaseIterable {
    case never, day, week, month, threeMonths, year
    /// A date and time the member picked with the date and time pickers (local time, sent as UTC).
    case custom
    /// An existing rule's own end, kept as it is.
    case keep

    /// The choices offered, in order ("Custom…" after them).
    public static let presets: [RuleExpiry] = [.never, .day, .week, .month, .threeMonths, .year]

    /// The end this preset gives from [now] in [zone]; nil for ``never`` (and for ``custom`` and ``keep``, which carry their own).
    public func end(from now: Date, zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let by: (Calendar.Component, Int)
        switch self {
        case .day: by = (.day, 1)
        case .week: by = (.day, 7)
        case .month: by = (.month, 1)
        case .threeMonths: by = (.month, 3)
        case .year: by = (.year, 1)
        case .never, .custom, .keep: return nil
        }
        return cal.date(byAdding: by.0, value: by.1, to: now)
    }
}

/// The custom end of a rule (§10.12 `expires_at`): a calendar day and a time in the member's zone. Mirrors vettid-android
/// `RuleEnds`, with the day as a ``Day`` (year, month, day) where Android has the date picker's UTC midnight.
public enum RuleEnds {
    /// A calendar day, as the date picker shows it.
    public struct Day: Equatable, Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// The day [date] falls on in [zone].
        public init(_ date: Date, zone: TimeZone) {
            let c = RuleEnds.calendar(zone).dateComponents([.year, .month, .day], from: date)
            self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        }

        var ordinal: Int { year * 10_000 + month * 100 + day }
    }

    private static let daySeconds: TimeInterval = 86_400

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// The picked [day] at [hour]:[minute] in [zone], as an instant.
    public static func of(_ day: Day, hour: Int, minute: Int, zone: TimeZone) -> Date {
        let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)
        return calendar(zone).date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// Whether [at] can end a rule: in the future and at most 3,650 days ahead (§10.12).
    public static func allowed(_ at: Date, now: Date) -> Bool {
        at > now && at < now.addingTimeInterval(TimeInterval(RuleDraft.maxExpiryDays) * daySeconds)
    }

    /// Whether the date picker offers [day]: today (in [zone]) up to the last day 3,650 days ahead.
    public static func selectable(_ day: Day, now: Date, zone: TimeZone) -> Bool {
        let today = Day(now, zone: zone)
        let last = Day(now.addingTimeInterval(TimeInterval(RuleDraft.maxExpiryDays) * daySeconds), zone: zone)
        return day.ordinal >= today.ordinal && day.ordinal <= last.ordinal
    }

    /// The day the date picker shows for [at] in [zone].
    public static func pickerDay(_ at: Date, zone: TimeZone) -> Day { Day(at, zone: zone) }
}

/// The custom end being picked: the day first, then the time on it.
public enum EndPicker: Equatable, Sendable {
    case date
    case time(RuleEnds.Day)
}

/// How long until a refused fetch can succeed, as the member reads it. Mirrors vettid-android `RetryIn`.
public enum RetryIn {
    public enum Scale: Equatable, Sendable { case minutes, hours }

    public struct Amount: Equatable, Sendable {
        public var scale: Scale
        public var count: Int
    }

    /// [seconds] (at least 1) as whole minutes rounded up, or whole hours rounded up from 90 minutes.
    public static func of(_ seconds: Int64) -> Amount {
        let minutes = (max(seconds, 1) + 59) / 60
        if minutes < 90 { return Amount(scale: .minutes, count: Int(minutes)) }
        return Amount(scale: .hours, count: Int((minutes + 59) / 60))
    }
}
