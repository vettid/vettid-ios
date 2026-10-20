#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the Connections screen can ask for. Mirrors vettid-android `ConnectionsActions`, with the connection requests'
/// decisions (the iPhone lists them here until its Approvals screen, IOS-PLAN §8 I2.3; chosen; not in the spec).
public struct ConnectionsActions {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onFavorite: @MainActor (String, Bool) -> Void = { _, _ in }
    /// The add button's sheet chose a screen of the connect flow.
    public var onConnect: @MainActor (ConnectDestination) -> Void = { _ in }
    public var onCancelInvite: @MainActor (OutstandingInvite?) -> Void = { _ in }
    public var onConfirmCancel: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    public var onDismissPeerDecline: @MainActor (String) -> Void = { _ in }
    public var onQuery: @MainActor (String) -> Void = { _ in }
    public var onApprove: @MainActor (PendingConnection) -> Void = { _ in }
    public var onDecline: @MainActor (PendingConnection) -> Void = { _ in }
    public var onDismissEnded: @MainActor () -> Void = {}

    public init() {}
}

/// Connections (ANDROID-PLAN §4, Proton's contacts): initial tiles (teal for favourites), state, a star per row; the
/// other member's declines and the open connection requests first, then the outstanding invitations; the top bar's
/// search by name; the add button offers invite (QR or link), scan, or paste. Mirrors vettid-android `ConnectionsScreen`.
public struct ConnectionsScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: ConnectionsState
    let chrome: ShellChrome
    let actions: ConnectionsActions
    @State private var searchOpen = false

    public init(state: ConnectionsState, chrome: ShellChrome, actions: ConnectionsActions) {
        self.state = state
        self.chrome = chrome
        self.actions = actions
    }

    private var search: TopBarSearchState {
        TopBarSearchState(
            query: Binding(get: { state.query }, set: { actions.onQuery($0) }),
            opened: $searchOpen,
            label: ConnectStrings.searchOpen,
            placeholder: ConnectStrings.search
        )
    }

    public var body: some View {
        TopLevelScaffold(title: ConnectStrings.title, chrome: chrome, search: state.searchable ? search : nil) {
            content
        } overlay: {
            AddConnectionControls(onOpen: actions.onConnect)
        }
        .confirmDialog(
            isPresented: Binding(get: { state.cancelling != nil }, set: { if !$0 { actions.onCancelInvite(nil) } }),
            title: ConnectStrings.cancelInviteTitle,
            message: ConnectStrings.cancelInviteBody,
            confirmLabel: ConnectStrings.cancelInviteConfirm,
            destructive: true,
            onConfirm: actions.onConfirmCancel
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections_screen")
    }

    @ViewBuilder private var content: some View {
        if state.loading && state.connections.isEmpty {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("connections_loading")
        } else if let error = state.error, state.isEmpty {
            ConnectionsError(kind: error, actionLabel: ConnectStrings.retry, action: actions.onRetry)
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.searching && state.connections.isEmpty {
            EmptyState(icon: .search, title: ConnectStrings.noMatchTitle, message: ConnectStrings.noMatchBody)
                .accessibilityIdentifier("connections_no_match")
        } else if state.isEmpty {
            EmptyState(icon: .connections, title: ConnectStrings.emptyTitle, message: ConnectStrings.emptyBody)
                .accessibilityIdentifier("connections_empty")
        } else {
            ConnectionList(state: state, actions: actions)
        }
    }
}

/// The list itself: a failure notice, then (unless searching) the declines, the requests and the invitations, then the
/// connections.
struct ConnectionList: View {
    let state: ConnectionsState
    let actions: ConnectionsActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.error {
                    ConnectionsError(kind: error, actionLabel: ConnectStrings.ok, action: actions.onDismissError)
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                if !state.searching { pending }
                ForEach(state.connections) { c in ConnectionItem(connection: c, actions: actions) }
            }
            .padding(.bottom, 96)
        }
        .accessibilityIdentifier("connections")
    }

    @ViewBuilder private var pending: some View {
        if let ended = state.ended {
            EndedRequestNotice(ended: ended, onDismiss: actions.onDismissEnded)
                .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
        }
        ForEach(state.peerDeclines, id: \.requestID) { d in
            NoticeCard(.info, title: PeerDeclineText.title(outgoing: d.outgoing, name: d.name), message: ConnectStrings.peerDeclinedBody) {
                ListNoticeAction(label: ConnectStrings.ok, identifier: "peer_declined_ok") { actions.onDismissPeerDecline(d.requestID) }
            }
            .accessibilityIdentifier("peer_declined_\(d.requestID)")
            .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
        }
        ForEach(state.requests, id: \.key) { r in
            RequestCard(request: r, deciding: state.deciding.contains(r.id), actions: actions)
                .padding(.vertical, Spacing.s)
        }
        if !state.invites.isEmpty {
            SectionHeader(text: ConnectStrings.invitesHeader)
            ForEach(state.invites, id: \.inviteID) { i in InviteRow(invite: i) { actions.onCancelInvite(i) } }
            SectionHeader(text: ConnectStrings.header)
        }
    }
}

/// A connection's row: its title (or "Name not shared yet"), its state and display name, when it was last active.
struct ConnectionItem: View {
    let connection: ConnectionInfo
    let actions: ConnectionsActions

    var body: some View {
        let c = connection
        ConnectionRow(
            name: c.displayName.isEmpty ? ConnectStrings.nameNotShared : c.displayName,
            favorite: c.favorite,
            supporting: Self.supporting(c),
            meta: c.lastActiveAt.map { ConnectTimes.short($0) },
            photo: ProfilePhotos.decode(c.photo),
            onFavoriteChange: { actions.onFavorite(c.id, $0) },
            onTap: { actions.onOpen(c.id) }
        )
        .accessibilityIdentifier("connection_\(c.id)")
    }

    /// The state (unless active) and the display name, joined; "Connected" when neither has anything to say.
    static func supporting(_ c: ConnectionInfo) -> String {
        let parts = [ConnectStrings.stateLabel(c.state), c.secondaryName].compactMap { $0 }
        return parts.isEmpty ? ConnectStrings.stateActive : parts.joined(separator: " · ")
    }
}
#endif
