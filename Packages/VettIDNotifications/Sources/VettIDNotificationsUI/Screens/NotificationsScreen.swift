#if os(iOS)
import SwiftUI
import VettIDData
import VettIDNotifications
import VettIDUI
import VettIDVault

/// What the Notifications screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `NotificationsActions`.
public struct NotificationsActions {
    public var onBack: @MainActor () -> Void = {}
    public var onOpen: @MainActor (FeedItem) -> Void = { _ in }
    public var onArchive: @MainActor (FeedItem) -> Void = { _ in }
    public var onToggleRead: @MainActor (FeedItem) -> Void = { _ in }
    public var onMoveBack: @MainActor (FeedItem) -> Void = { _ in }
    public var onAskDelete: @MainActor (FeedItem?) -> Void = { _ in }
    public var onDelete: @MainActor () -> Void = {}
    public var onUndo: @MainActor () -> Void = {}
    public var onUndoShown: @MainActor () -> Void = {}
    public var onMarkAllRead: @MainActor () -> Void = {}
    public var onArchived: @MainActor () -> Void = {}
    public var onUnreadOnly: @MainActor (Bool) -> Void = { _ in }
    public var onCloseSheet: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onErrorShown: @MainActor () -> Void = {}

    public init() {}
}

/// Notifications (ANDROID-PLAN §4 Notifications, 3): Needs attention, then the day groups; unread rows bold with a gold
/// dot; swipe to archive (Undo) or to mark read and unread, each also a VoiceOver action and in the long-press menu; the
/// Unread chip; ⋯ → Mark all as read, Archived. The Archived view moves items back or deletes them (confirmed). Mirrors
/// vettid-android `NotificationsScreen`.
public struct NotificationsScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: NotificationsState
    let actions: NotificationsActions
    /// The short message at the bottom (Android's snackbar): the archive's Undo, or a failure.
    @State private var toast: Toast?

    public init(state: NotificationsState, actions: NotificationsActions) {
        self.state = state
        self.actions = actions
    }

    struct Toast: Equatable {
        var text: String
        var undo: Bool
    }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            VStack(spacing: 0) {
                LargeTitle(state.archived ? NotificationsStrings.archivedTitle : NotificationsStrings.title)
                    .padding(.horizontal, Spacing.gutter)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } overlay: {
            VStack(spacing: Spacing.s) {
                if let toast { ToastView(toast: toast, onUndo: { undo() }) }
                if !state.archived { filter }
            }
        } actions: {
            if !state.archived { MoreMenu(state: state, actions: actions) }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.confirmDelete != nil }, set: { if !$0 { actions.onAskDelete(nil) } }),
            title: NotificationsStrings.deleteTitle,
            message: deleteMessage,
            confirmLabel: NotificationsStrings.delete,
            destructive: true,
            onConfirm: actions.onDelete
        )
        .sheet(isPresented: Binding(get: { state.sheet != nil }, set: { if !$0 { actions.onCloseSheet() } })) {
            if let item = state.sheet {
                FeedDetailSheet(item: item, names: state.names, gone: state.sheetGone)
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: state.undo) { _, undo in if undo != nil { show(Toast(text: NotificationsStrings.archivedSnackbar, undo: true)) } }
        .onChange(of: state.error) { _, error in
            guard let error else { return }
            actions.onErrorShown()
            show(Toast(text: error.message, undo: false))
        }
        .accessibilityIdentifier(state.archived ? "notifications_archived_screen" : "notifications_screen")
    }

    /// "Delete this notification on all your devices?", and for a batch that later requests start a new one.
    var deleteMessage: String { Self.deleteMessage(state.confirmDelete, names: state.names) }

    static func deleteMessage(_ item: FeedItem?, names: FeedNames) -> String {
        guard let item else { return NotificationsStrings.deleteBody }
        guard (item.count ?? 0) > 1 || item.kind == "grant.request" else { return NotificationsStrings.deleteBody }
        return NotificationsStrings.deleteBody + "\n\n" + NotificationsStrings.deleteBatch(FeedKinds.firstName(item, names))
    }

    private func show(_ t: Toast) {
        toast = t
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard toast == t else { return }
            toast = nil
            if t.undo { actions.onUndoShown() }
        }
    }

    private func undo() {
        toast = nil
        actions.onUndo()
    }

    private var filter: some View {
        BottomFloatingControls {
            HStack(spacing: Spacing.s) {
                FloatingFilterChip(
                    NotificationsStrings.filterUnread,
                    selected: Binding(get: { state.unreadOnly }, set: { actions.onUnreadOnly($0) })
                )
                if state.unreadOnly { ClearFiltersChip { actions.onUnreadOnly(false) } }
            }
        } trailing: {
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        let sections = state.sections()
        if state.items.isEmpty && (state.load == .loading || state.load == .notLoaded) {
            ProgressView().tint(colors.primary.color).accessibilityIdentifier("notifications_loading")
        } else if state.items.isEmpty && state.load == .failed {
            LoadFailed(onRetry: actions.onRetry)
        } else if sections.isEmpty {
            Self.empty(state)
        } else {
            FeedList(state: state, sections: sections, actions: actions)
        }
    }

    /// Archived, Unread or the main list's empty state.
    @ViewBuilder static func empty(_ state: NotificationsState) -> some View {
        if state.archived {
            EmptyState(icon: .archive, title: NotificationsStrings.emptyArchivedTitle, message: NotificationsStrings.emptyArchivedBody)
                .accessibilityIdentifier("notifications_empty_archived")
        } else if state.unreadOnly {
            EmptyState(icon: .doneAll, title: NotificationsStrings.emptyUnreadTitle, message: NotificationsStrings.emptyUnreadBody)
                .accessibilityIdentifier("notifications_empty_unread")
        } else {
            EmptyState(icon: .notifications, title: NotificationsStrings.emptyTitle, message: NotificationsStrings.emptyBody)
                .accessibilityIdentifier("notifications_empty")
        }
    }
}

/// ⋯: Mark all as read (while something is unread), Archived.
private struct MoreMenu: View {
    let state: NotificationsState
    let actions: NotificationsActions

    var body: some View {
        Menu {
            Button(action: actions.onMarkAllRead) { Label { Text(NotificationsStrings.markAllRead) } icon: { VettIDSymbol.doneAll.image } }
                .disabled(state.unread == 0 || state.markingAll)
            Button(action: actions.onArchived) { Label { Text(NotificationsStrings.archivedTitle) } icon: { VettIDSymbol.archive.image } }
        } label: {
            VettIDSymbol.moreHoriz.image.frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
        }
        .accessibilityLabel(NotificationsStrings.more)
        .accessibilityIdentifier("notifications_more")
    }
}

private struct LoadFailed: View {
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: Spacing.l) {
            Text(NotificationsStrings.loadFailed).vettIDFont(.bodyLarge).multilineTextAlignment(.center)
            PrimaryButton(NotificationsStrings.retry, action: onRetry).accessibilityIdentifier("notifications_retry")
        }
        .padding(Spacing.xl)
        .accessibilityIdentifier("notifications_load_failed")
    }
}

/// The bottom message: its text and, after an archive, Undo.
private struct ToastView: View {
    @Environment(\.vettIDColors) private var colors
    let toast: NotificationsScreen.Toast
    let onUndo: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(toast.text).vettIDFont(.bodyMedium).foregroundStyle(colors.inverseOnSurface)
            Spacer(minLength: 0)
            if toast.undo {
                Button(NotificationsStrings.undo, action: onUndo).foregroundStyle(colors.inversePrimary)
                    .accessibilityIdentifier("notifications_undo")
            }
        }
        .padding(Spacing.l)
        .background(colors.inverseSurface, in: RoundedRectangle(cornerRadius: VettIDShape.small, style: .continuous))
        .padding(.horizontal, Spacing.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications_toast")
    }
}
#endif
