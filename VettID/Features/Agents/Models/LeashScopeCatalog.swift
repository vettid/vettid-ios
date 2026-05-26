import Foundation

/// LEASH scope vocabulary for the LeashApproval + AgentDetail mint
/// dialogs. Mirrors Android `LeashScopeCatalog.kt` (commit 855a9f5).
///
/// LEASH scopes are `resource:action[:qualifier]` per
/// `vettid-dev/docs/LEASH-TOKEN-FORMAT.md` §"Scope grammar". They are
/// deliberately distinct from agent capability tokens
/// (`AgentScopeLabels` / `Contract.Scope`): capabilities gate vault
/// ops; LEASH scopes describe what an external resource server should
/// accept the LEASH for. A user can mint a LEASH that lets the agent
/// read a specific profile field without granting any vault capability
/// at all.
struct LeashScopeMeta: Equatable {
    let token: String
    let label: String
    let description: String
    /// Defaults-on for the mint dialog's pre-selected toggles.
    var defaultGranted: Bool = false
}

enum LeashScopeCatalog {

    /// Canonical curated LEASH scopes. Order matches dialog display.
    static let common: [LeashScopeMeta] = [
        LeashScopeMeta(
            token: "profile.email:read",
            label: "Read email",
            description: "Lets the agent read your email field from your VettID profile",
            defaultGranted: true
        ),
        LeashScopeMeta(
            token: "profile.name:read",
            label: "Read name",
            description: "Display name from your VettID profile",
            defaultGranted: true
        ),
        LeashScopeMeta(
            token: "credential:list",
            label: "List credentials",
            description: "Enumerate credential names (no values)"
        ),
        LeashScopeMeta(
            token: "wallet.balance:read",
            label: "Read wallet balance",
            description: "View balance of your connected wallet"
        ),
        LeashScopeMeta(
            token: "message:send",
            label: "Send messages",
            description: "Post messages on your behalf to recipients you have connections with"
        )
    ]

    /// Look up display metadata for a scope token. Unknown tokens
    /// fall through to a generic entry that shows the raw token —
    /// we never silently drop a requested scope.
    static func meta(for token: String) -> LeashScopeMeta {
        if let known = common.first(where: { $0.token == token }) {
            return known
        }
        return LeashScopeMeta(
            token: token,
            label: token,
            description: "Custom permission"
        )
    }

    // MARK: - Grammar validator
    //
    // Grammar (per LEASH-TOKEN-FORMAT.md):
    //   scope-token := resource ":" action [ ":" qualifier ]
    //   resource    := identifier ( "." identifier )*
    //   action      := read | write | use | list | sign | *
    //   qualifier   := identifier
    //   identifier  := [a-zA-Z][a-zA-Z0-9_-]*
    private static let identifierPattern = #"^[a-zA-Z][a-zA-Z0-9_-]*$"#
    private static let resourcePattern   = #"^[a-zA-Z][a-zA-Z0-9_-]*(\.[a-zA-Z*][a-zA-Z0-9_-]*)*$"#
    private static let validActions: Set<String> = ["read", "write", "use", "list", "sign", "*"]

    /// Validate a LEASH scope token against the grammar. Vault
    /// re-validates server-side, so this is purely a UX check to
    /// surface bad input before submit.
    static func isValidScope(_ token: String) -> Bool {
        // Verifiers reject unscoped wildcard pair.
        if token == "*:*" { return false }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return false }
        let resource = parts[0]
        let action = parts[1]
        guard resource.range(of: resourcePattern, options: .regularExpression) != nil else { return false }
        guard validActions.contains(action) else { return false }
        if parts.count == 3 {
            let qualifier = parts[2]
            guard qualifier.range(of: identifierPattern, options: .regularExpression) != nil else { return false }
        }
        return true
    }
}
