import Foundation
import VettIDData

// An agent's or a desktop's request: the decision of one it holds for approval (AA5, AA8), and the end of access from a renewal
// request (VAULT-MESSAGING 0.78.0 §6.8 step 3).
extension ApprovalDetailViewModel {
    /// An agent's held request, approved (`approval.decide{approve: true}`, §6.8): the vault's answer is said before the screen
    /// closes. Never from a list entry or a notification: only here, from its own screen.
    func approveHeld(_ d: DeviceRequest) {
        // Only the request the member was shown, as bytes (``ApprovalsRepository/approveDeviceRequest(_:)``).
        let shown = state.heldShow
        let way: AgentWay?
        switch d.held {
        case .itemRun?: way = .run
        case .itemProxy?: way = .proxy
        default: way = nil
        }
        var item: String?
        switch shown {
        case .run(_, let name, _)?, .proxy(_, let name, _)?: item = name
        default: item = nil
        }
        decideHeld(key: PendingApproval.device(d).key) { [repo] _ in
            let r = try await repo.approveDeviceRequest(d).result
            // Only a run or a proxy is referred again (§6.8 step 4): not done, the new approval is a new decision. For any other op
            // `referred` is a result like the rest (AA5's "Approved, but your vault answered: referred.").
            if r == "referred", way != nil { return .referred }
            var recorded = false
            if r == "ok", case .itemRun(let run)? = d.held, !run.flags.isDisjoint(with: [.programUnrecorded, .programChanged]) {
                // AA8 "Approving and the pin": said only when the item's settings, read now, show the matched entry with this
                // run's `sha256` and `program`.
                recorded = await repo.programRecorded(
                    agentID: d.deviceID ?? "", itemID: run.itemID, program: run.program, sha256: run.sha256
                )
            }
            return .approved(result: r, way: way, pinRecorded: recorded, item: item)
        }
    }

    /// AA8 "Fail closed": a run's `cwd` without `member_folder` is shown only once the item's settings, read for its own agent
    /// and item, allow it. Three reads, each failure followed by a wait (``cwdWaits``), Deny only meanwhile; after the third
    /// failure the run stays Deny only for good.
    func readCwdRule() {
        guard !cwdRead, case .device(let d)? = local.approval, case .itemRun(let run)? = d.held, run.hasCwd, let agent = d.deviceID
        else { return }
        cwdRead = true
        let (repo, waits) = (repo, cwdWaits)
        work.launch { [weak self] in
            for wait in waits {
                if let ok = await repo.runCwdRule(agentID: agent, itemID: run.itemID) {
                    self?.local.cwdAllowed = ok
                    return
                }
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            self?.local.cwdAllowed = false
        }
    }

    /// [body] decides a request an agent holds and says how it ended; a `not_found` is "no longer waiting", any other failure
    /// is shown with the request kept.
    func decideHeld(key: String, _ body: @escaping @MainActor (String) async throws -> DeviceOutcome) {
        guard !local.busy else { return }
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                let outcome = try await body(key)
                self?.local.outcome = outcome
            } catch let f as VaultFailure where f.kind == .notFound {
                self?.local.outcome = .noLongerWaiting
            } catch {
                self?.failed(error)
                return
            }
            self?.local.busy = false
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
}
