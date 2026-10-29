#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// What the Messages screen can ask for. Mirrors vettid-android `MessagesScreen`'s callbacks.
public struct MessagesActions {
    public var onUnreadOnly: @MainActor (Bool) -> Void = { _ in }
    public var onQuery: @MainActor (String) -> Void = { _ in }
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onCompose: @MainActor () -> Void = {}
    public var onInvite: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}

    public init() {}
}

/// Messages (ANDROID-PLAN §4, Proton's inbox): one row per connection with its latest message, newest first, unread ones
/// emphasized with their count; the Unread chip and the compose button float at the bottom (the button invites while
/// there is no active connection); the top bar's search once there is a conversation. Mirrors vettid-android
/// `MessagesScreen`.
public struct MessagesScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: MessagesState
    let chrome: ShellChrome
    let actions: MessagesActions
    @State private var searchOpen = false

    public init(state: MessagesState, chrome: ShellChrome, actions: MessagesActions) {
        self.state = state
        self.chrome = chrome
        self.actions = actions
    }

    private var search: TopBarSearchState {
        TopBarSearchState(
            query: Binding(get: { state.query }, set: { actions.onQuery($0) }),
            opened: $searchOpen,
            label: MessagesStrings.searchOpen,
            placeholder: MessagesStrings.search
        )
    }

    public var body: some View {
        TopLevelScaffold(title: MessagesStrings.title, chrome: chrome, search: state.searchable ? search : nil) {
            content
        } overlay: {
            BottomFloatingControls {
                FloatingFilterChip(
                    MessagesStrings.filter, selected: Binding(get: { state.unreadOnly }, set: { actions.onUnreadOnly($0) })
                )
                .accessibilityIdentifier("messages_unread")
            } trailing: {
                VettIDFab(
                    state.noConnections ? .personAdd : .edit,
                    label: state.noConnections ? MessagesStrings.invite : MessagesStrings.add,
                    action: state.noConnections ? actions.onInvite : actions.onCompose
                )
                .accessibilityIdentifier("messages_compose")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages_screen")
    }

    @ViewBuilder private var content: some View {
        if state.loading && state.conversations.isEmpty {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("messages_loading")
        } else if let error = state.error, state.conversations.isEmpty {
            MessagesError(kind: error, actionLabel: MessagesStrings.retry, action: actions.onRetry)
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.conversations.isEmpty && state.searching {
            EmptyState(icon: .search, title: MessagesStrings.noMatchTitle, message: MessagesStrings.noMatchBody)
                .accessibilityIdentifier("messages_no_match")
        } else if state.conversations.isEmpty {
            EmptyState(icon: .messages, title: Self.emptyTitle(state), message: Self.emptyBody(state))
                .accessibilityIdentifier("messages_empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.conversations) { c in
                        ConversationItem(summary: c) { actions.onOpen(c.connection.id) }
                    }
                }
                .padding(.bottom, 96)
            }
            .accessibilityIdentifier("conversations")
        }
    }

    static func emptyTitle(_ s: MessagesState) -> String { s.unreadOnly ? MessagesStrings.emptyUnreadTitle : MessagesStrings.emptyTitle }

    static func emptyBody(_ s: MessagesState) -> String {
        if s.unreadOnly { return MessagesStrings.emptyUnreadBody }
        return s.noConnections ? MessagesStrings.emptyNoConnections : MessagesStrings.emptyBody
    }
}

/// A conversation's row: the connection's name (or "Name not shared yet"), its latest message's first line ("You: …"
/// for the member's own), the unread count, the latest message's date.
struct ConversationItem: View {
    let summary: ConversationSummary
    let onTap: @MainActor () -> Void

    var body: some View {
        let c = summary.connection
        let name = Self.name(c)
        VettIDListRow(
            title: name,
            supporting: Self.supporting(summary),
            meta: summary.last.map { MessageTimes.short($0.sentAt) },
            tileName: Self.tileName(c),
            tileStyle: c.favorite ? .favorite : .connection,
            emphasized: summary.unread > 0,
            tilePhoto: ProfilePhotos.decode(c.photo),
            onTap: onTap
        )
        .accessibilityIdentifier("conversation_\(c.id)")
    }

    /// The connection's name, cleaned and bidi-isolated (VAULT-MESSAGING §10.8; mirrors vettid-android #220).
    static func name(_ c: ConnectionInfo) -> String { AccountNames.isolateOrNull(c.displayName) ?? MessagesStrings.nameNotShared }

    /// The name for the avatar's initial: cleaned, not isolated.
    static func tileName(_ c: ConnectionInfo) -> String { AccountNames.cleaned(c.displayName) ?? MessagesStrings.nameNotShared }

    /// The latest message's first line that shows something, cleaned and isolated (VAULT-MESSAGING 0.76.0 §10.8 step 6), with
    /// the unread count before it when there is any. A photo with nothing to show says "Photo"; any other text with nothing
    /// to show leaves out the line and its "You: " label (step 4), the unread count standing alone.
    static func supporting(_ s: ConversationSummary) -> String {
        guard let last = s.last else { return s.unread > 0 ? MessagesStrings.rowUnreadBare(s.unread) : MessagesStrings.previewNone }
        let line = previewLine(last.text, outgoing: last.outgoing, hasPhoto: last.attachment != nil)
        if s.unread > 0 { return line.isEmpty ? MessagesStrings.rowUnreadBare(s.unread) : MessagesStrings.rowUnread(s.unread, line) }
        return line
    }

    /// A conversation row's preview line: "" when nothing shows.
    static func previewLine(_ text: String, outgoing: Bool, hasPhoto: Bool) -> String {
        guard let line = AccountNames.firstLineIsolated(text) ?? (hasPhoto ? MessagesStrings.previewPhoto : nil) else { return "" }
        return outgoing ? MessagesStrings.previewYou(line) : line
    }
}

/// A failure of the messages: "Could not load messages", why, and the action ("Try again", "OK").
struct MessagesError: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    let kind: FailureKind
    let actionLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: MessagesStrings.errorTitle, message: kind.message(timeScale: timeScale)) {
            Button(action: action) {
                Text(actionLabel).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: Spacing.touchTarget)
            .accessibilityIdentifier("messages_error_action")
        }
        .accessibilityIdentifier("messages_error")
    }
}

/// Dates and times as the messages show them, in the phone's zone and locale (vettid-android `Times`).
enum MessageTimes {
    /// A list row's date (Proton): the time today, the weekday this week, else the date.
    static func short(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return d.formatted(date: .omitted, time: .shortened) }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo, day <= today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// The time of day (a message's meta line).
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// A day separator's label.
    static func dayLabel(_ day: Date) -> String { day.formatted(date: .abbreviated, time: .omitted) }
}
#endif
