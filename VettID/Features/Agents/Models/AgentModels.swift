import Foundation

/// Data models for agent connection management.
///
/// Agents are AI agent connectors (vettid-agent) that connect to a user's vault
/// to access secrets and perform actions on the user's behalf. The owner must
/// approve each request when approval_mode is "always_ask".

// MARK: - Agent Connection

/// An agent connection as returned by the vault.
struct AgentConnection: Identifiable, Equatable {
    let connectionId: String
    let agentName: String
    let agentType: String
    let status: String
    let approvalMode: String
    let scope: [String]
    let connectedAt: String
    let lastActiveAt: String?
    let hostname: String?
    let platform: String?

    var id: String { connectionId }

    /// Whether the agent is currently active
    var isActive: Bool {
        status == "active"
    }

    /// Human-readable approval mode description
    var approvalModeDescription: String {
        switch approvalMode {
        case "always_ask":
            return "Always ask for approval"
        case "auto_within_contract":
            return "Auto-approve within scope"
        case "auto_all":
            return "Auto-approve all"
        default:
            return approvalMode
        }
    }

    /// Human-readable agent type
    var displayAgentType: String {
        guard !agentType.isEmpty else { return "" }
        return agentType
            .replacingOccurrences(of: "_", with: " ")
            .prefix(1).uppercased() + agentType
            .replacingOccurrences(of: "_", with: " ")
            .dropFirst()
    }

    /// Human-readable status
    var displayStatus: String {
        status.prefix(1).uppercased() + status.dropFirst()
    }

    /// Parse from vault response dictionary
    static func from(dict: [String: Any]) -> AgentConnection {
        let scopeArray: [String]
        if let rawScope = dict["scope"] as? [Any] {
            scopeArray = rawScope.compactMap { $0 as? String }
        } else {
            scopeArray = []
        }

        return AgentConnection(
            connectionId: dict["connection_id"] as? String ?? "",
            agentName: dict["agent_name"] as? String ?? "Unknown",
            agentType: dict["agent_type"] as? String ?? "",
            status: dict["status"] as? String ?? "unknown",
            approvalMode: dict["approval_mode"] as? String ?? "always_ask",
            scope: scopeArray,
            connectedAt: dict["connected_at"] as? String ?? "",
            lastActiveAt: dict["last_active_at"] as? String,
            hostname: dict["hostname"] as? String,
            platform: dict["platform"] as? String
        )
    }
}

// MARK: - Agent Management State

/// State for the agent management screen.
enum AgentManagementState: Equatable {
    case loading
    case loaded([AgentConnection])
    case empty
    case error(String)
}

// MARK: - Agent Approval State

/// State for the agent approval screen.
enum AgentApprovalState: Equatable {
    case loading
    case ready(AgentApprovalRequest)
    case processingApproval
    case processingDenial
    case approved
    case denied
    case error(String)

    static func == (lhs: AgentApprovalState, rhs: AgentApprovalState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading),
             (.processingApproval, .processingApproval),
             (.processingDenial, .processingDenial),
             (.approved, .approved),
             (.denied, .denied):
            return true
        case (.ready(let a), .ready(let b)):
            return a.requestId == b.requestId
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Create Invitation State

// MARK: - Stage-2 Authorization Models
//
// Mirrors Android 830ba5f (agents Phase 4). vettid-agent has completed
// Stage 1 (resolved invite, generated ephemeral X25519 keypair) and
// posted `agent.request-session`. The phone surfaces the agent's
// identity card + requested scope hints, the owner picks the final
// `granted_scope` / `approval_mode` / `duration` / `rate_limit`, and
// `agent.authorize-session` writes them into the vault's
// ConnectionContract.

/// Stage-2 pending-auth payload pushed to the phone over
/// `OwnerSpace.<guid>.forApp.agent.pending-authorization`. Parallel to
/// `DevicePendingAuthNotification` but carries scope + duration hints
/// the desktop equivalent doesn't need.
struct AgentPendingAuthNotification: Equatable {
    let connectionId: String
    let approvalToken: String
    let agentPubKey: String
    let agentMetadata: AgentMetadataSummary?
    let binaryFpPrefix: String
    let expiresAt: Int
    /// Tokens the agent is asking for. Defaults-on in the picker;
    /// owner can untoggle anything before approving. Tokens outside
    /// this set can't be added — the vault would refuse them since
    /// the agent didn't acknowledge them in request-session.
    let requestedScope: [String]
    /// "always_ask" | "auto_within_contract". Owner can downgrade
    /// (auto → ask) but not upgrade.
    let requestedApprovalMode: String
    let requestedDurationSeconds: Int
    let defaultDurationSeconds: Int
    let maxDurationSeconds: Int
}

/// Identity-card fields the agent sends for the owner to verify before
/// approving. Mirrors `AgentMetadataSummary` (Android 830ba5f). Same
/// shape as the vault's vault-manager AgentMetadata, minus the
/// server-side fields (first_seen_at, ip_address).
struct AgentMetadataSummary: Equatable {
    let agentType: String
    let binaryFingerprint: String
    let machineFingerprint: String
    let hostname: String
    let platform: String
    let osName: String
    let osVersion: String
    let appVersion: String
}

/// Per-scope toggle state for the AuthorizeAgentView scope picker.
/// Each requested token gets default-on; the owner can untoggle anything
/// before approving.
struct ScopeToggle: Equatable, Identifiable {
    let token: String
    var granted: Bool
    var id: String { token }
}

/// State for the AuthorizeAgentView (Stage-2 surface). Mirrors Android
/// `AuthorizeAgentState`.
enum AuthorizeAgentState: Equatable {
    /// Waiting for the pending-authorization push from the vault.
    case waiting
    /// Form is ready — owner can pick scope / mode / duration and Approve.
    case ready(
        notification: AgentPendingAuthNotification,
        scopes: [ScopeToggle],
        approvalMode: String,         // "always_ask" | "auto_within_contract"
        durationSeconds: Int,
        rateLimitMax: Int,
        rateLimitPer: String          // "minute" | "hour"
    )
    case submitting
    case done
    case error(String)
}

// MARK: - Create-Invitation State

/// State for the create agent invitation screen.
///
/// Matches Android aecfa99 + the new vault agent pairing flow
/// (vettid-dev 338ca24): the vault mints a 12-char invite code +
/// scoped NATS creds, publishes the payload to invite.<code> on
/// JetStream, and returns the code for the user to paste into
/// `vettid-agent init`. Previous shape (`inviteToken` + `shortLink`
/// pointing at the never-registered vettid.com/agent URL) is retired.
enum CreateAgentInvitationState: Equatable {
    case ready
    case creating
    case created(inviteCode: String, connectionId: String, expiresAt: String)
    case error(String)

    static func == (lhs: CreateAgentInvitationState, rhs: CreateAgentInvitationState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.creating, .creating):
            return true
        case (.created(let c1, let cid1, let e1), .created(let c2, let cid2, let e2)):
            return c1 == c2 && cid1 == cid2 && e1 == e2
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
