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
    /// Its challenger withdrew it (VAULT-MESSAGING 0.80.0 §10.4): the screen stays, says so and offers Close in place of
    /// the decision, also once a decision in flight was answered `not_found` (ANDROID-PLAN 0.1.101).
    public var withdrawn = false
    /// The requesting connection is a service (VAULT-MESSAGING 0.69.0 §6.4): muting its asks is confirmed first.
    public var connectionIsService = false
    /// The requesting connection is in the connections list, so whether it is a service is known.
    public var connectionKnown = false
    /// The requesting connection's asks are muted (§10.4.1): the withdrawn notice no longer offers the mute.
    public var asksMuted = false
    /// The mute's confirmation is showing (a service connection's, or one not yet known).
    public var confirmMute = false
    /// The mute is on its way: the notice stays, its action waits.
    public var muting = false
    /// Why the mute failed; the only failure a withdrawn request's screen shows.
    public var muteError: FailureKind?
    /// Not held in memory since the screen opened, and the vault never said it was decided or expired: an approval that
    /// arrived only as an event is not read again after a lock or a restart (IOS-PLAN §6.9; no vault list names it), so
    /// its feed item opens this rather than "Already decided" (chosen; not in the spec). One that arrives meanwhile (a
    /// list read on its way) is shown.
    public var notHeld = false
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
    /// A session request's device: when its current access session ends (VAULT-MESSAGING 0.78.0 §6.8 step 3), passed or
    /// not, as the device list read when the screen opened says (and the events since); nil for a device with none, for
    /// any other request, and while that read has not been answered. ``renewalUntil(at:)`` says whether it renews.
    public var sessionEnd: Date?
    /// "End access for <device>?" is open (from "Deny and end access now").
    public var confirmEnd = false
    /// Ending access failed: said plainly with Try again; the request stays open.
    public var endFailure: FailureKind?
    /// Ending access is being sent from the screen of a request that had left: that screen stays.
    public var ending = false
    /// The vault is held (§3.6.3): a confirmation ends nothing, and a failed end is not offered again.
    public var held = false
    /// The session request the renewal's texts name, kept when it left the screen (a hold drops it).
    public var endRequest: PendingApproval?

    public init(key: String) { self.key = key }

    /// A renewal request (0.78.0 §6.8 step 3): the end of the device's session while it is still ahead of [now]; nil for a
    /// first request (no session, a session that passed while shown, or a list not read).
    public func renewalUntil(at now: Date = Date()) -> Date? { sessionEnd.flatMap { $0 > now ? $0 : nil } }

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

    /// Whether the request's `exp` has passed: it is no longer offered and the screen says it is decided or expired, as
    /// the vault would refuse it (chosen; not in the spec: vettid-android leaves the button until the list drops it).
    public func expired(at now: Date = Date()) -> Bool { approval?.exp.map { $0 <= now } ?? false }

    /// Whether the password backoff (`retry_after`) is over at [now].
    func backoffOver(_ now: Date) -> Bool { retryUntil.map { now > $0 } ?? true }

    /// Whether the approve button is offered now ([now]: for a password backoff and the request's expiry). Member
    /// authentication respects the backoff as a critical use does (chosen; not in the spec: vettid-android checks it for
    /// the critical use only; the vault refuses both alike).
    public func canApprove(at now: Date = Date()) -> Bool {
        guard !expired(at: now) else { return false }
        return switch approval {
        case nil, .device?: false
        case .grant?: !grantIndexes.isEmpty
        // 0.10.3: only once the safety code is known, and only once per member.
        case .connection(.incoming(let r))?: r.state == .pending
        case .connection(.outgoing(let r))?: r.state == .pending && r.sas != nil
        // §10.13: only a payload that matches its hash, shown to the member, can be approved; a field that cannot hold a
        // seed (0.21.0) only denied.
        case .critical(let c)?: c.suitable != false && c.payloadVerified && !password.isEmpty && backoffOver(now)
        case .share(let d)?: d.items.contains { !shareExcluded.contains($0.itemID) }
        case .authentication?: !password.isEmpty && backoffOver(now)
        }
    }

    public var description: String {
        "ApprovalDetailState(busy: \(busy), done: \(done), gone: \(gone), withdrawn: \(withdrawn), notHeld: \(notHeld), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
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
    @ObservationIgnored private let vault: (any ItemsRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local: ApprovalDetailState
    /// The repository's ``ApprovalsRepository/forgetCount`` when the screen opened.
    @ObservationIgnored private let forgetCountAtOpen: Int
    /// The repository's ``ApprovalsRepository/deviceSessionReads`` when the screen first held its session request: the
    /// request is judged by a read answered since (0.78.0 §6.8 step 3: the list is read when the request is shown).
    @ObservationIgnored private var sessionReadsAtOpen = 0
    /// Whether the device's session was last known live: a failed end is cleared when it then ends (nil: not known yet).
    @ObservationIgnored private var sessionWasLive: Bool?
    /// A session request's screen asks for the sessions while it is open: given back when the model goes.
    @ObservationIgnored private var sessionsAsk: DeviceSessionsAsk?
    /// The device of the session request, from when the screen first holds it (nil for any other request).
    @ObservationIgnored private var sessionDeviceID: String?
    /// How long a decision answered `not_found` waits for a withdrawn flag before it says the ask is gone (ANDROID-PLAN
    /// 0.1.101: about 2 seconds). Tests shorten it.
    @ObservationIgnored var withdrawnWait: Duration = .seconds(2)

    /// [key]: the approval's ``PendingApproval/key``. [connections]: for the requester's name. [items]: the member's items a
    /// category entry can be answered with; [vault] in its place: the Vault list, read quietly when it has not been read
    /// and followed as it changes (without either none, so a category entry cannot be granted: chosen; not in the spec).
    public init(
        key: String, approvals: any ApprovalsRepository, connections: (any ConnectionsRepository)? = nil, items: [AnswerItem] = [],
        vault: (any ItemsRepository)? = nil
    ) {
        repo = approvals
        forgetCountAtOpen = approvals.forgetCount
        self.connections = connections
        self.vault = vault
        vault?.readIfNotLoaded()
        local = ApprovalDetailState(key: key)
        local.approval = approvals.approvals.first { $0.key == key }
        local.items = items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        follows.add(follow(self, read: { m in m.repo.approvals.first { $0.key == m.local.key } }, apply: { m, a in
            if let a { m.local.approval = a }
            // A session request held only after the screen opened (from the feed, before the list answered) is followed
            // from when it arrives.
            m.followSessions()
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
        if let vault { s.items = Self.answers(vault.items) }
        let now = repo.approvals.first { $0.key == local.key }
        s.approval = now ?? local.approval
        // Dropped by a lock or a hold while open, it is no longer held, not decided (IOS-PLAN §6.9). Of the kinds
        // `pending.list` returns (VAULT-MESSAGING 0.70.0 §10.4.2), once the list has been answered since the drop, one
        // that is not held again was decided, expired or withdrawn: "Already decided". "No longer on this phone" stays
        // while the list has not been answered (an older vault, or the read failed or is on its way).
        let dropped = repo.forgetCount != forgetCountAtOpen
        // While access is being ended from the screen of a request that had left, that screen stays.
        let left = now == nil && local.approval != nil && !local.done && (!local.busy || local.ending) && local.criticalResult == nil
        let lost = dropped && (!PendingApproval.eventOnly(key: local.key) || repo.mayHaveBeenDropped(local.key))
        s.gone = left && !lost
        // Missing at the opening: not held only when it may have been dropped; one decided elsewhere stays "Already decided".
        let missing = local.approval == nil && repo.mayHaveBeenDropped(local.key)
        s.notHeld = now == nil && (missing || left && lost)
        if left && lost { s.approval = nil }
        // Withdrawn by its challenger (0.80.0 §10.4): the screen keeps its place and says so, with no decision's failure and
        // no countdown (only a failed mute is said). A decision in flight is answered first (``waitForWithdrawal(_:)``).
        if repo.wasWithdrawn(local.key), local.approval != nil, !local.done, !local.busy, local.criticalResult == nil {
            s.withdrawn = true
            s.gone = false
            s.notHeld = false
            s.error = nil
            s.retryUntil = nil
            s.approval = now ?? local.approval
        }
        sessions(&s)
        let connection = s.approval.flatMap(Self.connectionID).flatMap { id in connections?.connections.first { $0.id == id } }
        s.connectionName = AccountNames.cleaned(connection?.displayName)
        s.connectionKnown = connection != nil
        s.connectionIsService = connection?.isService ?? false
        s.asksMuted = local.asksMuted || connection?.asks?.muted == true
        return s
    }

    private static func connectionID(_ a: PendingApproval) -> String? { a.connectionID }

    /// A session request (0.78.0 §6.8 step 3), set up once, when the screen first holds it: whether it renews a live
    /// session comes from the device list, read now; the read never holds the request back, and if it fails the request is
    /// a first request until a later read answers.
    private func followSessions() {
        guard sessionDeviceID == nil, let device = Self.sessionDevice(local.approval) else { return }
        sessionDeviceID = device
        sessionReadsAtOpen = repo.deviceSessionReads
        sessionsAsk = repo.askDeviceSessions()
        let repo = repo
        work.launch { try? await repo.readDeviceSessions() }
        // A hold closes an open confirmation: nothing is ended while held (§6.8); a due check does not (chosen; not in the
        // spec, as vettid-android).
        follows.add(follow(self, read: { m in m.repo.forgetCount }, apply: { m, _ in
            if m.repo.vaultHeld { m.local.confirmEnd = false }
        }))
        // A failed end has nothing left to retry once the session it was about ends: cleared on that change only, so a
        // failure recorded after the session had passed stays, as one kept while nothing is known (a hold).
        follows.add(follow(self, read: { m in m.sessionLive() }, apply: { m, live in
            guard let live else { return }
            if m.sessionWasLive == true && !live { m.local.endFailure = nil }
            m.sessionWasLive = live
        }))
    }

    /// The device of a session request (`device.session.pending`), nil for any other request.
    static func sessionDevice(_ a: PendingApproval?) -> String? {
        guard case .device(let d)? = a, d.type == "device.session.pending" else { return nil }
        return d.deviceID
    }

    /// The renewal's part of [s]: the request it names (kept when it left), the session's end as a read since the screen
    /// opened says, the hold, and the confirmation (closed while held).
    private func sessions(_ s: inout ApprovalDetailState) {
        let request = s.approval ?? local.approval
        let device = Self.sessionDevice(request)
        s.endRequest = device == nil ? nil : request
        s.held = device != nil && repo.vaultHeld
        s.sessionEnd = sessionEnd(of: device)
        s.confirmEnd = local.confirmEnd && !s.held
    }

    /// The end of [device]'s session as a `device.list` read answered since the screen first held the request says, nil
    /// when it has none or nothing is known.
    private func sessionEnd(of device: String?) -> Date? {
        guard sessionDeviceID != nil, repo.deviceSessionsKnown, repo.deviceSessionReads > sessionReadsAtOpen else { return nil }
        return device.flatMap { repo.deviceSessions[$0] }
    }

    /// Whether this request's device has a live session now, nil while nothing is known (before a read, during a hold).
    private func sessionLive() -> Bool? {
        guard repo.deviceSessionsKnown, repo.deviceSessionReads > sessionReadsAtOpen else { return nil }
        return sessionEnd(of: sessionDeviceID).map { $0 > Date() } ?? false
    }

    /// The Vault list's items as answers, by name.
    static func answers(_ items: [ItemSummary]) -> [AnswerItem] {
        items.map { AnswerItem(id: $0.itemID, name: $0.name, category: $0.category, critical: $0.sensitivity == .critical) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func setPassword(_ v: String) {
        local.password = v
        local.error = nil
    }

    /// The screen left or the app went to the background: the password goes.
    public func forgetSecrets() { local.password = "" }

    public func askBlock(_ show: Bool) { local.confirmBlock = show }

    /// "Mute requests from …" on a withdrawn request (ANDROID-PLAN 0.1.101): a service connection's is confirmed first
    /// (superseded sign-ins are routine for a service), a person's is muted at once. One whose kind is not known yet (the
    /// connections not read) is confirmed too (chosen; not in the spec).
    public func askMute(_ show: Bool) {
        guard show else { return local.confirmMute = false }
        let s = state
        if s.connectionIsService || !s.connectionKnown { local.confirmMute = true } else { mute() }
    }

    /// Mutes the requesting connection's asks (`connection.asks.mute`, §10.4.1), as its detail does. Its own progress, not
    /// the decision's: the withdrawn notice stays meanwhile.
    public func mute() {
        local.confirmMute = false
        guard let id = state.approval.flatMap(Self.connectionID), let connections, !local.muting else { return }
        local.muting = true
        local.muteError = nil
        work.launch { [weak self] in
            do {
                try await connections.setAsksMuted(id, muted: true)
                self?.local.asksMuted = true
            } catch {
                self?.local.muteError = failureKind(error)
            }
            self?.local.muting = false
        }
    }

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

    /// [shown]: for a share decision, the item ids the screen showed when the member tapped. Only those are decided, so a
    /// `share.pending` batch that lands just before the tap is not included or declined unseen (VAULT-MESSAGING §10.12).
    /// Mirrors vettid-android `ApprovalDetailViewModel.approve`.
    public func approve(shown: [String]? = nil) {
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
                let ids = shown ?? d.items.map(\.itemID)
                try await repo.decideShare(
                    d.ruleID, include: ids.filter { !s.shareExcluded.contains($0) }, decline: ids.filter { s.shareExcluded.contains($0) }
                )
            case .device: break
            }
        }
    }

    /// [shown]: as for ``approve(shown:)``; only the share items the screen showed are declined.
    public func deny(shown: [String]? = nil) {
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
            case .share(let d): try await repo.decideShare(d.ruleID, include: [], decline: shown ?? d.items.map(\.itemID))
            case .device: try await repo.declineDeviceRequest(a.key)
            }
        }
    }

    /// "Deny and end access now" on a renewal request (0.78.0 §6.8 step 3): asks "End access for <device>?" first; nothing
    /// is sent yet. From the screen of a request that left, only a failure's Try again, while the session is live.
    public func askEndAccess() {
        let s = state
        guard !s.busy, !s.held, s.renewalUntil() != nil else { return }
        if (s.gone || s.notHeld) && s.endFailure == nil { return }
        local.confirmEnd = true
        local.endFailure = nil
    }

    public func dismissEndAccess() { local.confirmEnd = false }

    public func dismissEndFailure() { local.endFailure = nil }

    /// The member confirmed: `device.session.end{device_id}` alone, never `device.session.deny` as well (0.78.0 §6.8 step
    /// 3): the end drops the pending request and is audited and synced once, as an end. A confirmation already open stays
    /// and ends access when confirmed, even after the session passed or the request left; nothing is sent while the vault
    /// is held. A failure says so and leaves the request open; Try again asks the confirmation again.
    public func endAccess() {
        let s = state
        guard s.confirmEnd, !s.busy, !repo.vaultHeld, let device = Self.sessionDevice(s.approval ?? local.approval) else { return }
        local.confirmEnd = false
        local.ending = s.gone || s.notHeld
        local.busy = true
        local.endFailure = nil
        let repo = repo
        work.launch { [weak self] in
            do {
                try await repo.endDeviceAccess(device)
                guard let self else { return }
                // The device's asks left with the end; the screen closes.
                local.busy = false
                local.ending = false
                local.done = true
            } catch {
                guard let self else { return }
                // What the clock says now: a session that passed while the end was on its way is not "ended" again by the
                // read the failure brings, which would clear the failure at once.
                sessionWasLive = state.renewalUntil() != nil
                local.busy = false
                local.ending = false
                local.endFailure = failureKind(error)
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
                await self?.waitForWithdrawal(error)
                self?.failed(error)
            }
        }
    }

    /// A member authentication answered `not_found` (unknown, decided, expired or withdrawn alike, 0.80.0 §10.4): the
    /// screen keeps showing progress while it waits up to ``withdrawnWait`` for the withdrawn flag, then says withdrawn, or
    /// that the request left. A flag that comes later still turns the screen to withdrawn (``state``). Only a member
    /// authentication can be withdrawn, so no other kind waits (chosen; not in the spec).
    private func waitForWithdrawal(_ error: any Error) async {
        guard (error as? VaultFailure)?.kind == .notFound, local.key.hasPrefix("auth:") else { return }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: withdrawnWait)
        while !repo.wasWithdrawn(local.key), clock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
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
