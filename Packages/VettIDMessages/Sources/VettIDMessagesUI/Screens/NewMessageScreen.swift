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

    public init(
        state: NewMessageState,
        onBack: @escaping @MainActor () -> Void,
        onPick: @escaping @MainActor (String) -> Void,
        onInvite: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onBack = onBack
        self.onPick = onPick
        self.onInvite = onInvite
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

    @ViewBuilder private var content: some View {
        if state.loading && state.connections.isEmpty {
            ProgressView().tint(colors.primary.color)
        } else if state.connections.isEmpty {
            VStack(spacing: 0) {
                EmptyState(icon: .personAdd, title: MessagesStrings.newEmptyTitle, message: MessagesStrings.emptyNoConnections)
                Button(action: onInvite) {
                    Text(MessagesStrings.invite).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
                }
                .buttonStyle(.plain)
                .frame(minHeight: Spacing.touchTarget)
                .padding(Spacing.xl)
                .accessibilityIdentifier("new_message_invite")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.connections) { c in
                        let name = ConversationItem.name(c)
                        VettIDListRow(
                            title: name,
                            supporting: AccountNames.isolateOrNull(c.secondaryName),
                            tileName: ConversationItem.tileName(c),
                            tileStyle: c.favorite ? .favorite : .connection,
                            tilePhoto: ProfilePhotos.decode(c.photo),
                            onTap: { onPick(c.id) }
                        )
                        .accessibilityIdentifier("pick_\(c.id)")
                    }
                }
            }
        }
    }
}
#endif
