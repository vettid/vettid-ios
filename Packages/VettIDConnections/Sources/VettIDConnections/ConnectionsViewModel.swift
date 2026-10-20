import Foundation
import Observation
import VettIDData

/// The Connections screen's state. Names are the members' own: never printed, dumped or mirrored. Mirrors vettid-android
/// `ConnectionsUiState`; the connection requests are listed under Approvals (ANDROID-PLAN §4 Approvals).
public struct ConnectionsState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var loading = true
    /// Favourites first, then by name; while searching, only the matching ones.
    public var connections: [ConnectionInfo] = []
    public var invites: [OutstandingInvite] = []
    /// The invitation the member asked to cancel (confirmed first).
    public var cancelling: OutstandingInvite?
    /// Requests the other member declined (0.10.5), until dismissed.
    public var peerDeclines: [PeerDecline] = []
    public var error: FailureKind?
    /// The top bar's search by name; while it is set only matching connections show.
    public var query = ""
    /// Whether there is any connection to search.
    public var searchable = false

    public init() {}

    public var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Nothing at all to show: the empty state.
    public var isEmpty: Bool { connections.isEmpty && invites.isEmpty && peerDeclines.isEmpty }

    public var description: String {
        "ConnectionsState(loading: \(loading), connections: \(connections.count), invites: \(invites.count), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public extension ConnectionInfo {
    /// Whether [query] is in the title ("First Last") or the display name, ignoring case (vettid-android `matches`).
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return displayName.range(of: q, options: .caseInsensitive) != nil || name.range(of: q, options: .caseInsensitive) != nil
    }
}

/// Connections (ANDROID-PLAN §4, Proton's contacts): favourites first, then by name; a star toggles the owner's
/// `favorite` flag (VAULT-MESSAGING §10.4); outstanding invitations on top, each cancellable (confirmed); the other
/// member's declines (0.10.5) until dismissed (here or in Approvals). The connection requests are decided in Approvals.
/// Mirrors vettid-android `ConnectionsViewModel`.
@MainActor
@Observable
public final class ConnectionsViewModel {
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let requests: any ConnectionRequestsRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let account: (any AccountRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The vault was open at the last look (``account``'s phase).
    @ObservationIgnored private var wasOpen = true
    /// What the screen holds itself; the lists come from the repositories (``state``).
    private var local = ConnectionsState()

    /// [ownerChecks]: a list refused because the daily check was due (``FailureKind/ownerCheckRequired``) reads again by
    /// itself once a check passes, as vettid-android's. [account]: the invitations read are dropped when the vault is no
    /// longer open, and read again when it opens.
    public init(
        connections: any ConnectionsRepository,
        requests: any ConnectionRequestsRepository,
        ownerChecks: (any OwnerCheckRepository)? = nil,
        account: (any AccountRepository)? = nil
    ) {
        self.connections = connections
        self.requests = requests
        self.ownerChecks = ownerChecks
        self.account = account
        refresh()
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
        if account != nil {
            follows.add(follow(self, read: { $0.vaultOpen }, apply: { $0.onVaultOpen($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private var vaultOpen: Bool {
        if case .unlocked = account?.phase { return true }
        return false
    }

    /// The daily check passed (or the hold ended): a list it refused is read again.
    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.error == .ownerCheckRequired else { return }
        refresh()
    }

    /// Locked (or left): what was read from the open vault goes; an unlock reads it again.
    private func onVaultOpen(_ open: Bool) {
        defer { wasOpen = open }
        if !open {
            local.invites = []
            local.cancelling = nil
        } else if !wasOpen {
            refresh()
        }
    }

    public var state: ConnectionsState {
        var s = local
        let all = connections.connections
        s.connections = Self.listed(all, query: s.query)
        s.searchable = !all.isEmpty
        s.peerDeclines = requests.peerDeclines
        return s
    }

    /// Favourites first, then by the title, lower-cased (vettid-android's order); only those matching [query].
    static func listed(_ all: [ConnectionInfo], query: String) -> [ConnectionInfo] {
        all.filter { $0.matches(query) }.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            let (x, y) = (a.element.displayName.lowercased(), b.element.displayName.lowercased())
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// Reads the connections and the outstanding invitations again.
    public func refresh() {
        local.error = nil
        let connections = connections
        work.launch { [weak self] in
            do {
                try await connections.refresh()
                let invites = try await connections.outstandingInvites()
                self?.local.loading = false
                self?.local.invites = invites
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    public func setFavorite(_ id: String, _ favorite: Bool) {
        let connections = connections
        act { try await connections.setFavorite(id, favorite: favorite) }
    }

    public func setQuery(_ q: String) { local.query = q }

    /// Asks to cancel [invite] (nil: never mind).
    public func askCancel(_ invite: OutstandingInvite?) { local.cancelling = invite }

    public func confirmCancel() {
        guard let i = local.cancelling else { return }
        local.cancelling = nil
        let connections = connections
        act { [weak self] in
            try await connections.cancelInvite(i.inviteID)
            self?.local.invites.removeAll { $0.inviteID == i.inviteID }
        }
    }

    public func dismissError() { local.error = nil }

    /// The member saw that the other member declined [requestID] (0.10.5): not shown again.
    public func dismissPeerDecline(_ requestID: String) { requests.dismissPeerDecline(requestID) }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        work.launch { [weak self] in
            do {
                try await body()
            } catch {
                self?.local.error = failureKind(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
