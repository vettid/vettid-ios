#if os(iOS)
import SwiftUI
import VettIDData
import VettIDNotifications
import VettIDUI
import VettIDVault

/// Dates and times as the Notifications screen shows them, in the iPhone's zone and locale (vettid-android `Times`).
enum FeedTimes {
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// Needs attention ([day] nil), Today, Yesterday, Earlier (undated), then the date ("Mon 5 Oct").
    static func header(_ day: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let day else { return NotificationsStrings.needsAttention }
        let today = calendar.startOfDay(for: now)
        if day == FeedSections.undated { return NotificationsStrings.undated }
        if day == today { return NotificationsStrings.today }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { return NotificationsStrings.yesterday }
        return FeedSections.dayTitle(day, today: today, calendar: calendar)
    }
}

/// The list: a header per group, then its rows, each with its swipe actions (end: archive, or in Archived delete; start:
/// read and unread, or in Archived move back).
struct FeedList: View {
    @Environment(\.vettIDColors) private var colors
    let state: NotificationsState
    let sections: [FeedSection]
    let actions: NotificationsActions

    var body: some View {
        List {
            ForEach(sections, id: \.day) { s in
                Section {
                    ForEach(s.items, id: \.itemID) { item in
                        FeedRow(item: item, names: state.names, archived: state.archived, attention: s.day == nil,
                                unread: state.showsUnread(item), actions: actions)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(FeedTimes.header(s.day))
                        .vettIDFont(.titleSmall)
                        .foregroundStyle(s.day == nil ? colors.error : colors.onSurfaceVariant)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Color.clear.frame(height: 96).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("notifications_list")
    }
}

/// One item (ANDROID-PLAN §4 Notifications, 3): the connection's tile, or the kind's icon in its History category
/// colour; the title and a second line; the time and a gold dot while unread. Unread `urgent` items sit in Needs
/// attention on a red ground with a leading bar; `high` has an amber tile and says "Important"; `low` is quieter.
struct FeedRow: View {
    @Environment(\.vettIDColors) private var colors
    let item: FeedItem
    let names: FeedNames
    let archived: Bool
    let attention: Bool
    let unread: Bool
    let actions: NotificationsActions

    var body: some View {
        let red = CategoryColors.of(.red, dark: colors.isDark)
        HStack(spacing: Spacing.l) {
            FeedTile(item: item, names: names)
            texts(red)
            meta(red)
        }
        .padding(.leading, Spacing.gutter)
        .padding(.trailing, Spacing.l)
        .frame(minHeight: 72)
        .background(attention ? red.container : colors.background)
        .overlay(alignment: .leading) { if attention { colors.error.color.frame(width: 4) } }
        .contentShape(Rectangle())
        .onTapGesture { actions.onOpen(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Self.stateText(item, unread: unread))
        .accessibilityAction { actions.onOpen(item) }
        .modifier(RowActions(item: item, archived: archived, unread: unread, actions: actions))
        .accessibilityIdentifier("feed_row_\(item.itemID)")
    }

    private func texts(_ red: TagColor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(FeedKinds.title(item, names))
                .vettIDFont(.bodyLarge, weight: unread ? .semibold : .regular)
                .foregroundStyle(attention ? red.onContainer : lineColor)
                .lineLimit(2)
            if let line = FeedKinds.supporting(item, names) {
                Text(line).vettIDFont(.bodyMedium).foregroundStyle(attention ? red.onContainer : colors.onSurfaceVariant)
                    .lineLimit(Self.lineLimit(item))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.m)
    }

    private func meta(_ red: TagColor) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if let at = FeedManager.at(item) {
                Text(FeedTimes.time(at))
                    .vettIDFont(.bodySmall, weight: unread ? .semibold : .regular)
                    .foregroundStyle(attention ? red.onContainer : lineColor)
            }
            Circle().fill(unread ? colors.primary.color : .clear).frame(width: 10, height: 10)
                .accessibilityIdentifier(unread ? "unread_dot" : "read_dot")
        }
    }

    private var lineColor: ThemeColor {
        if item.priority == "low" && !unread { return colors.onSurfaceVariant }
        return unread ? colors.onSurface : colors.onSurfaceVariant
    }

    /// The second line's lines in the list (owner decision of 2026-10-20, IOS-PLAN 0.1.14): up to 3 for an urgent item
    /// (the rollback warning, a failed recovery attempt), 1 for the others; the detail sheet shows it in full.
    static func lineLimit(_ item: FeedItem) -> Int { FeedKinds.urgent(item) ? 3 : 1 }

    /// "Unread, Important" and the like, for VoiceOver.
    static func stateText(_ item: FeedItem, unread: Bool) -> String {
        [
            unread ? NotificationsStrings.stateUnread : nil,
            item.priority == FeedManager.priorityHigh ? NotificationsStrings.stateImportant : nil,
            item.priority == FeedManager.priorityUrgent ? NotificationsStrings.stateUrgent : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Swipe actions, the long-press menu and the VoiceOver actions of a row: archive and read/unread, or in Archived move
/// back and delete.
private struct RowActions: ViewModifier {
    let item: FeedItem
    let archived: Bool
    let unread: Bool
    let actions: NotificationsActions

    private var toggle: String { unread ? NotificationsStrings.markRead : NotificationsStrings.markUnread }

    func body(content: Content) -> some View {
        if archived {
            content
                .swipeActions(edge: .trailing) { Button(NotificationsStrings.delete, role: .destructive) { actions.onAskDelete(item) } }
                .swipeActions(edge: .leading) { Button(NotificationsStrings.moveBack) { actions.onMoveBack(item) } }
                .contextMenu {
                    Button(NotificationsStrings.moveBack) { actions.onMoveBack(item) }
                    Button(NotificationsStrings.delete, role: .destructive) { actions.onAskDelete(item) }
                }
                .accessibilityAction(named: Text(NotificationsStrings.moveBack)) { actions.onMoveBack(item) }
                .accessibilityAction(named: Text(NotificationsStrings.delete)) { actions.onAskDelete(item) }
        } else {
            content
                .swipeActions(edge: .trailing) { Button(NotificationsStrings.archive) { actions.onArchive(item) } }
                .swipeActions(edge: .leading) { Button(toggle) { actions.onToggleRead(item) } }
                .contextMenu {
                    Button(NotificationsStrings.archive) { actions.onArchive(item) }
                    Button(toggle) { actions.onToggleRead(item) }
                }
                .accessibilityAction(named: Text(NotificationsStrings.archive)) { actions.onArchive(item) }
                .accessibilityAction(named: Text(toggle)) { actions.onToggleRead(item) }
        }
    }
}

/// The connection's tile where the item names one; else the kind's icon in its History category colour (red when
/// urgent, amber when important).
struct FeedTile: View {
    @Environment(\.vettIDColors) private var colors
    let item: FeedItem
    let names: FeedNames

    var body: some View {
        if let c = item.connectionID.flatMap({ names.connections[$0] }) {
            InitialTile(c.displayName.isEmpty ? c.name : c.displayName, style: c.favorite ? .favorite : .connection,
                        photo: ProfilePhotos.decode(c.photo))
        } else {
            InitialTile("", icon: FeedIcons.icon(item.kind), colors: CategoryColors.of(FeedIcons.hue(item), dark: colors.isDark))
        }
    }
}

/// The kinds' icons and colours: History's categories (``FeedCategories``). Mirrors vettid-android `FeedIcons`.
enum FeedIcons {
    static func hue(_ item: FeedItem) -> CategoryHue { // swiftlint:disable:this cyclomatic_complexity
        if item.priority == FeedManager.priorityUrgent { return .red }
        if item.priority == FeedManager.priorityHigh { return .amber }
        switch FeedCategories.of(item.kind) {
        case .vaultAccess: return .green
        case .security: return .amber
        case .devices: return .purple
        case .connections: return .teal
        case .messages: return .blue
        case .items: return .gold
        case .agents: return .orange
        case .location: return .indigo
        case .account, .other: return .grey
        case .dropped: return .red
        }
    }

    static func icon(_ kind: String) -> VettIDSymbol { // swiftlint:disable:this cyclomatic_complexity
        switch FeedCategories.of(kind) {
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
}
#endif
