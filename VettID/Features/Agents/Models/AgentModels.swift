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

/// State for the create agent invitation screen.
enum CreateAgentInvitationState: Equatable {
    case ready
    case creating
    case created(inviteToken: String, connectionId: String, shortLink: String)
    case error(String)

    static func == (lhs: CreateAgentInvitationState, rhs: CreateAgentInvitationState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.creating, .creating):
            return true
        case (.created(let t1, let c1, let s1), .created(let t2, let c2, let s2)):
            return t1 == t2 && c1 == c2 && s1 == s2
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
