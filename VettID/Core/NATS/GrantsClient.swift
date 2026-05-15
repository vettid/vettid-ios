import Foundation

// MARK: - Grants Client

/// Wire-layer client for the three vault verb families that make up the
/// Grants subsystem (Phase 3.1, parity with Android `GrantsRepository`):
///
///   - `grant.*` — data and minor-secret access grants. A peer requests
///     access to an item; the owner approves (with mode + expiry +
///     max-uses + reason) or denies; held-in-trust values are fetched
///     foreground-only via `grant.fetch-remote`.
///
///   - `critical-secret-use.*` — peer asks the owner to *perform an
///     operation* (sign / decrypt / derive / auth) using a critical
///     secret. The value never leaves the owner's vault — only the
///     operation result.
///
///   - `verify.*` — peer challenges the owner to prove identity; the
///     owner approves with a password envelope, the vault publishes the
///     verdict and a `connection.get-verify-state` row.
///
/// All calls go through `OwnerSpaceClient.sendAndAwaitResponse` so each
/// envelope carries `timestamp_ms` + `nonce` (Phase 0.1) and password-
/// gated writes pick up the encrypted-credential blob automatically
/// (Phase 0.7).
final class GrantsClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let credentialStore: ProteanCredentialStore
    private let defaultTimeout: TimeInterval = 10

    init(ownerSpaceClient: OwnerSpaceClient,
         credentialStore: ProteanCredentialStore = ProteanCredentialStore()) {
        self.ownerSpaceClient = ownerSpaceClient
        self.credentialStore = credentialStore
    }

    // MARK: - grant.* — data / minor-secret access

    /// Request access to a peer's item. Returns the server-issued
    /// request_id so the requester can correlate the eventual approve
    /// / deny event.
    func request(
        connectionId: String,
        itemKind: String,
        itemRef: String,
        itemLabel: String,
        mode: String,
        deliverTo: String,
        requestedExpiresAt: TimeInterval,
        requestedMaxUses: Int,
        reason: String
    ) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "item_kind": AnyCodableValue(itemKind),
            "item_ref": AnyCodableValue(itemRef),
            "item_label": AnyCodableValue(itemLabel),
            "mode": AnyCodableValue(mode),
            "deliver_to": AnyCodableValue(deliverTo),
            "requested_expires_at": AnyCodableValue(Int(requestedExpiresAt)),
            "requested_max_uses": AnyCodableValue(requestedMaxUses),
            "reason": AnyCodableValue(reason)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.request", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.request failed")
        }
        return response.result?["request_id"] as? String ?? ""
    }

    /// Approve an inbound grant request. `expiresAt` / `maxUses` /
    /// `mode` override the requester's ask when provided (pass 0 / nil
    /// to inherit the request's values). Returns the issued grant_id.
    /// Password-gated — caller supplies the encrypted envelope.
    func approve(
        requestId: String,
        expiresAt: TimeInterval? = nil,
        maxUses: Int? = nil,
        mode: String? = nil,
        encryptedPasswordHash: String,
        ephemeralPublicKey: String,
        nonce: String,
        salt: String
    ) async throws -> String {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId),
            "encrypted_password_hash": AnyCodableValue(encryptedPasswordHash),
            "ephemeral_public_key": AnyCodableValue(ephemeralPublicKey),
            "nonce": AnyCodableValue(nonce),
            "salt": AnyCodableValue(salt)
        ]
        if let e = expiresAt, e > 0 { payload["expires_at"] = AnyCodableValue(Int(e)) }
        if let m = maxUses,   m > 0 { payload["max_uses"]    = AnyCodableValue(m) }
        if let mode = mode, !mode.isEmpty { payload["mode"]  = AnyCodableValue(mode) }
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.approve", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.approve failed")
        }
        return response.result?["grant_id"] as? String ?? ""
    }

    /// Deny an inbound grant request. Optional `reason` goes back to the
    /// requester. Not password-gated — denying doesn't release secret
    /// material.
    func deny(requestId: String, reason: String = "") async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId)
        ]
        if !reason.isEmpty { payload["reason"] = AnyCodableValue(reason) }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.deny", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.deny failed")
        }
    }

    /// Revoke an outstanding grant the owner previously approved.
    func revoke(grantId: String, reason: String = "") async throws {
        var payload: [String: AnyCodableValue] = [
            "grant_id": AnyCodableValue(grantId)
        ]
        if !reason.isEmpty { payload["reason"] = AnyCodableValue(reason) }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.revoke", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.revoke failed")
        }
    }

    /// Receiver-side: pull a value the owner approved. Triggers a
    /// foreground fetch — held-in-trust values are NEVER persisted to
    /// the receiver's vault.
    func fetchRemote(grantId: String) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "grant_id": AnyCodableValue(grantId)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.fetch-remote", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.fetch-remote failed")
        }
        return response.result?["request_id"] as? String ?? ""
    }

    /// List grants the owner has issued (outbound from this side).
    /// Optionally filter to a single connection.
    func listOutbound(connectionId: String? = nil) async throws -> [[String: Any]] {
        var payload: [String: AnyCodableValue] = [:]
        if let cid = connectionId, !cid.isEmpty {
            payload["connection_id"] = AnyCodableValue(cid)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.list-outbound", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.list-outbound failed")
        }
        return (response.result?["grants"] as? [[String: Any]]) ?? []
    }

    /// List grants this connection has received (inbound).
    func listInbound(connectionId: String? = nil) async throws -> [[String: Any]] {
        var payload: [String: AnyCodableValue] = [:]
        if let cid = connectionId, !cid.isEmpty {
            payload["connection_id"] = AnyCodableValue(cid)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.list-inbound", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.list-inbound failed")
        }
        return (response.result?["received_grants"] as? [[String: Any]]) ?? []
    }

    /// Owner-side: list pending requests awaiting an approve/deny decision.
    func listPending() async throws -> [[String: Any]] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "grant.list-pending", payload: [:], timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "grant.list-pending failed")
        }
        return (response.result?["pending"] as? [[String: Any]]) ?? []
    }

    // MARK: - critical-secret-use.* — operation requests

    /// Ask the owner to perform an operation using one of their critical
    /// secrets. The owner sees a `CriticalUseApprovalView` prompt; the
    /// value never leaves their vault. `payloadBase64` is the data to
    /// be operated on (e.g. bytes to sign); `context` is human-readable
    /// rationale for the approval screen.
    func requestCriticalUse(
        connectionId: String,
        itemRef: String,
        itemLabel: String,
        operation: String,
        payloadBase64: String,
        context: String
    ) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "item_ref": AnyCodableValue(itemRef),
            "item_label": AnyCodableValue(itemLabel),
            "operation": AnyCodableValue(operation),
            "payload": AnyCodableValue(payloadBase64),
            "context": AnyCodableValue(context)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "critical-secret-use.request-use", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "critical-secret-use request failed")
        }
        return response.result?["request_id"] as? String ?? ""
    }

    /// Owner approves a critical-secret-use request. Password-gated.
    /// On success the vault performs the operation, returns the result
    /// to the requester via `forApp.critical-secret-use.completed`, and
    /// the value itself stays inside the credential blob.
    func approveCriticalUse(
        requestId: String,
        encryptedPasswordHash: String,
        ephemeralPublicKey: String,
        nonce: String,
        salt: String
    ) async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId),
            "encrypted_password_hash": AnyCodableValue(encryptedPasswordHash),
            "ephemeral_public_key": AnyCodableValue(ephemeralPublicKey),
            "nonce": AnyCodableValue(nonce),
            "salt": AnyCodableValue(salt)
        ]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "critical-secret-use.approve", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "critical-secret-use approve failed")
        }
    }

    func denyCriticalUse(requestId: String, reason: String = "") async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId)
        ]
        if !reason.isEmpty { payload["reason"] = AnyCodableValue(reason) }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "critical-secret-use.deny", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "critical-secret-use deny failed")
        }
    }

    // MARK: - verify.* — identity-verify challenges

    /// Initiate an identity-verify challenge against a peer. Returns the
    /// `request_id` the responder will see on their inbound-requests row.
    func requestVerify(connectionId: String, challenge: String) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "challenge": AnyCodableValue(challenge)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "connection-authenticate.request", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "verify request failed")
        }
        return response.result?["request_id"] as? String ?? ""
    }

    /// Approve an inbound identity-verify challenge. Password-gated;
    /// vault publishes a positive verdict and updates the persistent
    /// per-connection verify state.
    func approveVerify(
        requestId: String,
        encryptedPasswordHash: String,
        ephemeralPublicKey: String,
        nonce: String,
        salt: String
    ) async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId),
            "encrypted_password_hash": AnyCodableValue(encryptedPasswordHash),
            "ephemeral_public_key": AnyCodableValue(ephemeralPublicKey),
            "nonce": AnyCodableValue(nonce),
            "salt": AnyCodableValue(salt)
        ]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "verify.approve", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "verify approve failed")
        }
    }

    func denyVerify(requestId: String, reason: String = "") async throws {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId)
        ]
        if !reason.isEmpty { payload["reason"] = AnyCodableValue(reason) }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "verify.deny", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "verify deny failed")
        }
    }

    /// Read the persistent per-connection verify state (last inbound /
    /// outbound at/ok/reason). The connection card's persistent verify
    /// row reads from this; the vault publishes updates after every
    /// approve/deny round-trip.
    func getVerifyState(connectionId: String) async throws -> [String: Any] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "connection.get-verify-state", payload: payload, timeout: defaultTimeout
        )
        guard response.success else {
            throw GrantsClientError.vaultError(response.error ?? "get-verify-state failed")
        }
        return response.result ?? [:]
    }
}

// MARK: - Errors

enum GrantsClientError: LocalizedError {
    case vaultError(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Grants vault error: \(msg)"
        }
    }
}
