import Foundation

// MARK: - Action Auth Mode

/// Per-action gate on who can invoke and under what controls.
/// Mirrors Android `ActionAuthMode`.
enum ActionAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Any peer in the allowlist may invoke without further checks.
    case openToAllowlist  = "OPEN_TO_ALLOWLIST"
    /// Each invocation lands on the owner's pending queue and requires
    /// an `action.approve` to actually run.
    case consentPerCall   = "CONSENT_PER_CALL"
    /// Owner-side password required before the vault runs the action
    /// (used for high-stakes actions like move-money / unlock-door).
    case passwordPerCall  = "PASSWORD_PER_CALL"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openToAllowlist: return "Allowlist-only"
        case .consentPerCall:  return "Consent per call"
        case .passwordPerCall: return "Password per call"
        }
    }

    var explainer: String {
        switch self {
        case .openToAllowlist:
            return "Anyone on the allowlist can invoke without prompting you each time."
        case .consentPerCall:
            return "Every invocation appears in your pending inbox and waits for your approve/deny."
        case .passwordPerCall:
            return "Every invocation prompts you for your password before the vault runs the action."
        }
    }
}

// MARK: - Published Action (my catalog)

/// One row in `action.list-mine` — an action the user has published
/// to (some subset of) their connections.
struct PublishedAction: Identifiable, Equatable, Hashable {
    let actionId: String
    let name: String
    let descriptionText: String
    /// JSON-schema describing the params each invocation must supply.
    /// Carried as raw string to avoid a heavy schema-decode at hydrate
    /// time; consumers parse / validate on the call path.
    let paramsSchema: String?
    let authMode: ActionAuthMode
    /// Connection ids permitted to invoke. Empty means "anyone in my
    /// connections" (rare; high-stakes actions narrow this).
    let allowlist: [String]
    let enabled: Bool

    var id: String { actionId }

    static func from(dict: [String: Any]) -> PublishedAction? {
        guard let id = dict["action_id"] as? String,
              let name = (dict["name"] ?? dict["label"]) as? String else {
            return nil
        }
        let authRaw = (dict["auth_mode"] as? String) ?? "OPEN_TO_ALLOWLIST"
        return PublishedAction(
            actionId: id,
            name: name,
            descriptionText: (dict["description"] as? String) ?? "",
            paramsSchema: dict["params_schema"] as? String,
            authMode: ActionAuthMode(rawValue: authRaw) ?? .openToAllowlist,
            allowlist: (dict["allowlist"] as? [String]) ?? [],
            enabled: (dict["enabled"] as? Bool) ?? true
        )
    }
}

// MARK: - Peer's available action (invokable by me)

/// One row in `action.list-on-peer` — an action the peer has made
/// callable. Trimmed shape: name + description + params schema +
/// auth-mode hint so the invoke sheet knows whether to expect a
/// pending-on-approval pattern.
struct PeerAction: Identifiable, Equatable, Hashable {
    let actionId: String
    let name: String
    let descriptionText: String
    let paramsSchema: String?
    let authMode: ActionAuthMode

    var id: String { actionId }

    static func from(dict: [String: Any]) -> PeerAction? {
        guard let id = dict["action_id"] as? String,
              let name = (dict["name"] ?? dict["label"]) as? String else {
            return nil
        }
        let authRaw = (dict["auth_mode"] as? String) ?? "OPEN_TO_ALLOWLIST"
        return PeerAction(
            actionId: id,
            name: name,
            descriptionText: (dict["description"] as? String) ?? "",
            paramsSchema: dict["params_schema"] as? String,
            authMode: ActionAuthMode(rawValue: authRaw) ?? .openToAllowlist
        )
    }
}

// MARK: - Pending Action Approval

/// Inbound invocation awaiting my approve/deny. Drives the
/// PendingActionRow inside ActionScreens; tap → approve sheet.
struct PendingActionApproval: Identifiable, Equatable, Hashable {
    let requestId: String
    let actionId: String
    let actionName: String
    let connectionId: String
    let peerLabel: String
    let params: [String: String]
    let createdAt: Date

    var id: String { requestId }

    static func from(dict: [String: Any]) -> PendingActionApproval? {
        guard let req = dict["request_id"] as? String,
              let aid = dict["action_id"] as? String else { return nil }
        let createdAt = (dict["created_at"] as? Double)
            ?? (dict["created_at"] as? Int).map(Double.init) ?? 0
        let params: [String: String] = {
            if let p = dict["params"] as? [String: String] { return p }
            if let p = dict["params"] as? [String: Any] {
                return p.compactMapValues { $0 as? String }
            }
            return [:]
        }()
        return PendingActionApproval(
            requestId: req,
            actionId: aid,
            actionName: (dict["action_name"] as? String) ?? aid,
            connectionId: (dict["connection_id"] as? String) ?? "",
            peerLabel: (dict["peer_label"] as? String) ?? "",
            params: params,
            createdAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt) : Date()
        )
    }
}

// MARK: - Action Invocation Result

/// Async result delivered on `forApp.action.result.<request_id>`.
/// Surfaced to the call site that issued `invokeOnPeer(...)`.
struct ActionInvocationResult: Equatable {
    let requestId: String
    let success: Bool
    let result: [String: String]
    let errorMessage: String?
}

// MARK: - JSON Schema Validator (stub)

/// Lightweight JSON-schema validator for action params (Phase 3.11).
/// Android's `ActionSchemaValidator` does full draft-07 validation;
/// the iOS port validates a useful subset:
///   - presence of `required` keys,
///   - per-key type checks for "string" / "number" / "boolean".
///
/// Returns nil on success or a human-readable error on failure. Good
/// enough to catch the obvious "you forgot to fill in the airport"
/// case; the vault still does authoritative validation on receipt.
enum ActionSchemaValidator {
    static func validate(schemaJSON: String?, params: [String: Any]) -> String? {
        guard let schemaJSON = schemaJSON, !schemaJSON.isEmpty,
              let data = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let required = schema["required"] as? [String] ?? []
        for key in required where params[key] == nil {
            return "Missing required field: \(key)"
        }

        if let properties = schema["properties"] as? [String: [String: Any]] {
            for (key, propSpec) in properties {
                guard let value = params[key] else { continue }
                let expected = propSpec["type"] as? String ?? "any"
                if !typeMatches(value, expected: expected) {
                    return "Field \(key) must be a \(expected)"
                }
            }
        }
        return nil
    }

    private static func typeMatches(_ value: Any, expected: String) -> Bool {
        switch expected {
        case "string":  return value is String
        case "number", "integer":
            return value is NSNumber && !(value is Bool)
        case "boolean": return value is Bool
        case "array":   return value is [Any]
        case "object":  return value is [String: Any]
        case "any":     return true
        default:         return true
        }
    }
}
