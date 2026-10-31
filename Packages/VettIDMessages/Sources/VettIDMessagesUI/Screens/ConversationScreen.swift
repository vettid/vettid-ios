#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// What the conversation screen can ask for. Mirrors vettid-android `ConversationActions`, with the link question's
/// answers.
public struct ConversationActions {
    public var onBack: @MainActor () -> Void = {}
    public var onDraft: @MainActor (String) -> Void = { _ in }
    public var onSend: @MainActor () -> Void = {}
    /// Asks to delete a message (nil: never mind).
    public var onAskDelete: @MainActor (MessageInfo?) -> Void = { _ in }
    public var onConfirmDelete: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    /// The connection's page.
    public var onDetails: @MainActor () -> Void = {}
    /// The list reached its top while older messages remain (VAULT-MESSAGING §10.5.2).
    public var onLoadOlder: @MainActor () -> Void = {}
    /// A link tapped in a bubble.
    public var onLink: @MainActor (URL) -> Void = { _ in }
    /// "Open": the route hands the re-checked URL to the system, or an invitation to the accept screen.
    public var onConfirmLink: @MainActor () -> Void = {}
    public var onDismissLink: @MainActor () -> Void = {}
    /// The photos (VAULT-MESSAGING §10.5.1): the button, the camera, the draft, the bubbles and the viewer.
    public var photos = PhotoActions()

    public init() {}
}

/// A conversation (ANDROID-PLAN §4): the connection's name, the bubbles by day with their delivery state, older messages
/// on reaching the top, a failure notice, and the reply field at the bottom (a sentence instead while the connection is
/// not active). A long press on a bubble offers the delete, confirmed first; a link asks "Open link to <host>?" first.
/// Photos: the composer's photo button, the camera and the prepared photos over the conversation, the photo bubbles.
/// Mirrors vettid-android `ConversationScreen`.
public struct ConversationScreen: View {
    let state: ConversationState
    let actions: ConversationActions

    public init(state: ConversationState, actions: ConversationActions) {
        self.state = state
        self.actions = actions
    }

    /// The connection's name, cleaned and bidi-isolated (VAULT-MESSAGING §10.8; mirrors vettid-android #220): the title and
    /// every sentence take it as it is.
    var name: String { AccountNames.isolateOrNull(state.connection?.displayName) ?? MessagesStrings.nameNotShared }

    var isolated: String { name }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            VStack(spacing: 0) {
                CenteredTitle(name)
                ConversationBody(state: state, name: isolated, actions: actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .announcesArrivals(state, name: isolated, covered: photoCover)
                if let error = state.error {
                    MessagesError(kind: error, actionLabel: MessagesStrings.ok, action: actions.onDismissError)
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                        .accessibilityIdentifier("conversation_error")
                }
                Composer(state: state, name: isolated, actions: actions)
            }
        } actions: {
            IconButton(.info, label: MessagesStrings.details(isolated), action: actions.onDetails)
                .accessibilityIdentifier("conversation_details")
        }
        .confirmDialog(
            isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { actions.onAskDelete(nil) } }),
            title: MessagesStrings.deleteTitle,
            message: MessagesStrings.deleteBody(isolated),
            confirmLabel: MessagesStrings.deleteConfirm,
            destructive: true,
            onConfirm: actions.onConfirmDelete
        )
        .confirmDialog(
            isPresented: Binding(get: { state.link != nil }, set: { if !$0 { actions.onDismissLink() } }),
            title: MessagesStrings.openLink(state.link?.host ?? ""),
            message: state.link?.shownURL ?? "",
            confirmLabel: MessagesStrings.openLinkConfirm,
            onConfirm: actions.onConfirmLink
        )
        .fullScreenCover(isPresented: Binding(get: { photoCover }, set: { if !$0 { closePhotoCover() } })) {
            if state.capturing {
                PhotoCaptureOverlay(actions: actions.photos)
            } else if let draft = state.photoDraft {
                PhotoDraftOverlay(draft: draft, name: isolated, actions: actions.photos)
            }
        }
        .accessibilityIdentifier("conversation_screen")
    }

    /// The camera, or the prepared photos waiting for Send or Cancel.
    var photoCover: Bool { state.capturing || state.photoDraft != nil }

    private func closePhotoCover() {
        if state.capturing {
            actions.photos.onCloseCamera()
        } else if state.photoDraft?.inFlight == false {
            actions.photos.onCancel()
        }
    }
}

/// Loading, "Say hello", or the messages.
struct ConversationBody: View {
    @Environment(\.vettIDColors) private var colors
    let state: ConversationState
    let name: String
    let actions: ConversationActions

    var body: some View {
        if state.loading && state.messages.isEmpty {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("conversation_loading")
        } else if state.messages.isEmpty {
            EmptyState(icon: .messages, title: MessagesStrings.conversationEmptyTitle, message: MessagesStrings.conversationEmptyBody(name))
                .accessibilityIdentifier("conversation_empty")
        } else {
            MessageList(state: state, name: name, actions: actions)
        }
    }
}

/// The reply field and Send; for a connection that is not active, why nothing can be sent.
struct Composer: View {
    @Environment(\.vettIDColors) private var colors
    let state: ConversationState
    let name: String
    let actions: ConversationActions

    var body: some View {
        if state.connection != nil && !state.active {
            Text(MessagesStrings.inactive(name))
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(Spacing.l)
                .accessibilityIdentifier("conversation_inactive")
        } else {
            HStack(alignment: .center, spacing: Spacing.s) {
                if state.photosAvailable { PhotoButton(enabled: state.photoDraft == nil, actions: actions.photos) }
                field
                sendButton
            }
            .padding(.leading, state.photosAvailable ? Spacing.xs : Spacing.gutter)
            .padding(.trailing, Spacing.s)
            .padding(.vertical, Spacing.s)
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField(
                "", text: Binding(get: { state.draft }, set: { actions.onDraft($0) }),
                prompt: Text(MessagesStrings.replyHint(name)), axis: .vertical
            )
            .lineLimit(1...5)
            .textInputAutocapitalization(.sentences)
            .vettIDFont(.bodyLarge)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(minHeight: Spacing.touchTarget)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(state.tooLong ? colors.error : colors.outline))
            .accessibilityLabel(MessagesStrings.replyHint(name))
            .accessibilityIdentifier("composer")
            if state.tooLong {
                Text(MessagesStrings.tooLong).vettIDFont(.bodySmall).foregroundStyle(colors.error)
                    .accessibilityIdentifier("composer_too_long")
            }
        }
    }

    private var sendButton: some View {
        Button(action: actions.onSend) {
            ZStack {
                if state.sending {
                    ProgressView().tint(colors.onPrimaryContainer.color)
                } else {
                    VettIDSymbol.send.image.font(.system(size: 20))
                }
            }
            .foregroundStyle(colors.onPrimaryContainer)
            .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
            .background(colors.primaryContainer, in: Circle())
            .opacity(state.canSend || state.sending ? 1 : 0.38)
        }
        .buttonStyle(.plain)
        .disabled(!state.canSend)
        .accessibilityLabel(MessagesStrings.send)
        .accessibilityIdentifier("send")
    }
}
#endif
