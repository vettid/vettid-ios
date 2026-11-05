#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// The compose button's picker (vettid-android `NewMessageScreen`): the active connections, favourites first; with none,
/// the suggestion to invite someone.
public struct NewMessageScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: NewMessageState
    let onBack: @MainActor () -> Void
    let onPick: @MainActor (String) -> Void
    let onInvite: @MainActor () -> Void
    let onRetry: @MainActor () -> Void

    public init(
        state: NewMessageState,
        onBack: @escaping @MainActor () -> Void,
        onPick: @escaping @MainActor (String) -> Void,
        onInvite: @escaping @MainActor () -> Void,
        onRetry: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.onBack = onBack
        self.onPick = onPick
        self.onInvite = onInvite
        self.onRetry = onRetry
    }

    /// What the picker shows: connections that could not be read are never "No connections yet" with "Invite".
    static func phase(_ state: NewMessageState) -> ListPhase {
        ListPhase.of(loading: state.loading, empty: state.connections.isEmpty, failed: state.error != nil)
    }

    public var body: some View {
        DetailScaffold(onBack: onBack) {
            VStack(spacing: 0) {
                CenteredTitle(MessagesStrings.newTitle)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("new_message_screen")
    }

    /// The connections could not be read: why, with "Try again".
    private func failure(_ error: FailureKind) -> some View {
        MessagesError(kind: error, actionLabel: MessagesStrings.retry, title: MessagesStrings.newErrorTitle, action: onRetry)
            .accessibilityIdentifier("new_message_error")
    }

    @ViewBuilder private var content: some View {
        let phase = Self.phase(state)
        if phase == .loading {
            ProgressView().tint(colors.primary.color)
        } else if phase == .failed, let error = state.error {
            ScrollView { failure(error).padding(Spacing.xl) }
        } else if phase == .empty {
            VStack(spacing: 0) {
                EmptyState(icon: .personAdd, title: MessagesStrings.newEmptyTitle, message: MessagesStrings.emptyNoConnections)
                Button(action: onInvite) {
                    Text(MessagesStrings.invite).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
                        .textButtonTarget()
                }
                .buttonStyle(.plain)
                .padding(Spacing.xl)
                .accessibilityIdentifier("new_message_invite")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if phase.failedAbove(failed: state.error != nil), let error = state.error {
                        failure(error).padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                    }
                    ForEach(state.connections) { c in
                        let name = ConversationItem.name(c)
                        ProfilePhotoLoading(c.photo) { photo in
                            VettIDListRow(
                                title: name,
                                supporting: AccountNames.isolateOrNull(c.secondaryName),
                                tileName: ConversationItem.tileName(c),
                                tileStyle: c.favorite ? .favorite : .connection,
                                tilePhoto: photo,
                                onTap: { onPick(c.id) }
                            )
                        }
                        .accessibilityIdentifier("pick_\(c.id)")
                    }
                }
            }
        }
    }
}
#endif
