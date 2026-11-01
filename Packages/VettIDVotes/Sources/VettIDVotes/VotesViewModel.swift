import Foundation
import Observation
import VettIDData

/// A request of a Votes screen that failed: said plainly, never silent. [code] is the vault's own code when it gave one
/// (`already_voted`, `not_open`, …); [retryAfterSeconds] a password backoff's wait.
public struct VoteProblem: Equatable, Sendable {
    public var kind: FailureKind
    public var code: String?
    public var retryAfterSeconds: Int64

    public init(kind: FailureKind, code: String? = nil, retryAfterSeconds: Int64 = 0) {
        self.kind = kind
        self.code = code
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// From a failure: a ``VaultFailure``'s own kind and code, else ``FailureKind/other``.
    init(_ e: any Error) {
        let f = e as? VaultFailure
        self.init(kind: f?.kind ?? .other, code: f?.code, retryAfterSeconds: f?.retryAfterSeconds ?? 0)
    }
}

/// Whether a failure is work cut off by a lock or by the app leaving, which is silent: a ``CancellationError``, any failure that
/// arrives in a task that was cancelled, and a transport's `URLError.cancelled` that a failure carries (``VaultFailures`` maps
/// every `URLError` to ``FailureKind/network``; the relay and the site reader turn a cancelled request into a
/// ``CancellationError`` themselves, so this is the net under any path that does not).
func isSilent(_ e: any Error) -> Bool {
    e is CancellationError || Task.isCancelled || ((e as? VaultFailure)?.cause as? URLError)?.code == .cancelled
}

/// The name a service connection is shown by: the name it gave (cleaned), else the connection's title; empty when neither
/// shows. Mirrors vettid-android `serviceName`.
func serviceName(_ c: ConnectionInfo?) -> String { AccountNames.cleaned(c?.name) ?? AccountNames.cleaned(c?.displayName) ?? "" }

/// The Votes list's state (ANDROID-PLAN 0.1.102 §4 "Votes", screen 1). The votes are the service's words and the member's
/// own: never printed, dumped or mirrored. Mirrors vettid-android `VotesUiState`.
public struct VotesState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var votes: [VoteSummary] = []
    public var reconnect: [ReconnectEntry] = []
    public var dropped: [DroppedNotice] = []
    public var problems: [ProblemsNotice] = []
    /// connection id to the service's name as the connection shows it.
    public var services: [String: String] = [:]
    public var load = ListLoad.notLoaded
    public var error: FailureKind?
    /// The lock of the unlock window a cast opened failed: told until it is closed (**Close it now**) or the vault locks.
    public var windowNotClosed: WindowNotClosed?
    public var windowClosing = false
    public var windowCloseProblem: VoteProblem?

    public init() {}

    public var open: [VoteSummary] { votes.filter(VoteRules.inOpenSection) }
    public var closed: [VoteSummary] { votes.filter { !VoteRules.inOpenSection($0) } }

    public var loading: Bool { votes.isEmpty && reconnect.isEmpty && error == nil && load != .loaded }

    /// Nothing at all to show: the list is read and holds no vote, no connection to connect again, no notice.
    public var empty: Bool {
        load == .loaded && votes.isEmpty && reconnect.isEmpty && dropped.isEmpty && problems.isEmpty && windowNotClosed == nil
    }

    public var description: String { "VotesState(votes: \(votes.count), load: \(load), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Votes list (ANDROID-PLAN 0.1.102): the vault's `vote.list`, read when the screen opens and on every return; a
/// `vote.event` re-reads it in the repository. Held in memory only. A shown `dropped` notice is acknowledged to the vault
/// ([noticesShown]) so that it does not come back. With [only], the votes and notices of that one service connection
/// ("Votes from <name>"). Work cut off by a lock or by the app leaving reaches here as ``CancellationError`` and is
/// silent: no error text. Mirrors vettid-android `VotesViewModel`.
@MainActor
@Observable
public final class VotesViewModel {
    @ObservationIgnored private let repo: any VotesRepository
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let only: String?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local = VotesState()

    /// [ownerChecks]: a list refused because the daily check was due reads again by itself once a check passes.
    public init(
        repo: any VotesRepository, connections: any ConnectionsRepository, ownerChecks: (any OwnerCheckRepository)? = nil,
        only: String? = nil
    ) {
        self.repo = repo
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.only = only
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func mine<T>(_ list: [T], _ id: (T) -> String) -> [T] { only.map { o in list.filter { id($0) == o } } ?? list }

    public var state: VotesState {
        var s = local
        s.votes = mine(repo.votes) { $0.connectionID }
        s.reconnect = mine(repo.reconnect) { $0.connectionID }
        s.dropped = mine(repo.dropped) { $0.connectionID }
        s.problems = mine(repo.problems) { $0.connectionID }
        s.services = Dictionary(connections.connections.map { ($0.id, serviceName($0)) }, uniquingKeysWith: { a, _ in a })
        s.load = repo.load
        s.windowNotClosed = repo.windowNotClosed
        return s
    }

    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.error == .ownerCheckRequired else { return }
        refresh()
    }

    /// On opening and on every return to the screen.
    public func refresh() {
        local.error = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.refresh()
            } catch where isSilent(error) {
                // A lock or the app leaving cut the read off: silent (the list is read again when the screen returns).
            } catch {
                self?.local.error = failureKind(error)
            }
        }
    }

    /// The `dropped` notices of these connections were shown: sent to the vault as `ack_dropped` with the next read.
    public func noticesShown(_ connectionIDs: [String]) { repo.acknowledgeDropped(connectionIDs) }

    /// **Close it now** on the notice of a lock that failed: the notice goes only when this went through.
    public func closeWindowNow() {
        guard !local.windowClosing else { return }
        local.windowClosing = true
        local.windowCloseProblem = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.closeWindowNow()
                self?.local.windowClosing = false
            } catch where isSilent(error) {
                self?.local.windowClosing = false
            } catch {
                self?.local.windowClosing = false
                self?.local.windowCloseProblem = VoteProblem(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
