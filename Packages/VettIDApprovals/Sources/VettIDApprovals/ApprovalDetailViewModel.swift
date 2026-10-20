import Foundation
import Observation
import VettIDData

/// One of the member's items a grant's category entry can be answered with (VAULT-MESSAGING §10.12): its id, name and
/// category, and whether it is critical (never granted). Names only, never values. Mirrors the part of vettid-android
/// `ItemSummary` the decision uses.
public struct AnswerItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var critical: Bool

    public init(id: String, name: String, category: String, critical: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.critical = critical
    }
}

/// What a decision needs from the member: the credential password for the critical actions (ANDROID-PLAN §4 Approvals).
public enum ApprovalNeeds: Equatable, Sendable { case nothing, password }

/// One approval's state. The password is held only while the screen is open and cleared after every decision; neither it
/// nor what the request names is ever printed, dumped or mirrored. Mirrors vettid-android `ApprovalDetailUiState`.
public struct ApprovalDetailState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var key: String
    public var approval: PendingApproval?
    public var password = ""
    public var busy = false
    public var confirmBlock = false
    /// Decided here: the screen closes.
    public var done = false
    /// It left the list without a decision here (decided on another device, or expired).
    public var gone = false
    public var error: FailureKind?
    /// A share decision's items the member unticked: declined, the rest included (§10.12).
    public var shareExcluded: Set<String> = []
    /// The member's items (§10.12: only `data` and `secret` are granted), to answer category entries.
    public var items: [AnswerItem] = []
    /// A grant request's entries the member chose (indexes); nil: the default (every named item that exists).
    public var grantSelected: Set<Int>?
    /// A category entry's answer: index → the member's item id.
    public var grantAnswers: [Int: String] = [:]
    /// Uses and lifetime the member set (nil: the request's).
    public var grantUses: Int?
    public var grantExpiresIn: Int?
    /// A critical-item use was approved: the status the connection received (`ok`, `unsuitable`, `unavailable`).
    public var criticalResult: String?
    /// The end of a password backoff (`retry_after`).
    public var retryUntil: Date?
    /// The limit a `limit` error named (§10.1).
    public var limit: VaultLimit?
    /// The requesting connection's "First Last", when the request names a connection that has names.
    public var connectionName: String?

    public init(key: String) { self.key = key }

    /// The grant entries that will be granted: chosen, and for a category answered.
    public var grantIndexes: Set<Int> {
        guard case .grant(let g)? = approval else { return [] }
        let chosen = grantSelected ?? Set(g.grantable)
        return chosen.filter { i in
            guard g.entries.indices.contains(i) else { return false }
            let e = g.entries[i]
            return (e.kind == "item" && e.available) || grantAnswers[i] != nil
        }
    }

    /// Items the member may answer with: never `critical` (§10.12).
    public var answerable: [AnswerItem] { items.filter { !$0.critical } }

    /// Critical actions ask for the credential password (ANDROID-PLAN §4 Approvals).
    public var needs: ApprovalNeeds {
        switch approval {
        case .authentication?, .critical?: .password
        default: .nothing
        }
    }

    /// Whether the approve button is offered now ([now]: for a password backoff).
    public func canApprove(at now: Date = Date()) -> Bool {
        switch approval {
        case nil, .device?: false
        case .grant?: !grantIndexes.isEmpty
        // 0.10.3: only once the safety code is known, and only once per member.
        case .connection(.incoming(let r))?: r.state == .pending
        case .connection(.outgoing(let r))?: r.state == .pending && r.sas != nil
        // §10.13: only a payload that matches its hash, shown to the member, can be approved; a field that cannot hold a
        // seed (0.21.0) only denied.
        case .critical(let c)?: c.suitable != false && c.payloadVerified && !password.isEmpty && (retryUntil.map { now > $0 } ?? true)
        case .share(let d)?: d.items.contains { !shareExcluded.contains($0.itemID) }
        case .authentication?: !password.isEmpty
        }
    }

    public var description: String {
        "ApprovalDetailState(busy: \(busy), done: \(done), gone: \(gone), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One approval (ANDROID-PLAN §4 Approvals): what is asked, by whom, and approve or deny. Member authentication and
/// critical-item uses take the credential password (VAULT-MESSAGING §10.4, §10.13); a connection request shows its
/// safety code and can be blocked; a grant request is decided entry by entry (§10.12); a desktop's or agent's request
/// can only be declined. Mirrors vettid-android `ApprovalDetailViewModel`.
@MainActor
@Observable
public final class ApprovalDetailViewModel {
    @ObservationIgnored private let repo: any ApprovalsRepository
    @ObservationIgnored private let connections: (any ConnectionsRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local: ApprovalDetailState

    /// [key]: the approval's ``PendingApproval/key``. [connections]: for the requester's name. [items]: the member's items a
    /// category entry can be answered with (the Vault screens bring them, IOS-PLAN §8 I3.1; until then none, so a category
    /// entry cannot be granted: chosen; not in the spec).
    public init(
        key: String, approvals: any ApprovalsRepository, connections: (any ConnectionsRepository)? = nil, items: [AnswerItem] = []
    ) {
        repo = approvals
        self.connections = connections
        local = ApprovalDetailState(key: key)
        local.approval = approvals.approvals.first { $0.key == key }
        local.items = items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        follows.add(follow(self, read: { m in m.repo.approvals.first { $0.key == m.local.key } }, apply: { m, a in
            if let a { m.local.approval = a }
        }))
        // A critical-item request from the list has only the payload's hash: the payload is fetched (§10.13).
        if case .critical(let c)? = local.approval, c.payload.isEmpty {
            let repo = repo
            work.launch { [weak self] in
                do {
                    try await repo.loadCriticalUse(c.requestID)
                } catch {
                    self?.local.error = failureKind(error)
                }
            }
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: ApprovalDetailState {
        var s = local
        let now = repo.approvals.first { $0.key == local.key }
        s.approval = now ?? local.approval
        s.gone = now == nil && local.approval != nil && !local.done && !local.busy && local.criticalResult == nil
        s.connectionName = s.approval.flatMap { a -> String? in
            guard let id = Self.connectionID(a), let n = connections?.connections.first(where: { $0.id == id })?.displayName,
                  !n.isEmpty else { return nil }
            return n
        }
        return s
    }

    private static func connectionID(_ a: PendingApproval) -> String? { a.connectionID }

    public func setPassword(_ v: String) {
        local.password = v
        local.error = nil
    }

    /// The screen left or the app went to the background: the password goes.
    public func forgetSecrets() { local.password = "" }

    public func askBlock(_ show: Bool) { local.confirmBlock = show }

    private func chosen() -> Set<Int> {
        if let s = local.grantSelected { return s }
        if case .grant(let g)? = state.approval { return Set(g.grantable) }
        return []
    }

    /// Ticks or unticks one entry of a grant request.
    public func toggleGrantEntry(_ index: Int) {
        var cur = chosen()
        if cur.contains(index) { cur.remove(index) } else { cur.insert(index) }
        local.grantSelected = cur
    }

    /// Answers a category entry with one of the member's items (and ticks it).
    public func answerGrantEntry(_ index: Int, itemID: String) {
        var cur = chosen()
        cur.insert(index)
        local.grantAnswers[index] = itemID
        local.grantSelected = cur
    }

    public func setGrantUses(_ uses: Int?) { local.grantUses = uses }

    public func setGrantExpiresIn(_ seconds: Int?) { local.grantExpiresIn = seconds }

    /// Ticks or unticks one item of a share decision.
    public func toggleShareItem(_ itemID: String) {
        if local.shareExcluded.contains(itemID) { local.shareExcluded.remove(itemID) } else { local.shareExcluded.insert(itemID) }
    }

    public func approve() {
        let s = state
        guard let a = s.approval, s.canApprove() else { return }
        let (repo, pw) = (repo, s.password)
        decide { [weak self] in
            switch a {
            case .connection(.incoming(let r)): try await repo.approveConnection(r.pendingID)
            case .connection(.outgoing(let r)): try await repo.approveOutgoing(r.connectionID)
            case .authentication(let x): try await repo.approveAuthentication(x.requestID, password: pw)
            case .grant(let g):
                let idx = s.grantIndexes
                let decision = GrantDecision(
                    items: idx.sorted(), answers: s.grantAnswers.filter { idx.contains($0.key) }, uses: s.grantUses,
                    expiresInSeconds: s.grantExpiresIn
                )
                try await repo.decideGrant(g.requestID, decision: decision)
            case .critical(let c):
                let status = try await repo.approveCriticalUse(c.requestID, password: pw)
                self?.local.criticalResult = status ?? "ok"
            case .share(let d):
                let ids = d.items.map(\.itemID)
                try await repo.decideShare(
                    d.ruleID, include: ids.filter { !s.shareExcluded.contains($0) }, decline: ids.filter { s.shareExcluded.contains($0) }
                )
            case .device: break
            }
        }
    }

    public func deny() {
        guard let a = state.approval else { return }
        let repo = repo
        decide {
            switch a {
            case .connection(.incoming(let r)): try await repo.declineConnection(r.pendingID)
            case .connection(.outgoing(let r)): try await repo.declineOutgoing(r.connectionID)
            case .authentication(let x): try await repo.denyAuthentication(x.requestID)
            case .grant(let g): try await repo.decideGrant(g.requestID, approve: false)
            case .critical(let c): try await repo.denyCriticalUse(c.requestID)
            // "Do not share": every item of the question declined (§10.12 `share.decide{decline}`).
            case .share(let d): try await repo.decideShare(d.ruleID, include: [], decline: d.items.map(\.itemID))
            case .device: try await repo.declineDeviceRequest(a.key)
            }
        }
    }

    /// Declines an incoming connection request and blocks the requester (confirmed first).
    public func block() {
        guard case .connection(.incoming(let r))? = state.approval else { return }
        local.confirmBlock = false
        let repo = repo
        decide { try await repo.blockConnectionRequest(r.pendingID) }
    }

    /// The member read the critical-use result.
    public func finish() { local.done = true }

    private func decide(_ body: @escaping @MainActor () async throws -> Void) {
        guard !local.busy else { return }
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                try await body()
                guard let self else { return }
                // A critical use stays on screen with its result; everything else closes.
                local.done = local.criticalResult == nil
                local.password = ""
                local.busy = false
            } catch {
                self?.failed(error)
            }
        }
    }

    private func failed(_ error: any Error) {
        let f = error as? VaultFailure
        local.error = failureKind(error)
        local.limit = f?.limit
        local.password = ""
        let wait = f.flatMap { $0.kind == .backoff && $0.retryAfterSeconds > 0 ? Double($0.retryAfterSeconds) : nil }
        local.retryUntil = wait.map { Date().addingTimeInterval($0) }
        local.busy = false
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
