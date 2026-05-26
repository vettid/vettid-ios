import Foundation
import Combine

/// Stage-2-style authorization for agent-initiated LEASH mints.
/// Mirrors Android `LeashApprovalViewModel` (commit ef03314).
///
/// The agent already paired (Stage-2 of the pairing flow ran earlier)
/// and has now requested a LEASH via `vettid-agent leash mint`. The
/// vault stored a `PendingLeashRequest` and pushed
/// `agent.leash-mint-pending` — this view-model listens, surfaces the
/// scope picker to the owner, and publishes `agent.leash-approve`
/// back with the final scope/duration.
///
/// Approve / Deny outcomes:
///   - vault HandleAgentLeashApprove mints (or denies) and publishes
///     `AgentMsgLeashGranted` / `AgentMsgLeashDenied` to the agent's
///     response subject. The agent's CLI receives the JWT (or denial)
///     without the owner copying anything back manually.
@MainActor
final class LeashApprovalViewModel: ObservableObject {

    @Published private(set) var state: LeashApprovalState = .waiting

    private var ownerSpaceClient: OwnerSpaceClient?
    private var listenerTask: Task<Void, Never>?
    private var requestIdFilter: String?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    /// Called from the screen on first composition with the
    /// request_id. Idempotent.
    func bindRequest(requestId: String) {
        requestIdFilter = requestId
        listenerTask?.cancel()
        guard let client = ownerSpaceClient else { return }
        client.startAgentEventSubscription()
        listenerTask = Task { [weak self] in
            for await notification in client.agentLeashMintPending {
                guard let self = self else { return }
                await MainActor.run {
                    guard notification.requestId == self.requestIdFilter else { return }
                    self.seedReady(notification)
                }
            }
        }
    }

    private func seedReady(_ notif: AgentLeashMintPendingNotification) {
        // Don't clobber owner edits on replay.
        if case .ready = state { return }
        let toggles = notif.requestedScope.map { ScopeToggle(token: $0, granted: true) }
        state = .ready(
            notification: notif,
            scopes: toggles,
            durationSeconds: notif.durationSeconds
        )
    }

    func toggleScope(_ token: String, granted: Bool) {
        guard case .ready(let notif, var scopes, let dur) = state else { return }
        scopes = scopes.map {
            $0.token == token
                ? ScopeToggle(token: $0.token, granted: granted)
                : $0
        }
        state = .ready(notification: notif, scopes: scopes, durationSeconds: dur)
    }

    func setDuration(_ seconds: Int) {
        guard case .ready(let notif, let scopes, _) = state else { return }
        let capped = min(Swift.max(seconds, 60), 24 * 3600)
        state = .ready(notification: notif, scopes: scopes, durationSeconds: capped)
    }

    func approve() async {
        guard case .ready(let notif, let scopes, let dur) = state else { return }
        let granted = scopes.filter { $0.granted }.map { $0.token }
        guard !granted.isEmpty else {
            state = .error("Grant at least one scope before approving.")
            return
        }
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }
        state = .submitting

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.leash-approve",
                payload: [
                    "request_id": AnyCodableValue(notif.requestId),
                    "approved": AnyCodableValue(true),
                    "granted_scope": AnyCodableValue(granted as [Any]),
                    "duration_secs": AnyCodableValue(dur)
                ],
                timeout: 30
            )
            if response.success {
                state = .done
            } else {
                state = .error(response.error ?? "Vault returned failure")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func deny() async {
        guard case .ready(let notif, _, _) = state else { return }
        guard let client = ownerSpaceClient else {
            state = .done
            return
        }
        state = .submitting
        do {
            _ = try await client.sendAndAwaitResponse(
                "agent.leash-approve",
                payload: [
                    "request_id": AnyCodableValue(notif.requestId),
                    "approved": AnyCodableValue(false),
                    "deny_reason": AnyCodableValue("owner_denied")
                ],
                timeout: 10
            )
        } catch {
            // Fire-and-forget on deny — vault publishes AgentMsgLeashDenied
            // to the agent either way.
        }
        state = .done
    }

    deinit { listenerTask?.cancel() }
}
