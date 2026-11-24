import Foundation
import VettIDData

// An agent's or a desktop's request: the decision of one it holds for approval (AA5, AA8), and the end of access from a renewal
// request (VAULT-MESSAGING 0.78.0 §6.8 step 3).
extension ApprovalDetailViewModel {
    /// An agent's held request, approved (`approval.decide{approve: true}`, §6.8): the vault's answer is said before the screen
    /// closes. Never from a list entry or a notification: only here, from its own screen.
    func approveHeld(_ d: DeviceRequest) {
        decideHeld(key: PendingApproval.device(d).key) { [repo] key in
            let r = try await repo.approveDeviceRequest(key).result
            return r == "referred" ? .referred : .approved(result: r)
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
