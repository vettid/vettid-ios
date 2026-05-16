import Foundation

// MARK: - Actions Client

/// Wire-layer client for the shared-action layer (Phase 3.11, parity
/// with Android `core/actions/`).
///
/// "Actions" are peer-invokable verbs the user (or one of their
/// agents) publishes to a connection: `book-flight`, `pay-bill`,
/// `unlock-door`, etc. Each carries a JSON schema describing the
/// required params, an auth mode that gates invocation, and an
/// optional allowlist of connections / agents that may call it.
///
/// Vault verbs:
///   - `action.list-mine` — catalog of actions the user has published.
///   - `action.set-enabled` — flip an action on/off without removing it.
///   - `action.list-on-peer` — actions a specific peer has published
///     to me.
///   - `action.invoke-on-peer` — actually call one. Returns a
///     request id; the actual result lands on `forApp.action.result`.
///   - `action.list-pending` — incoming invocations awaiting my
///     approve/deny (when the action's auth mode requires it).
///   - `action.approve` / `action.deny` — owner-side approval verbs.
///
/// All calls route through `OwnerSpaceClient.sendAndAwaitResponse` so
/// each envelope carries the replay headers from Phase 0.1.
final class ActionsClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 10

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - My actions

    /// `action.list-mine` — actions I've published to my connections.
    func listMine() async throws -> [[String: Any]] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.list-mine", payload: [:], timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.list-mine failed")
        }
        return (response.result?["actions"] as? [[String: Any]]) ?? []
    }

    /// `action.set-enabled` — toggle an action on/off (kept around but
    /// disabled rather than deleted so peers can see it's coming back).
    func setEnabled(actionId: String, enabled: Bool) async throws {
        let payload: [String: AnyCodableValue] = [
            "action_id": AnyCodableValue(actionId),
            "enabled":   AnyCodableValue(enabled)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.set-enabled", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.set-enabled failed")
        }
    }

    // MARK: - Peer actions (calling them)

    /// `action.list-on-peer` — actions a specific peer has made
    /// callable by me.
    func listOnPeer(connectionId: String) async throws -> [[String: Any]] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.list-on-peer", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.list-on-peer failed")
        }
        return (response.result?["actions"] as? [[String: Any]]) ?? []
    }

    /// `action.invoke-on-peer` — call a peer's published action with
    /// JSON params. Returns the server-issued request id; the eventual
    /// result lands on `forApp.action.result.<request_id>`.
    func invokeOnPeer(
        connectionId: String,
        actionId: String,
        params: [String: Any]
    ) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "action_id":     AnyCodableValue(actionId),
            "params":        AnyCodableValue(params)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.invoke-on-peer", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.invoke-on-peer failed")
        }
        return response.result?["request_id"] as? String ?? ""
    }

    // MARK: - Owner-side approval

    /// `action.list-pending` — invocations from peers waiting on my
    /// approve/deny (only relevant for actions whose auth mode is
    /// "consent-per-call").
    func listPending() async throws -> [[String: Any]] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.list-pending", payload: [:], timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.list-pending failed")
        }
        return (response.result?["pending"] as? [[String: Any]]) ?? []
    }

    func approve(requestId: String) async throws {
        let payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.approve", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.approve failed")
        }
    }

    func deny(requestId: String, reason: String = "") async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId)
        ]
        if !reason.isEmpty { payload["reason"] = AnyCodableValue(reason) }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "action.deny", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw ActionsClientError.vaultError(response.error ?? "action.deny failed")
        }
    }
}

// MARK: - Errors

enum ActionsClientError: LocalizedError {
    case vaultError(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Actions vault error: \(msg)"
        }
    }
}
