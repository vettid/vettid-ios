#if os(iOS)
import SwiftUI
import VettIDData
import VettIDNotifications
import VettIDUI
import VettIDVault

/// The detail sheet (ANDROID-PLAN §4 Notifications, 4): the title and the full second line, the exact time, the connection or item as History
/// resolves them; "This is no longer waiting." for an ask that is gone; "Not available in this version of the app." for
/// kinds that come later; an unknown kind shows the kind itself; a guide its body. Mirrors vettid-android `DetailSheet`.
struct FeedDetailSheet: View {
    @Environment(\.vettIDColors) private var colors
    let item: FeedItem
    let names: FeedNames
    let gone: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(FeedKinds.title(item, names)).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                // The second line in full, under the title, for every kind that has one (owner decision of 2026-10-20,
                // IOS-PLAN 0.1.14): the rollback warning and the other long lines a row cuts short. A guide shows its whole
                // body below instead of its first line.
                if let line = Self.secondLine(item, names) {
                    Text(line).vettIDFont(.bodyLarge).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("feed_sheet_line")
                }
                ForEach(Self.lines(item, names), id: \.label) { l in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(l.label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
                        Text(l.value).vettIDFont(.bodyLarge)
                    }
                    .padding(.vertical, Spacing.xs)
                    .accessibilityElement(children: .combine)
                }
                if item.kind == "guide", let body = item.body, !body.isEmpty {
                    Text(body).vettIDFont(.bodyLarge).padding(.top, Spacing.s)
                }
                if let note = Self.note(item, gone: gone) {
                    Text(note).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant).padding(.top, Spacing.m)
                        .accessibilityIdentifier("feed_sheet_note")
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.surface)
        .accessibilityIdentifier("feed_sheet")
    }

    struct Line: Equatable {
        var label: String
        var value: String
    }

    /// When, the connection, the item (or "Deleted item" for a revealed one that is gone), and an unknown kind itself.
    static func lines(_ item: FeedItem, _ names: FeedNames) -> [Line] {
        var out: [Line] = []
        if let at = FeedManager.at(item) { out.append(Line(label: NotificationsStrings.sheetTime, value: FeedTimes.full(at))) }
        if item.connectionID != nil {
            out.append(Line(label: NotificationsStrings.sheetConnection, value: FeedKinds.connectionName(item, names)))
        }
        if let thing = FeedKinds.itemName(item, names) {
            out.append(Line(label: NotificationsStrings.sheetItem, value: thing))
        } else if item.kind == "item.revealed" {
            out.append(Line(label: NotificationsStrings.sheetItem, value: FeedKinds.deletedItem))
        }
        if !FeedKinds.isKnown(item.kind) { out.append(Line(label: NotificationsStrings.sheetKind, value: item.kind)) }
        return out
    }

    static func secondLine(_ item: FeedItem, _ names: FeedNames) -> String? {
        item.kind == "guide" ? nil : FeedKinds.supporting(item, names)
    }

    static func note(_ item: FeedItem, gone: Bool) -> String? {
        if FeedKinds.classify(item.kind) == .later { return NotificationsStrings.sheetNotAvailable }
        if gone && FeedKinds.isAsk(item.kind) { return NotificationsStrings.sheetNoLongerWaiting }
        if gone { return NotificationsStrings.sheetGone }
        if !FeedKinds.isKnown(item.kind) { return NotificationsStrings.sheetUnknown }
        return nil
    }
}
#endif
