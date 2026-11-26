import Foundation
import VettIDData

// An agent's or a desktop's request: the decision of one it holds for approval (AA5, AA8), and the end of access from a renewal
// request (VAULT-MESSAGING 0.78.0 §6.8 step 3).
extension ApprovalDetailViewModel {
    /// What this render of the screen shows of a request an agent holds, for Approve to send (``approve(shown:held:)``); nil for
    /// any other request.
    public func shownHeld() -> ShownHeld? {
        let s = state
        guard case .device(let d)? = s.approval, let show = s.heldShow else { return nil }
        return ShownHeld(request: d, show: show, generation: repo.forgetCount)
    }

    /// An agent's held request, approved (`approval.decide{approve: true}`, §6.8): the vault's answer is said before the screen
    /// closes. Never from a list entry or a notification: only here, from its own screen.
    func approveHeld(_ shown: ShownHeld) {
        // Only the request the member was shown, as bytes, and only while the screen shows it as it did: a request whose item or
        // field was renamed, or whose item list was read again, since the render is not approved
        // (``ApprovalsRepository/approveDeviceRequest(_:generation:stillShown:)``).
        let d = shown.request
        guard shown.show.approvable else { return }
        let way: AgentWay?
        switch d.held {
        case .itemRun?: way = .run
        case .itemProxy?: way = .proxy
        default: way = nil
        }
        var item: String?
        switch shown.show {
        case .run(_, let name, _), .proxy(_, let name, _): item = name
        default: item = nil
        }
        // A desktop's block or removal: the connection as shown, judged again by the approvals at the send (ANDROID-PLAN 0.1.145).
        let target = shown.show.desktopTarget
        let still: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            let s = state
            guard case .device(let now)? = s.approval else { return false }
            return now.sameContent(as: d) && (s.itemsRead == .read || shown.show.namesNoItem) && s.heldShow == shown.show
        }
        decideHeld(key: PendingApproval.device(d).key, generation: shown.generation) { [weak self, repo] _ in
            let r = try await repo.approveDeviceRequest(d, generation: shown.generation, target: target, stillShown: still).result
            // Only a run or a proxy is referred again (§6.8 step 4): not done, the new approval is a new decision. For any other op
            // `referred` is a result like the rest (AA5's "Approved, but your vault answered: referred.").
            if r == "referred", way != nil { return .referred }
            let outcome = DeviceOutcome.approved(result: r, way: way, pinRecorded: false, item: item)
            if r == "ok", case .itemRun(let run)? = d.held, !run.flags.isDisjoint(with: [.programUnrecorded, .programChanged]) {
                self?.readPin(d, run, after: outcome)
            }
            return outcome
        }
    }

    /// AA8 "Approving and the pin": "Approved" is said at once; that the fingerprint is now recorded is added only when the item's
    /// settings, read now, show the matched entry with this run's `sha256` and `program`, and only to the same outcome.
    private func readPin(_ d: DeviceRequest, _ run: ItemRun, after outcome: DeviceOutcome) {
        guard case .approved(let r, let way, _, let item) = outcome else { return }
        let repo = repo
        work.launch { [weak self] in
            let recorded = await repo.programRecorded(
                agentID: d.deviceID ?? "", itemID: run.itemID, program: run.program, sha256: run.sha256
            )
            guard recorded, let self, local.outcome == outcome else { return }
            local.outcome = .approved(result: r, way: way, pinRecorded: true, item: item)
        }
    }

    /// AA8 "Fail closed": a run's `cwd` without `member_folder` is approved only once the item's settings, read for its own agent
    /// and item, allow it; its screen shows meanwhile, Deny only (``ApprovalDetailState/cwdCheck``). One read, and one more
    /// after each wait of ``cwdWaits``; when every read failed the screen says so, with Try again (``retryCwdRule()``), and an
    /// unlock reads again.
    func readCwdRule() {
        guard !cwdRead, case .device(let d)? = local.approval, case .itemRun(let run)? = d.held, run.hasCwd, let agent = d.deviceID
        else { return }
        cwdRead = true
        local.cwdFailed = false
        let (repo, waits) = (repo, cwdWaits)
        work.launch { [weak self] in
            for attempt in 0...waits.count {
                if attempt > 0 {
                    try? await Task.sleep(for: waits[attempt - 1])
                    if Task.isCancelled { return }
                }
                if let ok = await repo.runCwdRule(agentID: agent, itemID: run.itemID) {
                    self?.local.cwdReadFor = CwdReadFor(agentID: agent, itemID: run.itemID)
                    self?.local.cwdAllowed = ok
                    return
                }
            }
            self?.local.cwdFailed = true
        }
    }

    /// "Try again" on a run whose cwd rule could not be read: the reads start over. Nothing is approved by it.
    public func retryCwdRule() {
        guard state.cwdCheck == .failed else { return }
        cwdRead = false
        readCwdRule()
    }

    /// [body] decides a request an agent holds and says how it ended; a `not_found` is "no longer waiting", any other failure
    /// is shown with the request kept. [generation]: the approvals' ``ApprovalsRepository/forgetCount`` when the screen showed
    /// the request; a `not_found` after they were dropped since (a lock while it was on its way) is not an end: the screen says
    /// what it says of a request dropped from this phone ("No longer on this phone"), as for one dropped while shown.
    func decideHeld(key: String, generation: Int? = nil, _ body: @escaping @MainActor (String) async throws -> DeviceOutcome) {
        guard !local.busy else { return }
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                let outcome = try await body(key)
                self?.local.outcome = outcome
            } catch let f as VaultFailure where f.kind == .notFound {
                guard let self else { return }
                let dropped = generation.map { $0 != repo.forgetCount } ?? false
                if !dropped { local.outcome = .noLongerWaiting }
            } catch {
                self?.failed(error)
                return
            }
            self?.local.busy = false
        }
    }

    /// "Try again" on a request whose item list could not be read: the list is read again, quietly; nothing is approved by it.
    public func retryItems() {
        guard state.offersItemsRetry else { return }
        vault?.refreshQuietly()
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
}

// What a request an agent holds shows and allows on its screen.
extension ApprovalDetailState {
    /// The item list could not be read and the request says so: "Try again" reads it again (Approve stays off until a read).
    public var offersItemsRetry: Bool { heldShow == .itemsUnread && itemsRead == .failed }

    /// What a request an agent holds for approval shows and allows, from the item list; nil for any other request.
    public var heldShow: HeldShow? {
        guard case .device(let d)? = approval, DeviceAsks.isHeld(d) else { return nil }
        return DeviceAsks.show(d, items: heldItems, read: itemsRead, connections: heldConnections)
    }

    /// Where a run's `cwd` (without `member_folder`) stands (AA8 "Fail closed"): nil when it has none, or once the item's
    /// settings, read for its own agent and item, allow it; else Deny only, on the run's own screen.
    public var cwdCheck: CwdCheck? {
        guard case .device(let d)? = approval, DeviceAsks.isHeld(d), case .itemRun(let r)? = d.held, r.hasCwd else { return nil }
        if cwdAllowed == true, cwdReadFor?.matches(agentID: d.deviceID ?? "", itemID: r.itemID) == true { return nil }
        if cwdFailed { return .failed }
        return cwdAllowed == false ? .notAllowed : .checking
    }

    /// The run or proxy ended by its `exp` (AA8 "Refused or expired"): `exp` has passed, and the request was still held then (one
    /// that left the list before, decided elsewhere, did not expire).
    public func endedByExpiry(at now: Date = Date()) -> Bool {
        guard let exp = approval?.exp, exp <= now else { return false }
        return leftAt.map { $0 >= exp } ?? true
    }
}

/// The agent and the item a run's cwd rule was read for (AA8 "Fail closed").
public struct CwdReadFor: Equatable, Sendable {
    public var agentID: String
    public var itemID: String

    /// Whether it was read for [agentID] and [itemID], as bytes.
    public func matches(agentID: String, itemID: String) -> Bool {
        self.agentID.sameBytes(agentID) && self.itemID.sameBytes(itemID)
    }
}

/// Where a run's cwd rule stands while it does not allow the run (``ApprovalDetailState/cwdCheck``).
public enum CwdCheck: Equatable, Sendable {
    /// Being read: "Checking where this may run…".
    case checking
    /// Every read failed: "This can't be shown yet. Try again.", with Try again.
    case failed
    /// The item's settings do not allow it (they carry `folders`): Deny only.
    case notAllowed
}
