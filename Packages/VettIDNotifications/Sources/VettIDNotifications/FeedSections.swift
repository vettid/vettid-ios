import Foundation
import VettIDData
import VettIDVault

/// A group of the list: the items of one local [day], or (day nil) Needs attention. Undated items (an `at` that does not
/// parse) are the group ``FeedSections/undated``.
public struct FeedSection: Equatable, Sendable {
    public var day: Date?
    public var items: [FeedItem]

    public init(day: Date?, items: [FeedItem]) {
        self.day = day
        self.items = items
    }
}

/// The list's grouping (ANDROID-PLAN §4 Notifications, 3), kept pure for tests: newest first by `at` (a batch keeps its
/// first ask's `at`); unread `urgent` items in Needs attention at the top; the others in day groups in local time. The
/// Archived view lists the archived items only, the main list everything else; [unreadOnly] keeps the `active` ones and
/// those read by viewing while the screen is open ([fresh]). Mirrors vettid-android `FeedSections`.
public enum FeedSections {
    /// The day of the items whose `at` does not parse ("Earlier").
    public static let undated = Date.distantPast

    public static func of(
        _ items: [FeedItem], archived: Bool, unreadOnly: Bool, calendar: Calendar = .current, fresh: Set<String> = []
    ) -> [FeedSection] {
        let shown = items.filter { i in
            if archived { return i.status == FeedManager.statusArchived }
            return i.status != FeedManager.statusArchived
                && (!unreadOnly || i.status == FeedManager.statusActive || fresh.contains(i.itemID))
        }
        .map { ($0, FeedManager.at($0)) }
        .sorted { a, b in
            let (x, y) = (a.1 ?? .distantPast, b.1 ?? .distantPast)
            return x != y ? x > y : a.0.itemID > b.0.itemID
        }
        let urgent = archived ? [] : shown.filter { $0.0.status == FeedManager.statusActive && FeedKinds.urgent($0.0) }
        let urgentIDs = Set(urgent.map(\.0.itemID))
        var days: [FeedSection] = []
        for (item, at) in shown where !urgentIDs.contains(item.itemID) {
            let day = at.map { calendar.startOfDay(for: $0) } ?? undated
            if days.last?.day == day { days[days.count - 1].items.append(item) } else { days.append(FeedSection(day: day, items: [item])) }
        }
        return (urgent.isEmpty ? [] : [FeedSection(day: nil, items: urgent.map(\.0))]) + days
    }

    /// An older day group's title: "Mon 5 Oct", with the year when it is not [today]'s.
    public static func dayTitle(_ day: Date, today: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        f.dateFormat = sameYear ? "EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: day)
    }
}
