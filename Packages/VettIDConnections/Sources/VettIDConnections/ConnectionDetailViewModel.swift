import Foundation
import Observation
import VettIDData

/// What the detail screen asks the member to confirm first.
public enum DetailConfirm: Equatable, Sendable {
    case remove
}

/// What the Votes feature knows of one connection (ANDROID-PLAN 0.1.102 "Votes"): [count] votes from it (a service
/// connection gets the row "Votes from <name>"), whether one is [unfinished] (removing the connection asks first), and
/// whether VettID's service list names this person connection as a service ([reconnect]: "Connect again to vote").
public struct ConnectionVotes: Equatable, Sendable {
    public var count = 0
    public var unfinished = false
    public var reconnect = false

    public init(count: Int = 0, unfinished: Bool = false, reconnect: Bool = false) {
        self.count = count
        self.unfinished = unfinished
        self.reconnect = reconnect
    }

    /// The votes of [connectionID] in the Votes list now; nothing where the vault has none.
    @MainActor
    public static func of(_ connectionID: String, _ votes: (any VotesRepository)?) -> ConnectionVotes {
        guard let votes else { return ConnectionVotes() }
        let mine = votes.votes.filter { $0.connectionID == connectionID }
        return ConnectionVotes(
            count: mine.count, unfinished: mine.contains(where: VoteRules.unfinished),
            reconnect: votes.reconnect.contains { $0.connectionID == connectionID }
        )
    }
}

/// A connection's detail screen state. Names are the members' own: never printed, dumped or mirrored. Mirrors
/// vettid-android `ConnectionDetailUiState` without member authentication (IOS-PLAN §8 I2.3).
public struct ConnectionDetailState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var connectionID: String
    public var connection: ConnectionInfo?
    public var loading = true
    public var busy = false
    public var confirm: DetailConfirm?
    /// The connection is gone (removed here, or unknown to the vault): the screen closes.
    public var gone = false
    public var error: FailureKind?
    /// Both directions of sharing with this connection (VAULT-ITEMS §6, VAULT-MESSAGING §10.12).
    public var sharing = DetailSharing()
    /// A share rule the member asked to delete, waiting for the confirmation.
    public var deleteRule: ShareRule?
    /// This connection's votes; nothing where the vault has none.
    public var votes = ConnectionVotes()

    public init(connectionID: String) { self.connectionID = connectionID }

    public var description: String {
        "ConnectionDetailState(loaded: \(connection != nil), loading: \(loading), busy: \(busy), gone: \(gone), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the connection page offers for a connection's asks (VAULT-MESSAGING 0.23.0 §10.4.1). Mirrors vettid-android
/// `AsksAction`.
public enum AsksAction: Equatable, Sendable {
    case mute
    case unmute
    /// `connection.asks.resume` while paused.
    case resume
    /// `connection.asks.resume` without a pause: clears the cooldowns of declined asks.
    case allowAgain
}

/// A connection's asks as the page shows them: muted, paused and the declined asks in cooldown, with the actions that end
/// each state. Unmuting does not resume a pause, and resuming does not unmute (§10.4.1), so both can be offered at once.
/// Nil for a vault before 0.23.0 (no `asks` on the connection): nothing is shown or offered. Mirrors vettid-android
/// `AsksView`.
public struct AsksView: Equatable, Sendable {
    public var muted: Bool
    public var paused: Bool
    public var pausedAt: Date?
    public var cooldowns: Int
    public var actions: [AsksAction]

    /// A state the member should see before the rest of the page.
    public var prominent: Bool { muted || paused }

    public static func of(_ a: AskState?) -> AsksView? {
        guard let a else { return nil }
        let resume: AsksAction? = a.paused ? .resume : (a.cooldowns > 0 ? .allowAgain : nil)
        return AsksView(
            muted: a.muted, paused: a.paused, pausedAt: a.pausedAt, cooldowns: a.cooldowns,
            actions: [resume, a.muted ? .unmute : .mute].compactMap { $0 }
        )
    }
}

public extension ConnectionInfo {
    /// The name the sharing and asks texts use: the first name on the peer's account, else its full name; nil before the
    /// names arrived (vettid-android `sharingName`).
    var sharingName: String? {
        AccountNames.cleaned(firstName) ?? AccountNames.cleaned(accountName)
    }
}

/// A connection (ANDROID-PLAN §4): the profile it shares (self-asserted), its asks (mute, resume: VAULT-MESSAGING 0.23.0
/// §10.4.1), favourite and remove (confirmed). No safety code, alias, note or block here (as vettid-android, whose owner
/// decided so), and sharing both ways (what the member shares with it, what it shares with the member: §10.12). Mirrors
/// vettid-android `ConnectionDetailViewModel` without member authentication (IOS-PLAN §8 I2.3).
@MainActor
@Observable
public final class ConnectionDetailViewModel {
    @ObservationIgnored private let connections: any ConnectionsRepository
    /// Nil while the app has no sharing (the cards are not shown then; chosen; not in the spec: vettid-android always has it).
    @ObservationIgnored private let sharing: (any SharingRepository)?
    /// Nil while the app has no Votes (chosen; not in the spec: vettid-android defaults to `NoVotes`).
    @ObservationIgnored private let votes: (any VotesRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The connection was in the repository's list: once it is not, it is gone.
    @ObservationIgnored private var listed = false
    private var local: ConnectionDetailState

    public init(
        connectionID: String, connections: any ConnectionsRepository, sharing: (any SharingRepository)? = nil,
        votes: (any VotesRepository)? = nil
    ) {
        self.connections = connections
        self.sharing = sharing
        self.votes = votes
        local = ConnectionDetailState(connectionID: connectionID)
        load()
        loadSharing()
        follows.add(follow(self, read: { $0.inList }, apply: { $0.onListed($1) }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private var inList: Bool { connections.connections.contains { $0.id == local.connectionID } }

    /// The connection left the list (removed on another device, or the vault locked and the lists were emptied): the
    /// screen closes and drops what it showed, its names and profile included. vettid-android keeps the last copy on
    /// screen (chosen; not in the spec: nothing read from the vault stays shown once the vault no longer lists it).
    private func onListed(_ present: Bool) {
        if present {
            listed = true
        } else if listed {
            local.connection = nil
            local.gone = true
            local.sharing = DetailSharing()
            local.deleteRule = nil
        }
    }

    /// Reads the connection (on opening, and "Try again" after a failure).
    public func load() {
        local.loading = true
        local.error = nil
        let (connections, id) = (connections, local.connectionID)
        work.launch { [weak self] in
            do {
                let c = try await connections.connection(id)
                self?.local.loading = false
                self?.local.connection = c
            } catch {
                let kind = failureKind(error)
                self?.local.loading = false
                self?.local.error = kind
                self?.local.gone = kind == .notFound
            }
        }
    }

    /// Reads both directions again (`share.rule.list` for this connection, `grant.list`), e.g. when the screen comes back from
    /// the rule editor. Only grants in force count; a failure leaves the rest of the screen as it is.
    public func loadSharing() {
        guard let sharing else { return }
        let id = local.connectionID
        work.launch { [weak self] in
            do {
                let rules = try await sharing.rules(connectionID: id).filter { $0.connectionID == id }
                let g = try await sharing.grants()
                let inForce = { (list: [GrantView]) in
                    list.filter { $0.connectionID == id && $0.active }.sorted { $0.name.lowercased() < $1.name.lowercased() }
                }
                // An answer that lands after the connection is gone is dropped (nothing read stays shown).
                guard let self, !local.gone else { return }
                local.sharing = DetailSharing(
                    rules: rules, given: inForce(g.given), received: inForce(g.received),
                    asked: g.requested.filter { $0.connectionID == id && $0.state == Self.askPending }, loaded: true
                )
            } catch {
                guard let self, !local.gone else { return }
                local.sharing.loaded = true
                local.sharing.failed = true
            }
        }
    }

    private static let askPending = "pending"

    /// The connection as the list has it now (a change from another device shows at once), else as read; nothing once
    /// it is gone.
    public var state: ConnectionDetailState {
        var s = local
        if !s.gone, let c = connections.connections.first(where: { $0.id == s.connectionID }) { s.connection = c }
        s.votes = s.gone ? ConnectionVotes() : ConnectionVotes.of(s.connectionID, votes)
        return s
    }

    private var id: String { local.connectionID }

    public func toggleFavorite() {
        guard let c = state.connection else { return }
        let (connections, id) = (connections, id)
        act { try await connections.setFavorite(id, favorite: !c.favorite) }
    }

    /// Mutes or unmutes this connection's asks (`connection.asks.mute`, 0.23.0 §10.4.1).
    public func muteAsks(_ muted: Bool) {
        let (connections, id) = (connections, id)
        act { try await connections.setAsksMuted(id, muted: muted) }
    }

    /// Resumes paused asks and clears the cooldowns of declined ones (`connection.asks.resume`, §10.4.1).
    public func resumeAsks() {
        let (connections, id) = (connections, id)
        act { try await connections.resumeAsks(id) }
    }

    /// Asks the member to confirm [confirm] (nil: never mind).
    public func ask(_ confirm: DetailConfirm?) { local.confirm = confirm }

    /// Removes the connection once confirmed (`connection.remove`, §10.4): the peer is told, the screen closes.
    public func confirm() {
        guard local.confirm == .remove else { return }
        local.confirm = nil
        let (connections, id) = (connections, id)
        act { [weak self] in
            try await connections.remove(id)
            self?.local.gone = true
        }
    }

    public func dismissNotice() { local.error = nil }

    /// Asks to delete a share rule of this connection (nil: never mind).
    public func askDeleteRule(_ rule: ShareRule?) { local.deleteRule = rule }

    /// Deletes the rule asked about (`share.rule.delete`, §10.12): its items are withdrawn, then both directions are read again.
    public func deleteRule() {
        guard let r = local.deleteRule, let sharing else { return }
        local.deleteRule = nil
        act { [weak self] in
            try await sharing.deleteRule(r.ruleID)
            self?.loadSharing()
        }
    }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                try await body()
                self?.local.busy = false
            } catch {
                self?.local.busy = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
