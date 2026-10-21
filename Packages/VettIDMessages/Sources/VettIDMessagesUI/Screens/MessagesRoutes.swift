#if os(iOS)
import SwiftUI
import VettIDData
import VettIDMessages
import VettIDUI

/// What the Messages screens need from the app shell. Mirrors vettid-android `MessagesHost`.
public struct MessagesHost {
    public var onBack: @MainActor () -> Void = {}
    /// A conversation with a connection (from a row or the picker).
    public var onOpenConversation: @MainActor (String) -> Void = { _ in }
    /// The compose button's picker.
    public var onCompose: @MainActor () -> Void = {}
    /// The connection's page (the connections feature).
    public var onOpenConnection: @MainActor (String) -> Void = { _ in }
    /// Invite a connection (the connections feature).
    public var onInvite: @MainActor () -> Void = {}
    /// A confirmed link that is a VettID invitation: the accept screen (the connections feature), where the member
    /// confirms before anything is sent.
    public var onInviteLink: @MainActor (String) -> Void = { _ in }
    /// The viewer of a message's photo, by connection and message (only the ids travel).
    public var onOpenPhoto: @MainActor (String, String) -> Void = { _, _ in }

    public init() {}
}

/// The Messages screen with its view model, made when it first appears and released when it goes. Mirrors
/// vettid-android `messagesDestination`'s `MessagesRoute`.
public struct MessagesRoute: View {
    private let messages: any MessagesRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let chrome: ShellChrome
    private let host: MessagesHost
    @State private var model: MessagesViewModel?

    public init(messages: any MessagesRepository, ownerChecks: (any OwnerCheckRepository)? = nil, chrome: ShellChrome, host: MessagesHost) {
        self.messages = messages
        self.ownerChecks = ownerChecks
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        MessagesScreen(state: model?.state ?? MessagesState(), chrome: chrome, actions: actions)
            .onAppear { if model == nil { model = MessagesViewModel(messages: messages, ownerChecks: ownerChecks) } }
    }

    private var actions: MessagesActions {
        var a = MessagesActions()
        a.onOpen = host.onOpenConversation
        a.onCompose = host.onCompose
        a.onInvite = host.onInvite
        guard let m = model else { return a }
        a.onUnreadOnly = { m.setUnreadOnly($0) }
        a.onQuery = { m.setQuery($0) }
        a.onRetry = { m.refresh() }
        return a
    }
}

/// A conversation with its view model; the draft lives as long as the screen is on the stack. A confirmed link is handed
/// to the system's `openURL` only after the view model checked it once more against the link rule. Mirrors
/// vettid-android `messagesDestination`'s `ConversationRoute`.
public struct ConversationRoute: View {
    private let connectionID: String
    private let messages: any MessagesRepository
    private let connections: any ConnectionsRepository
    private let attachments: (any AttachmentsRepository)?
    private let host: MessagesHost
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ConversationViewModel?

    /// [attachments]: the photos (VAULT-MESSAGING §10.5.1); nil offers none.
    public init(
        _ connectionID: String, messages: any MessagesRepository, connections: any ConnectionsRepository,
        attachments: (any AttachmentsRepository)? = nil, host: MessagesHost
    ) {
        self.connectionID = connectionID
        self.messages = messages
        self.connections = connections
        self.attachments = attachments
        self.host = host
    }

    public var body: some View {
        ConversationScreen(state: model?.state ?? ConversationState(connectionID: connectionID), actions: actions)
            .onAppear {
                let m = model ?? ConversationViewModel(
                    connectionID: connectionID, messages: messages, connections: connections, attachments: attachments
                )
                model = m
                m.setForeground(scenePhase == .active)
                m.setShown(true)
            }
            // Covered by a screen pushed over it, or closed: nothing more is marked read until it shows again.
            .onDisappear { model?.setShown(false) }
            .onChange(of: scenePhase) { _, phase in model?.setForeground(phase == .active) }
    }

    private var actions: ConversationActions {
        var a = ConversationActions()
        let (id, host, openURL) = (connectionID, host, openURL)
        a.onBack = host.onBack
        a.onDetails = { host.onOpenConnection(id) }
        guard let m = model else { return a }
        a.onDraft = { m.setDraft($0) }
        a.onSend = { m.send() }
        a.onAskDelete = { m.askDelete($0) }
        a.onConfirmDelete = { m.confirmDelete() }
        a.onDismissError = { m.dismissError() }
        a.onLoadOlder = { m.loadOlder() }
        a.onLink = { m.askOpen($0) }
        a.onConfirmLink = { LinkOpening.perform(m.confirmLink(), open: { openURL($0) }, invite: host.onInviteLink) }
        a.onDismissLink = { m.dismissLink() }
        a.photos = Self.photoActions(m, id, host)
        return a
    }

    private static func photoActions(_ m: ConversationViewModel, _ id: String, _ host: MessagesHost) -> PhotoActions {
        var p = PhotoActions()
        p.onTakePhoto = { m.startCapture() }
        p.onPicked = { m.onPicked($0) }
        p.onShot = { m.onShot($0) }
        p.onCloseCamera = { m.stopCapture() }
        p.onCaption = { m.setPhotoCaption($0) }
        p.onSend = { m.sendPhotos() }
        p.onCancel = { m.cancelPhotos() }
        p.onDismissProblem = { m.dismissPhotoProblem() }
        p.onOpen = { host.onOpenPhoto(id, $0) }
        p.thumbnail = { await m.thumbnail($0) }
        return p
    }
}

/// The photo viewer of one message with its view model (only the ids travel; the photo stays in memory). Mirrors
/// vettid-android `messagesDestination`'s `PhotoViewerRoute`.
public struct PhotoViewerRoute: View {
    private let connectionID: String
    private let messageID: String
    private let attachments: any AttachmentsRepository
    private let messages: any MessagesRepository
    private let host: MessagesHost
    @State private var model: PhotoViewerViewModel?

    public init(
        connectionID: String, messageID: String, attachments: any AttachmentsRepository, messages: any MessagesRepository,
        host: MessagesHost
    ) {
        self.connectionID = connectionID
        self.messageID = messageID
        self.attachments = attachments
        self.messages = messages
        self.host = host
    }

    public var body: some View {
        PhotoViewerScreen(state: model?.state ?? PhotoViewerState(), onBack: host.onBack, onRetry: { model?.load() })
            .onAppear {
                if model == nil {
                    model = PhotoViewerViewModel(
                        connectionID: connectionID, messageID: messageID, attachments: attachments, messages: messages
                    )
                }
            }
    }
}

/// The confirmed link's last step: VettID's own invitation to the accept screen, any other link to the system.
enum LinkOpening {
    @MainActor
    static func perform(_ target: LinkTarget?, open: @MainActor (URL) -> Void, invite: @MainActor (String) -> Void) {
        switch target {
        case .open(let url): open(url)
        case .invite(let link): invite(link)
        case nil: break
        }
    }
}

/// The new-message picker with its view model. Mirrors vettid-android `messagesDestination`'s `NewMessageRoute`.
public struct NewMessageRoute: View {
    private let connections: any ConnectionsRepository
    private let host: MessagesHost
    @State private var model: NewMessageViewModel?

    public init(connections: any ConnectionsRepository, host: MessagesHost) {
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        NewMessageScreen(
            state: model?.state ?? NewMessageState(),
            onBack: host.onBack,
            onPick: host.onOpenConversation,
            onInvite: host.onInvite
        )
        .onAppear { if model == nil { model = NewMessageViewModel(connections: connections) } }
    }
}
#endif
