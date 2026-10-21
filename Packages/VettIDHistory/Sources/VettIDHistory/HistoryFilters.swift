import Foundation
import VettIDData

/// The date presets of the History filter (ANDROID-PLAN §4 History); ``custom`` is a range the member picked. Mirrors
/// vettid-android `DatePreset`.
public enum DatePreset: CaseIterable, Sendable {
    case any, today, week, month, custom

    /// The days the preset covers, today included; nil for none or a picked range.
    public var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .any, .custom: nil
        }
    }
}

/// A connection the History filter offers.
public struct ConnectionOption: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Builds the filter of the History screen from the member's choices (kept pure for tests). Mirrors vettid-android
/// `HistoryFilters`.
public enum HistoryFilters {
    /// One category at a time: choosing the selected one again (or nil) is "All".
    public static func category(_ f: AuditFilter, _ c: AuditCategory?) -> AuditFilter {
        var n = f
        n.category = c == f.category ? nil : c
        return n
    }

    /// The range of [preset] in [calendar]'s time zone: `since` the start of the first day (today, 7 or 30 days
    /// including today), no `until`; ``DatePreset/any`` clears it; ``DatePreset/custom`` takes [since] and [until].
    public static func dates(
        _ f: AuditFilter, _ preset: DatePreset, now: Date, calendar: Calendar, since: Date? = nil, until: Date? = nil
    ) -> AuditFilter {
        var n = f
        switch preset {
        case .any:
            n.since = nil
            n.until = nil
        case .custom:
            n.since = since
            n.until = until
        case .today, .week, .month:
            let today = calendar.startOfDay(for: now)
            n.since = calendar.date(byAdding: .day, value: -((preset.days ?? 1) - 1), to: today)
            n.until = nil
        }
        return n
    }

    /// A custom range of whole local days: from the start of [first] to the start of the day after [last] (picked
    /// backwards, the same range).
    public static func days(_ first: Date, _ last: Date, calendar: Calendar) -> (since: Date, until: Date) {
        let a = calendar.startOfDay(for: min(first, last))
        let b = calendar.startOfDay(for: max(first, last))
        return (a, calendar.date(byAdding: .day, value: 1, to: b) ?? b)
    }
}
