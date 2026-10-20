#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// What the connect flow needs from the app shell. Mirrors vettid-android `ConnectionsHost`'s part for these screens.
public struct ConnectHost {
    public var onBack: @MainActor () -> Void = {}
    /// Replaces the current screen (the scanner with the accept screen, and back).
    public var replace: @MainActor (ConnectDestination) -> Void = { _ in }
    /// The conversation with a connection; nil until the messages are in the iPhone app (IOS-PLAN §8 I2.2).
    public var onOpenConversation: (@MainActor (String) -> Void)?
    /// A connection's page, over the current screen (from the list).
    public var onOpenConnection: (@MainActor (String) -> Void)?
    /// A connection's page in place of the current screen (the accept screen's "Open the connection", as vettid-android's
    /// `host.replace`); nil: [onOpenConnection].
    public var replaceWithConnection: (@MainActor (String) -> Void)?
    /// Opens a screen of the connect flow (the list's add button).
    public var push: @MainActor (ConnectDestination) -> Void = { _ in }

    public init() {}
}

/// One screen of the connect flow with its view model, made when it first appears and released (its work cancelled)
/// when the screen goes. Mirrors vettid-android's `connectionsDestination` for these routes.
public struct ConnectRoute: View {
    private let destination: ConnectDestination
    private let connections: any ConnectionsRepository
    private let requests: any ConnectionRequestsRepository
    private let host: ConnectHost

    public init(
        _ destination: ConnectDestination,
        connections: any ConnectionsRepository,
        requests: any ConnectionRequestsRepository,
        host: ConnectHost
    ) {
        self.destination = destination
        self.connections = connections
        self.requests = requests
        self.host = host
    }

    public var body: some View {
        switch destination {
        case .invite:
            InviteRoute(connections: connections, requests: requests, host: host)
        case .scan:
            ScanRoute(host: host)
        case .accept(let input):
            AcceptRoute(input: input, connections: connections, requests: requests, host: host)
        }
    }
}

struct InviteRoute: View {
    let connections: any ConnectionsRepository
    let requests: any ConnectionRequestsRepository
    let host: ConnectHost
    @State private var model: InviteViewModel?

    var body: some View {
        InviteScreen(state: model?.state ?? InviteState(), actions: actions)
            .onAppear { if model == nil { model = InviteViewModel(connections: connections, requests: requests) } }
    }

    private var actions: InviteActions {
        var a = InviteActions()
        a.onBack = host.onBack
        a.onMessage = host.onOpenConversation
        guard let m = model else { return a }
        a.onTtl = { m.setTtl($0) }
        a.onCreate = { m.create() }
        a.onTick = { m.tick() }
        a.onApprove = { m.approve() }
        a.onDecline = { m.decline() }
        a.onAskBlock = { m.askBlock($0) }
        a.onBlock = { m.block() }
        a.onCancelInvite = { m.cancelInvite() }
        a.onAgain = { m.again() }
        return a
    }
}

struct ScanRoute: View {
    let host: ConnectHost
    @State private var model = ScanViewModel()

    var body: some View {
        ScanScreen(
            state: model.state,
            onBack: host.onBack,
            onScanned: { model.onScanned($0) },
            onPaste: { host.replace(.accept(AcceptInput())) },
            onLink: { link in
                model.consumed()
                host.replace(.accept(AcceptInput(link: link)))
            }
        )
    }
}

struct AcceptRoute: View {
    let input: AcceptInput
    let connections: any ConnectionsRepository
    let requests: any ConnectionRequestsRepository
    let host: ConnectHost
    @State private var model: AcceptViewModel?

    var body: some View {
        AcceptScreen(state: model?.state ?? AcceptState(input: input.link ?? "", fromLink: input.opened), actions: actions)
            .onAppear {
                guard model == nil else { return }
                model = AcceptViewModel(connections: connections, requests: requests, input: input.link, opened: input.opened)
            }
    }

    private var actions: AcceptActions {
        var a = AcceptActions()
        a.onBack = host.onBack
        a.onScan = { host.replace(.scan) }
        a.onMessage = host.onOpenConversation
        a.onOpenConnection = host.replaceWithConnection ?? host.onOpenConnection
        guard let m = model else { return a }
        a.onInput = { m.setInput($0) }
        a.onAccept = { m.accept() }
        a.onApprove = { m.approve() }
        a.onDecline = { m.decline() }
        return a
    }
}

/// The Connections screen with its view model, made when it first appears and released when it goes. Mirrors
/// vettid-android `connectionsDestination`'s `ConnectionsRoute`.
public struct ConnectionsRoute: View {
    private let connections: any ConnectionsRepository
    private let requests: any ConnectionRequestsRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let account: (any AccountRepository)?
    private let chrome: ShellChrome
    private let host: ConnectHost
    @State private var model: ConnectionsViewModel?

    /// [ownerChecks] and [account]: ``ConnectionsViewModel``'s, for reading again after a passed check and dropping the
    /// invitations on a lock.
    public init(
        connections: any ConnectionsRepository,
        requests: any ConnectionRequestsRepository,
        ownerChecks: (any OwnerCheckRepository)? = nil,
        account: (any AccountRepository)? = nil,
        chrome: ShellChrome,
        host: ConnectHost
    ) {
        self.connections = connections
        self.requests = requests
        self.ownerChecks = ownerChecks
        self.account = account
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        ConnectionsScreen(state: model?.state ?? ConnectionsState(), chrome: chrome, actions: actions)
            .onAppear {
                guard model == nil else { return }
                model = ConnectionsViewModel(connections: connections, requests: requests, ownerChecks: ownerChecks, account: account)
            }
    }

    private var actions: ConnectionsActions {
        var a = ConnectionsActions()
        a.onOpen = { host.onOpenConnection?($0) }
        a.onConnect = host.push
        guard let m = model else { return a }
        a.onFavorite = { m.setFavorite($0, $1) }
        a.onCancelInvite = { m.askCancel($0) }
        a.onConfirmCancel = { m.confirmCancel() }
        a.onRetry = { m.refresh() }
        a.onDismissError = { m.dismissError() }
        a.onDismissPeerDecline = { m.dismissPeerDecline($0) }
        a.onQuery = { m.setQuery($0) }
        return a
    }
}

/// A connection's detail with its view model. Mirrors vettid-android `connectionsDestination`'s `ConnectionDetailRoute`.
public struct ConnectionDetailRoute: View {
    private let connectionID: String
    private let connections: any ConnectionsRepository
    private let host: ConnectHost
    @State private var model: ConnectionDetailViewModel?

    public init(_ connectionID: String, connections: any ConnectionsRepository, host: ConnectHost) {
        self.connectionID = connectionID
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        ConnectionDetailScreen(state: model?.state ?? ConnectionDetailState(connectionID: connectionID), actions: actions)
            .onAppear { if model == nil { model = ConnectionDetailViewModel(connectionID: connectionID, connections: connections) } }
    }

    private var actions: DetailActions {
        var a = DetailActions()
        a.onBack = host.onBack
        a.onMessage = opening(host.onOpenConversation, connectionID)
        guard let m = model else { return a }
        a.onFavorite = { m.toggleFavorite() }
        a.onAsk = { m.ask($0) }
        a.onConfirm = { m.confirm() }
        a.onDismissNotice = { m.dismissNotice() }
        a.onMuteAsks = { m.muteAsks($0) }
        a.onResumeAsks = { m.resumeAsks() }
        a.onRetry = { m.load() }
        return a
    }
}
#endif
