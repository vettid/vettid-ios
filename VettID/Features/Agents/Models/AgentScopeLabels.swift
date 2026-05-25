import Foundation

/// Formal scope vocabulary for agent session authorization. Mirrors
/// Android `AgentScopeLabels.kt` (Phase 4, commit 830ba5f) — the
/// 9-token list in
/// `vettid-agent/docs/AGENT-PAIRING-FLOW.md` §"Locked decisions" #2.
///
/// The agent sends `requested_scope` as a hint; the phone is the sole
/// authority that writes the final `ConnectionContract.Scope` on the
/// vault. Tokens not in this map render with the raw token string and
/// a generic "tool-specific action" description so the owner still
/// sees them — we never silently drop a requested scope just because
/// the phone hasn't learned about it yet.
struct ScopeMeta: Equatable {
    /// Short label rendered next to the toggle.
    let label: String
    /// One-line caption explaining what the agent gets if granted.
    let description: String
    /// True for scopes the owner should think twice about. Renders
    /// the toggle row with a warning accent. Currently: anything
    /// that lets the agent change vault state or send on the owner's
    /// behalf.
    var sensitive: Bool = false
}

enum AgentScopeLabels {
    static let table: [String: ScopeMeta] = [
        "secrets.catalog.read": ScopeMeta(
            label: "Read secret catalog",
            description: "See the list of secret aliases without their values"
        ),
        "secrets.get": ScopeMeta(
            label: "Read secret values",
            description: "Retrieve the value of a secret (still subject to per-op approval)",
            sensitive: true
        ),
        "secrets.put": ScopeMeta(
            label: "Write secrets",
            description: "Create or update secrets in the vault",
            sensitive: true
        ),
        "message.send": ScopeMeta(
            label: "Send messages",
            description: "Send messages to your connections on your behalf",
            sensitive: true
        ),
        "message.recv": ScopeMeta(
            label: "Receive messages",
            description: "Observe inbound messages from your connections"
        ),
        "call.history": ScopeMeta(
            label: "Read call history",
            description: "See past calls — who, when, and duration"
        ),
        "connection.list": ScopeMeta(
            label: "List connections",
            description: "See the names of people you're connected to"
        ),
        "connection.get": ScopeMeta(
            label: "Read connection details",
            description: "View details about a specific connection"
        )
    ]

    /// Look up display metadata for a scope token. Falls back
    /// gracefully for parameterised tokens (e.g. `agent.action.<tool>`)
    /// and unknown tokens.
    static func meta(for token: String) -> ScopeMeta {
        if let known = table[token] { return known }
        if token.hasPrefix("agent.action.") {
            let tool = String(token.dropFirst("agent.action.".count))
            return ScopeMeta(
                label: "Run tool: \(tool)",
                description: "Invoke the agent's \(tool) tool on your behalf",
                sensitive: true
            )
        }
        return ScopeMeta(
            label: token,
            description: "Custom permission requested by the agent"
        )
    }
}
