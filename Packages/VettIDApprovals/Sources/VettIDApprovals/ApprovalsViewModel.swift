import Foundation
import Observation
import VettIDData

/// The Approvals screen's state. What a request names (people, items, notes) is the members' own: never printed, dumped or
/// mirrored. Mirrors vettid-android `ApprovalsUiState`.
public struct ApprovalsState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var loading = true
    /// Everything waiting, newest first, the connection requests included.
    public var approvals: [PendingApproval] = []
    /// Requests the other member declined (0.10.5): told once, until dismissed (here or on Connections).
    public var peerDeclines: [PeerDecline] = []
    public var error: FailureKind?
    /// Why the last read of the open asks (`pending.list`, VAULT-MESSAGING 0.70.0 §10.4.2) failed: the screen says so, with
    /// Retry; ``FailureKind/ownerCheckRequired`` says the vault is on hold.
    public var openAsksError: FailureKind?
    /// Connections whose asks are paused after several declines (0.23.0 §10.4.1): resume, or remove the connection.
    public var paused: [ConnectionInfo] = []
    /// A paused connection the member asked to remove (confirmed first).
    public var confirmRemove: ConnectionInfo?
    public var busy = false
    /// The connections by id, for the names a request's row shows.
    public var connections: [String: ConnectionInfo] = [:]

    public init() {}

    /// The rows: one per approval, a connection's asks within 10 minutes as one batch (§10.4.1).
    public var entries: [ApprovalEntry] { AskBatches.group(approvals) }

    /// Nothing to list at all (the empty state, or the failure).
    public var nothing: Bool { approvals.isEmpty && peerDeclines.isEmpty && paused.isEmpty }

    /// A connection's "First Last", cleaned (VAULT-MESSAGING §10.8); nil without the connection, its names, or anything
    /// visible in them.
    public func connectionName(_ id: String?) -> String? {
        guard let id else { return nil }
        return AccountNames.cleaned(connections[id]?.displayName)
    }

    public var description: String {
        "ApprovalsState(loading: \(loading), approvals: \(approvals.count), paused: \(paused.count), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Approvals (ANDROID-PLAN §4 Approvals): everything waiting for the member's decision, newest first, the connection
/// requests of either side included; a connection's asks batched; the other member's declines until dismissed; and the
/// connections whose asks are paused, with "Resume requests" and "Remove connection". Mirrors vettid-android
/// `ApprovalsViewModel`.
@MainActor
@Observable
public final class ApprovalsViewModel {
    @ObservationIgnored private let approvals: any ApprovalsRepository
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local = ApprovalsState()

    /// [ownerChecks]: a list refused because the daily check was due reads again by itself once a check passes, as
    /// vettid-android's `checkCleared`.
    public init(
        approvals: any ApprovalsRepository, connections: any ConnectionsRepository, ownerChecks: (any OwnerCheckRepository)? = nil
    ) {
        self.approvals = approvals
        self.connections = connections
        self.ownerChecks = ownerChecks
        refresh()
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: ApprovalsState {
        var s = local
        s.approvals = approvals.approvals
        s.peerDeclines = approvals.peerDeclines
        s.openAsksError = approvals.openAsksError
        let all = connections.connections
        s.paused = all.filter { $0.asks?.paused == true }
        s.connections = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return s
    }

    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.error == .ownerCheckRequired || approvals.openAsksError == .ownerCheckRequired else { return }
        refresh()
    }

    public func refresh() {
        local.error = nil
        let approvals = approvals
        work.launch { [weak self] in
            do {
                try await approvals.refreshApprovals()
                self?.local.loading = false
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// Resumes a paused connection's asks (`connection.asks.resume`, 0.23.0 §10.4.1).
    public func resumeAsks(_ connectionID: String) {
        let connections = connections
        act { try await connections.resumeAsks(connectionID) }
    }

    /// Asks to remove [c] (nil: never mind).
    public func askRemove(_ c: ConnectionInfo?) { local.confirmRemove = c }

    /// Removes the paused connection the member confirmed (§10.4.1 offers it with the pause).
    public func remove() {
        guard let c = local.confirmRemove else { return }
        local.confirmRemove = nil
        let connections = connections
        act { try await connections.remove(c.id) }
    }

    /// The member saw that the other member declined [requestID] (0.10.5): not shown again.
    public func dismissPeerDecline(_ requestID: String) { approvals.dismissPeerDecline(requestID) }

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
