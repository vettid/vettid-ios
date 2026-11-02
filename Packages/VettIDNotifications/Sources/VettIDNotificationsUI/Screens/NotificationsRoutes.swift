#if os(iOS)
import SwiftUI
import VettIDData
import VettIDNotifications
import VettIDUI
import VettIDVault

/// What the Notifications screens need from the app shell: back, the Archived view, and the screen an item opens
/// (``FeedTarget``). Mirrors vettid-android `NotificationsHost`.
public struct NotificationsHost {
    public var onBack: @MainActor () -> Void = {}
    public var onOpenArchived: @MainActor () -> Void = {}
    public var onOpen: @MainActor (FeedTarget) -> Void = { _ in }

    public init() {}
}

/// The Notifications screen (or, with [archived], its Archived view) with its view model, made when it first appears and
/// released when it goes. Viewing marks read while the screen is in view and the app active; the dots of what was read
/// by viewing stay until the member leaves. Mirrors vettid-android `notificationsDestination`.
public struct NotificationsRoute: View {
    private let feed: any FeedRepository
    private let connections: (any ConnectionsRepository)?
    private let approvals: (any ApprovalsRepository)?
    private let items: (any ItemsRepository)?
    private let votes: (any VotesRepository)?
    private let archived: Bool
    private let host: NotificationsHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: NotificationsViewModel?

    public init(
        feed: any FeedRepository, connections: (any ConnectionsRepository)? = nil, approvals: (any ApprovalsRepository)? = nil,
        items: (any ItemsRepository)? = nil, votes: (any VotesRepository)? = nil, archived: Bool = false,
        host: NotificationsHost
    ) {
        self.feed = feed
        self.connections = connections
        self.approvals = approvals
        self.items = items
        self.votes = votes
        self.archived = archived
        self.host = host
    }

    public var body: some View {
        NotificationsScreen(state: model?.state ?? NotificationsState(archived: archived), actions: actions)
            .onAppear {
                if model == nil {
                    model = NotificationsViewModel(
                        feed: feed, connections: connections, approvals: approvals, items: items, votes: votes, archived: archived
                    )
                }
                if scenePhase == .active { model?.shown() }
            }
            .onDisappear { model?.left() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model?.shown() } else { model?.paused() }
            }
            .onChange(of: model?.state.open) { _, target in
                guard let target else { return }
                model?.targetTaken()
                host.onOpen(target)
            }
    }

    private var actions: NotificationsActions {
        var a = NotificationsActions()
        a.onBack = host.onBack
        a.onArchived = host.onOpenArchived
        guard let m = model else { return a }
        a.onOpen = { m.open($0) }
        a.onArchive = { m.archive($0) }
        a.onToggleRead = { m.toggleRead($0) }
        a.onMoveBack = { m.moveToNotifications($0) }
        a.onAskDelete = { m.askDelete($0) }
        a.onDelete = { m.delete() }
        a.onUndo = { m.undoArchive() }
        a.onUndoShown = { m.undoShown() }
        a.onMarkAllRead = { m.markAllRead() }
        a.onUnreadOnly = { m.setUnreadOnly($0) }
        a.onCloseSheet = { m.closeSheet() }
        a.onRetry = { m.refresh() }
        a.onErrorShown = { m.errorShown() }
        return a
    }
}

/// The bell of the drawer screens' top bar (ANDROID-PLAN §4 Notifications): the feed's unread count, red while an urgent
/// item is unread; nil (no bell) while the vault is held or the daily check is due, when nothing of the feed is shown
/// (VAULT-MESSAGING §3.6.3).
public enum NotificationsBell {
    @MainActor
    public static func of(
        _ feed: (any FeedRepository)?, held: Bool, onTap: @escaping @MainActor @Sendable () -> Void
    ) -> NotificationBell? {
        guard let feed, !held else { return nil }
        return NotificationBell(unread: feed.badge.unread, urgent: feed.badge.urgent, onTap: onTap)
    }
}
#endif
