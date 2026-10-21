#if os(iOS)
import SwiftUI
import VettIDData
import VettIDHistory
import VettIDUI

/// The colour and icon of each group (owner request 2026-10-09; IOS-PLAN §3: SF Symbols in place of Material Icons):
/// unlocks green, security amber, blocked and dropped red, connections teal, messages blue, the vault gold, devices
/// purple, agents orange, location indigo, account (and a kind this app does not know) grey. The same on the entry's
/// tile, its screen and the filter chips. Mirrors vettid-android `categoryHue` and `categoryIcon`.
enum HistoryVisuals {
    static func hue(_ c: AuditCategory) -> CategoryHue {
        switch c {
        case .vaultAccess: .green
        case .security: .amber
        case .devices: .purple
        case .connections: .teal
        case .messages: .blue
        case .items: .gold
        case .agents: .orange
        case .location: .indigo
        case .account, .other: .grey
        case .dropped: .red
        }
    }

    static func symbol(_ c: AuditCategory) -> VettIDSymbol { // swiftlint:disable:this cyclomatic_complexity
        switch c {
        case .vaultAccess: .lockOpen
        case .security: .shield
        case .devices: .devices
        case .connections: .connections
        case .messages: .messages
        case .items: .vault
        case .agents: .agent
        case .location: .location
        case .account: .accountCircle
        case .dropped: .block
        case .other: .eventNote
        }
    }

    static func colors(_ c: AuditCategory, _ scheme: ColorScheme) -> TagColor { CategoryColors.of(hue(c), dark: scheme == .dark) }
}

/// An entry's time as History shows it (vettid-android `Times`): the time today, the weekday within the week, else the
/// date; the full date and time on the entry's screen; a day for the date range.
enum HistoryTimes {
    static func short(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return d.formatted(date: .omitted, time: .shortened) }
        if let week = calendar.date(byAdding: .day, value: -6, to: today), day >= week, day < today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }

    /// "1 Oct 2026 – 8 Oct 2026": a custom range's first and last day (the day before `until`).
    static func range(since: Date, until: Date?, now: Date = Date()) -> String {
        HistoryStrings.dateRange(day(since), day((until ?? now).addingTimeInterval(-0.001)))
    }
}
#endif
