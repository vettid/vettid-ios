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
    /// A connection's page; nil until it is in the iPhone app (IOS-PLAN §8 I2.1).
    public var onOpenConnection: (@MainActor (String) -> Void)?

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
        a.onOpenConnection = host.onOpenConnection
        guard let m = model else { return a }
        a.onInput = { m.setInput($0) }
        a.onAccept = { m.accept() }
        a.onApprove = { m.approve() }
        a.onDecline = { m.decline() }
        return a
    }
}
#endif
