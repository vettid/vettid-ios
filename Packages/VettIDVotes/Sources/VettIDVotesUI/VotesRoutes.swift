#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI
import VettIDVotes

/// Where the Votes screens go: a vote's screen (by the pair, never the proposal id alone, 0.81.2), a service connection's
/// page ("Open the connection" of "Connect again to vote"), and back. Mirrors the navigation of vettid-android
/// `votesDestination`.
public struct VotesHost {
    public var onOpen: @MainActor (VoteKey) -> Void = { _ in }
    public var onOpenConnection: @MainActor (String) -> Void = { _ in }
    public var onBack: @MainActor () -> Void = {}

    public init() {}
}

/// The Votes list with its view model (the drawer's Votes). Read when the screen opens and on every return to it.
public struct VotesRoute: View {
    private let votes: any VotesRepository
    private let connections: any ConnectionsRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let chrome: ShellChrome
    private let host: VotesHost
    @State private var model: VotesViewModel?

    public init(
        votes: any VotesRepository, connections: any ConnectionsRepository, ownerChecks: (any OwnerCheckRepository)? = nil,
        chrome: ShellChrome, host: VotesHost
    ) {
        self.votes = votes
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        VotesScreen(state: model?.state ?? VotesState(), chrome: chrome, actions: actions)
            .onAppear {
                if model == nil { model = VotesViewModel(repo: votes, connections: connections, ownerChecks: ownerChecks) }
                model?.refresh()
            }
    }

    private var actions: VotesActions { VotesActions.of(model, host) }
}

/// The votes of one service connection ("Votes from <name>" on its page): the same list under a back arrow.
public struct ConnectionVotesRoute: View {
    private let connectionID: String
    private let votes: any VotesRepository
    private let connections: any ConnectionsRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let host: VotesHost
    @State private var model: VotesViewModel?

    public init(
        _ connectionID: String, votes: any VotesRepository, connections: any ConnectionsRepository,
        ownerChecks: (any OwnerCheckRepository)? = nil, host: VotesHost
    ) {
        self.connectionID = connectionID
        self.votes = votes
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.host = host
    }

    public var body: some View {
        ConnectionVotesScreen(state: model?.state ?? VotesState(), onBack: host.onBack, actions: VotesActions.of(model, host))
            .onAppear {
                if model == nil {
                    model = VotesViewModel(repo: votes, connections: connections, ownerChecks: ownerChecks, only: connectionID)
                }
                model?.refresh()
            }
    }
}

extension VotesActions {
    @MainActor static func of(_ model: VotesViewModel?, _ host: VotesHost) -> VotesActions {
        var a = VotesActions()
        a.onOpen = host.onOpen
        a.onOpenConnection = host.onOpenConnection
        guard let m = model else { return a }
        a.onRetry = { m.refresh() }
        a.onNoticesShown = { m.noticesShown($0) }
        a.onCloseWindow = { m.closeWindowNow() }
        return a
    }
}

/// One vote's screen with its view model.
public struct VoteRoute: View {
    private let key: VoteKey
    private let votes: any VotesRepository
    private let connections: any ConnectionsRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let host: VotesHost
    @State private var model: VoteViewModel?

    public init(
        _ key: VoteKey, votes: any VotesRepository, connections: any ConnectionsRepository,
        ownerChecks: (any OwnerCheckRepository)? = nil, host: VotesHost
    ) {
        self.key = key
        self.votes = votes
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.host = host
    }

    public var body: some View {
        VoteScreen(state: model?.state ?? VoteScreenState(key: key), proof: model?.proofFile, actions: actions)
            .onAppear {
                guard model == nil else { return }
                model = VoteViewModel(key: key, repo: votes, connections: connections, ownerChecks: ownerChecks)
            }
    }

    private var actions: VoteActions {
        var a = VoteActions()
        a.onBack = host.onBack
        guard let m = model else { return a }
        a.onRetry = { m.refresh() }
        a.onSelect = { m.select($0) }
        a.onCast = { m.askCast() }
        a.onConfirmCast = { m.confirmCast() }
        a.onDismissCast = { m.dismissCast() }
        a.onPassword = { m.setPassword($0) }
        a.onSubmitPassword = { m.submitPassword() }
        a.onCheck = { m.checkWithService() }
        a.onAnswerRestore = { m.answerRestore(mine: $0) }
        a.onSaveProof = { m.askProof() }
        a.onDismissProofWarning = { m.dismissProofWarning() }
        a.onFetchProof = { m.fetchProof() }
        a.onProofExporterAnswered = { m.proofExporterAnswered(saved: $0) }
        a.onProofExporterFailed = { m.proofExporterFailed() }
        a.onProofShown = { m.proofShown() }
        a.onRelease = { m.askRelease() }
        a.onDismissRelease = { m.dismissRelease() }
        a.onConfirmRelease = { m.release(pin: $0) }
        a.onDismissCastProblem = { m.dismissCastProblem() }
        a.onCloseWindow = { m.closeWindowNow() }
        a.onDismissAlreadyVoted = { m.dismissAlreadyVoted() }
        a.onForgetSecrets = { m.forgetSecrets() }
        a.onLeave = { m.leave() }
        return a
    }
}
#endif
