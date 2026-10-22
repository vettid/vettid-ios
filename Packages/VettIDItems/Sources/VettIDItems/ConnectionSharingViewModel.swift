import Foundation
import Observation
import VettIDData

/// A connection's sharing state. Mirrors vettid-android `ConnectionSharingUiState`.
public struct ConnectionSharingState: Equatable, Sendable, Failing {
    public let connectionID: String
    public var connectionName: String?
    public var rules: [ShareRule] = []
    /// The grants given to this connection (rule and one-off), active ones first.
    public var given: [GrantView] = []
    public var items: [String: ItemSummary] = [:]
    public var loading = true
    public var busy = false
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
    public var limit: VaultLimit?
    public var confirmRevoke: GrantView?

    public init(connectionID: String, connectionName: String? = nil) {
        self.connectionID = connectionID
        self.connectionName = connectionName
    }

    public var active: [GrantView] { given.filter(\.active) }

    /// Items the rules include, by id, that the connection can only ask to use (critical, §10.13).
    public var usable: [String] {
        var seen = Set<String>()
        return rules.flatMap(\.included).filter { seen.insert($0).inserted && items[$0]?.sensitivity == .critical }
    }

    public var pendingCount: Int { rules.reduce(0) { $0 + $1.pending.count } }

    /// Each rule's id → the other rules of this connection covering the same tags or items (§10.12).
    public var overlaps: [String: [ShareRule]] { RuleOverlaps.of(rules) }

    /// The connection has the most rules it can have (§10.12 `share_rules_subject`, 64): no new one.
    public var atRuleLimit: Bool { rules.count >= RuleDraft.maxRulesPerSubject }
}

/// What one connection can see (VAULT-ITEMS §6, VAULT-MESSAGING §10.12): its share rules by tag (each with the items it
/// includes, the ones waiting for the member's decision and the declined ones), and the grants given to it (from rules and
/// one-off requests), which the member can revoke. Tags never reach the connection; it sees the items only. Mirrors
/// vettid-android `ConnectionSharingViewModel`.
@MainActor
@Observable
public final class ConnectionSharingViewModel {
    public private(set) var state: ConnectionSharingState

    @ObservationIgnored private let sharing: any SharingRepository
    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored let work = Work()
    @ObservationIgnored private let follows = TaskBag()

    public init(
        connectionID: String, sharing: any SharingRepository, items: any ItemsRepository, connections: any ConnectionsRepository
    ) {
        self.sharing = sharing
        self.items = items
        self.connections = connections
        state = ConnectionSharingState(connectionID: connectionID, connectionName: connectionName(connections, connectionID))
        follows.add(follow(self, read: { $0.items.items }, apply: { m, l in
            m.state.items = Dictionary(l.map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
        }))
        load()
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public func load() {
        state.loading = true
        state.error = nil
        let id = state.connectionID
        work.launch { [weak self, sharing] in
            do {
                let rules = try await sharing.rules(connectionID: id)
                let given = try await sharing.grants().given.filter { $0.connectionID == id }
                guard let self else { return }
                state.rules = rules
                state.given = grantOrder(given)
                state.loading = false
                state.connectionName = connectionName(connections, id) ?? state.connectionName
            } catch {
                guard let self else { return }
                state.loading = false
                state.fail(error)
            }
        }
    }

    public func askRevoke(_ g: GrantView?) { state.confirmRevoke = g }

    public func revoke() {
        guard let g = state.confirmRevoke else { return }
        state.confirmRevoke = nil
        state.busy = true
        work.launch { [weak self, sharing] in
            do {
                try await sharing.revokeGrant(g.grantID)
                self?.state.busy = false
                self?.load()
            } catch {
                guard let self else { return }
                state.busy = false
                state.fail(error)
            }
        }
    }

    public func dismissError() { state.error = nil }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
