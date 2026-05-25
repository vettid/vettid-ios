import Foundation
import Combine

/// Stage-2 agent authorization. Mirrors Android
/// `AuthorizeAgentViewModel` (Phase 4, commit 830ba5f).
///
/// The agent has resolved its invite code, generated an ephemeral
/// X25519 keypair, and posted `agent.request-session`. The vault
/// stores `AgentPendingAuth` and pushes
/// `agent.pending-authorization` to the owner's phone —
/// `OwnerSpaceClient` deserialises it into an
/// `AgentPendingAuthNotification` on the `agentPendingAuth` stream.
///
/// This view-model:
///   1. Listens to `agentPendingAuth`, filtered to the route's
///      `connectionId`.
///   2. Seeds `.ready` with default-on toggles for every
///      `requested_scope` token and a duration picked from the agent's
///      hint (clamped to `[60s, max]`).
///   3. On Approve, publishes `agent.authorize-session` with the
///      owner's final scope / approval_mode / rate_limit / duration.
///      The vault does the X25519+HKDF, persists the
///      `ConnectionContract`, and publishes
///      `agent.session.activated` to the agent's MessageSpace channel.
///
/// Unlike the desktop authorise flow, scope is the load-bearing
/// input. The agent's `requestedScope` is a hint — every token here
/// defaults-on but is freely toggleable; tokens outside the requested
/// set can't be added (the vault would refuse them anyway, since the
/// agent didn't acknowledge them in `request-session`).
@MainActor
final class AuthorizeAgentViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AuthorizeAgentState = .waiting

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal

    private var listenerTask: Task<Void, Never>?
    private var connectionIdFilter: String?

    // MARK: - Init

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Bind

    /// Called from the screen on `.onAppear`. Begins collecting the
    /// pending-auth flow filtered to this `connectionId`; once the
    /// notification arrives, seeds `.ready`. Idempotent.
    func bindConnection(connectionId: String) {
        connectionIdFilter = connectionId
        listenerTask?.cancel()
        guard let client = ownerSpaceClient else { return }
        client.startAgentEventSubscription()
        listenerTask = Task { [weak self] in
            for await notification in client.agentPendingAuth {
                guard let self = self else { return }
                await MainActor.run {
                    guard notification.connectionId == self.connectionIdFilter else { return }
                    self.seedReady(notification)
                }
            }
        }
    }

    private func seedReady(_ notif: AgentPendingAuthNotification) {
        // If the user has already toggled things on this screen and
        // the vault re-emits (replay=1 / they backgrounded and came
        // back), don't clobber their picks.
        if case .ready = state { return }

        let toggles = notif.requestedScope.map { ScopeToggle(token: $0, granted: true) }

        // Duration: prefer the agent's hint if within [60s, max];
        // else fall back to the vault default. The vault re-clamps
        // anyway.
        let hint = notif.requestedDurationSeconds
        let seedDuration: Int
        if hint >= 60 && hint <= notif.maxDurationSeconds {
            seedDuration = hint
        } else if notif.defaultDurationSeconds > 0 {
            seedDuration = notif.defaultDurationSeconds
        } else {
            seedDuration = 60 * 60
        }

        // Approval mode locked to always_ask unless the agent
        // explicitly requested auto. Owner can downgrade but not
        // upgrade — agents that didn't ask for auto might not
        // handle silently-approved ops they expected to prompt for.
        let mode = (notif.requestedApprovalMode == "auto_within_contract")
            ? "auto_within_contract"
            : "always_ask"

        state = .ready(
            notification: notif,
            scopes: toggles,
            approvalMode: mode,
            durationSeconds: seedDuration,
            rateLimitMax: Self.defaultRateLimitMax,
            rateLimitPer: Self.defaultRateLimitPer
        )
    }

    // MARK: - Mutations

    func toggleScope(_ token: String, granted: Bool) {
        guard case .ready(let notif, var scopes, let mode, let dur, let max, let per) = state else { return }
        scopes = scopes.map { $0.token == token ? ScopeToggle(token: $0.token, granted: granted) : $0 }
        state = .ready(notification: notif, scopes: scopes, approvalMode: mode, durationSeconds: dur, rateLimitMax: max, rateLimitPer: per)
    }

    func setApprovalMode(_ mode: String) {
        guard case .ready(let notif, let scopes, _, let dur, let max, let per) = state else { return }
        // Don't let the user pick auto_within_contract if the agent
        // didn't ask for it.
        if mode == "auto_within_contract" && notif.requestedApprovalMode != "auto_within_contract" {
            return
        }
        state = .ready(notification: notif, scopes: scopes, approvalMode: mode, durationSeconds: dur, rateLimitMax: max, rateLimitPer: per)
    }

    func setDuration(_ seconds: Int) {
        guard case .ready(let notif, let scopes, let mode, _, let max, let per) = state else { return }
        let capped = min(Swift.max(seconds, 60), notif.maxDurationSeconds)
        state = .ready(notification: notif, scopes: scopes, approvalMode: mode, durationSeconds: capped, rateLimitMax: max, rateLimitPer: per)
    }

    func setRateLimit(max: Int, per: String) {
        guard case .ready(let notif, let scopes, let mode, let dur, _, _) = state else { return }
        let cleanedMax = Swift.max(max, 0)
        let cleanedPer = (per == "minute") ? "minute" : "hour"
        state = .ready(notification: notif, scopes: scopes, approvalMode: mode, durationSeconds: dur, rateLimitMax: cleanedMax, rateLimitPer: cleanedPer)
    }

    // MARK: - Approve / Deny

    func approve() async {
        guard case .ready(let notif, let scopes, let mode, let dur, let max, let per) = state else { return }
        let grantedTokens = scopes.filter { $0.granted }.map { $0.token }
        let displayName = Self.agentDisplayName(notif)

        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }
        state = .submitting

        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(notif.connectionId),
            "approval_token": AnyCodableValue(notif.approvalToken),
            "agent_name": AnyCodableValue(displayName),
            "granted_scope": AnyCodableValue(grantedTokens as [Any]),
            "approval_mode": AnyCodableValue(mode),
            "duration_seconds": AnyCodableValue(dur),
            "rate_limit": AnyCodableValue([
                "max": max,
                "per": per
            ] as [String: Any])
        ]

        // `agent.authorize-session` needs the matching AgentPendingAuth
        // to be live in the vault. The agent's request-session can be
        // delayed (initial NATS connect + bootstrap creds) so a "no
        // pending authorization" error means "agent not ready yet" —
        // retry rather than fail the pairing. Mirrors the device path.
        let deadline = Date().addingTimeInterval(Self.retryWindow)
        while true {
            do {
                let response = try await client.sendAndAwaitResponse(
                    "agent.authorize-session",
                    payload: payload,
                    timeout: 20
                )
                if response.success {
                    state = .done
                    return
                }
                let errMsg = response.error ?? ""
                if errMsg.range(of: "pending authorization", options: .caseInsensitive) != nil
                    && Date() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryInterval * 1_000_000_000))
                    continue
                }
                state = .error(errMsg.isEmpty ? "Authorization failed" : errMsg)
                return
            } catch {
                state = .error(error.localizedDescription)
                return
            }
        }
    }

    /// Owner tapped Deny. Publishes `agent.revoke`; vault tears down
    /// the connection. Marks `.done` either way so the screen pops.
    func deny() async {
        guard case .ready(let notif, _, _, _, _, _) = state else { return }
        guard let client = ownerSpaceClient else {
            state = .done
            return
        }
        state = .submitting
        do {
            _ = try await client.sendAndAwaitResponse(
                "agent.revoke",
                payload: [
                    "connection_id": AnyCodableValue(notif.connectionId),
                    "reason": AnyCodableValue("owner_denied_authorization")
                ],
                timeout: 10
            )
        } catch {
            // fire-and-forget from the owner's POV
        }
        state = .done
    }

    // MARK: - Helpers

    /// Name the vault writes into `ConnectionContract.AgentName` (and
    /// peer-side label). Picks the most informative bit of metadata
    /// the agent sent.
    private static func agentDisplayName(_ notif: AgentPendingAuthNotification) -> String {
        guard let meta = notif.agentMetadata, !meta.agentType.isEmpty else { return "Agent" }
        if !meta.hostname.isEmpty {
            return "\(meta.agentType) @ \(meta.hostname)"
        }
        return meta.agentType
    }

    deinit { listenerTask?.cancel() }

    private static let retryWindow: TimeInterval = 45
    private static let retryInterval: TimeInterval = 2
    private static let defaultRateLimitMax = 60
    private static let defaultRateLimitPer = "hour"
}
