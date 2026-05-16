import Foundation

// MARK: - Connections Client

/// NATS-based client for peer-to-peer connection management.
/// Uses OwnerSpaceClient.sendAndAwaitResponse() for proper request-response
/// correlation by event_id, avoiding race conditions.
///
/// Connection handlers enable secure peer messaging by:
/// 1. Creating invitation credentials for connecting to this vault
/// 2. Storing credentials received from peer invitations
/// 3. Managing credential lifecycle (rotation, revocation)
///
/// All operations go through the vault-manager NATS handlers and require
/// the vault EC2 instance to be online.
final class ConnectionsClient {

    private let ownerSpaceClient: OwnerSpaceClient

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Create Invite

    /// Create an invitation for a peer to connect to this vault.
    ///
    /// The invitation contains NATS credentials scoped to the owner's message space,
    /// allowing the peer to publish messages that this vault can receive.
    ///
    /// - Parameters:
    ///   - peerGuid: GUID of the peer being invited
    ///   - label: Human-readable label for this connection
    ///   - expiresInMinutes: How long the invitation is valid (default: 1440 = 24 hours)
    /// - Returns: Connection invitation with credentials
    func createInvite(
        peerGuid: String,
        label: String,
        expiresInMinutes: Int = 1440
    ) async throws -> NatsConnectionInvitation {
        let payload: [String: AnyCodableValue] = [
            "peer_guid": AnyCodableValue(peerGuid),
            "label": AnyCodableValue(label),
            "expires_in_minutes": AnyCodableValue(expiresInMinutes)
        ]

        let response = try await sendAndAwait("connection.create-invite", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        // Parse inviter profile
        var inviterProfile: [String: String] = [:]
        if let profileDict = result["inviter_profile"] as? [String: Any] {
            for (key, value) in profileDict {
                if let stringValue = value as? String {
                    inviterProfile[key] = stringValue
                }
            }
        }

        // Use vault-returned label (which may be richer) or fallback to what we sent
        let vaultLabel = result["label"] as? String ?? label

        return NatsConnectionInvitation(
            connectionId: result["connection_id"] as? String ?? "",
            peerGuid: peerGuid,
            label: vaultLabel,
            natsCredentials: result["credentials"] as? String
                ?? result["nats_credentials"] as? String ?? "",
            ownerSpaceId: result["owner_space"] as? String
                ?? result["owner_space_id"] as? String ?? "",
            messageSpaceId: result["message_space"] as? String
                ?? result["message_space_id"] as? String
                ?? result["message_space_topic"] as? String ?? "",
            expiresAt: result["expires_at"] as? String ?? "",
            inviterProfile: inviterProfile,
            inviteCode: result["invite_code"] as? String ?? ""
        )
    }

    // MARK: - Store Credentials

    /// Store credentials received from a peer's invitation.
    ///
    /// Call this after receiving an invitation from another vault owner.
    /// The credentials allow this vault to send messages to the peer's message space.
    ///
    /// - Parameters:
    ///   - connectionId: Unique ID for this connection
    ///   - peerGuid: GUID of the peer who sent the invitation
    ///   - label: Human-readable label for this connection
    ///   - natsCredentials: NATS credentials from the invitation
    ///   - peerOwnerSpaceId: Peer's owner space ID (for receiving their messages)
    ///   - peerMessageSpaceId: Peer's message space ID (for sending to them)
    ///   - peerProfile: Optional peer profile data
    /// - Returns: Stored connection record
    func storeCredentials(
        connectionId: String,
        peerGuid: String,
        label: String,
        natsCredentials: String,
        peerOwnerSpaceId: String,
        peerMessageSpaceId: String,
        peerProfile: [String: String]? = nil
    ) async throws -> NatsConnectionRecord {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "peer_guid": AnyCodableValue(peerGuid),
            "label": AnyCodableValue(label),
            "nats_credentials": AnyCodableValue(natsCredentials),
            "peer_owner_space_id": AnyCodableValue(peerOwnerSpaceId),
            "peer_message_space_id": AnyCodableValue(peerMessageSpaceId)
        ]

        if let peerProfile = peerProfile {
            payload["peer_profile"] = AnyCodableValue(peerProfile)
        }

        #if DEBUG
        print("[ConnectionsClient] storeCredentials: connection_id=\(connectionId), peer_guid=\(peerGuid)")
        print("[ConnectionsClient] storeCredentials: nats_creds_len=\(natsCredentials.count), peer_owner_space=\(peerOwnerSpaceId), peer_msg_space=\(peerMessageSpaceId)")
        #endif

        let response = try await sendAndAwait("connection.store-credentials", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        return Self.parseConnectionRecord(from: result)
    }

    // MARK: - Rotate

    /// Rotate credentials for a connection.
    ///
    /// Generates new NATS credentials for the peer, invalidating old ones.
    /// Use this periodically or after suspected compromise.
    ///
    /// - Parameter connectionId: The connection to rotate
    /// - Returns: Updated connection with new credentials
    func rotate(connectionId: String) async throws -> NatsConnectionRecord {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await sendAndAwait("connection.rotate", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        return Self.parseConnectionRecord(from: result)
    }

    // MARK: - Revoke

    /// Revoke a connection.
    ///
    /// Permanently invalidates the connection credentials. The peer will
    /// no longer be able to send messages to this vault.
    ///
    /// - Parameter connectionId: The connection to revoke
    /// - Returns: Whether the revocation succeeded
    func revoke(connectionId: String) async throws -> Bool {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await sendAndAwait("connection.revoke", payload: payload)

        return response.result?["success"] as? Bool ?? response.success
    }

    /// Cancel an outbound pending invitation (Phase 1.8).
    ///
    /// Used when the inviter changes their mind before the recipient
    /// accepts. The vault tears down the broker entry so the code can
    /// no longer be resolved, and emits a status update so any device
    /// holding a stale `pending` card refreshes.
    ///
    /// Implemented on top of `connection.revoke` — the vault treats a
    /// revoke against a pending-outbound connection the same as a
    /// cancel. Kept as a separate method so the UI can label the
    /// button "Cancel invitation" rather than "Revoke connection".
    func cancelInvitation(connectionId: String) async throws -> Bool {
        return try await revoke(connectionId: connectionId)
    }

    // MARK: - List

    /// List all connections.
    ///
    /// - Parameters:
    ///   - status: Optional filter by status ("active", "revoked", "expired")
    ///   - limit: Maximum number of results (default: 50)
    ///   - cursor: Pagination cursor for next page
    /// - Returns: List of connection records with optional pagination cursor
    func list(
        status: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> NatsConnectionListResult {
        var payload: [String: AnyCodableValue] = [
            "limit": AnyCodableValue(limit)
        ]

        if let status = status {
            payload["status"] = AnyCodableValue(status)
        }
        if let cursor = cursor {
            payload["cursor"] = AnyCodableValue(cursor)
        }

        let response = try await sendAndAwait("connection.list", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        // Backend may use "connections" or "items" as the array key
        let itemsArray = result["connections"] as? [[String: Any]]
            ?? result["items"] as? [[String: Any]]
            ?? []

        let items = itemsArray.map { Self.parseConnectionRecord(from: $0) }

        return NatsConnectionListResult(
            items: items,
            nextCursor: result["next_cursor"] as? String
        )
    }

    // MARK: - Get Credentials

    /// Get credentials for a specific connection.
    ///
    /// Returns the NATS credentials needed to communicate with the peer.
    ///
    /// - Parameter connectionId: The connection ID
    /// - Returns: Connection credentials
    func getCredentials(connectionId: String) async throws -> NatsConnectionCredentials {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await sendAndAwait("connection.get-credentials", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        return NatsConnectionCredentials(
            connectionId: connectionId,
            natsCredentials: result["nats_credentials"] as? String ?? "",
            peerMessageSpaceId: result["peer_message_space_id"] as? String ?? "",
            expiresAt: result["expires_at"] as? String
        )
    }

    // MARK: - Respond

    /// Respond to a pending connection (accept or reject).
    /// Used by the inviter to review and approve/decline the peer.
    ///
    /// - Parameters:
    ///   - connectionId: The connection to respond to
    ///   - response: "accept" or "reject"
    /// - Returns: Updated connection record
    func respond(connectionId: String, response: String) async throws -> NatsConnectionRecord {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "response": AnyCodableValue(response)
        ]

        let vaultResponse = try await sendAndAwait("connection.respond", payload: payload)

        guard let result = vaultResponse.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        return Self.parseConnectionRecord(from: result)
    }

    // MARK: - Resolve Invite

    /// Resolve an invite code via the vault's broker.
    /// The vault fetches the invitation data from the NATS INVITATIONS stream.
    ///
    /// - Parameter inviteCode: The short invite code from QR or deep link
    /// - Returns: Resolved invitation with credentials and space IDs
    func resolveInvite(inviteCode: String) async throws -> NatsResolvedInvitation {
        let payload: [String: AnyCodableValue] = [
            "invite_code": AnyCodableValue(inviteCode)
        ]

        let response = try await sendAndAwait("connection.resolve-invite", payload: payload)

        guard let result = response.result else {
            throw ConnectionsClientError.invalidResponse("No result in response")
        }

        // Reconstruct .creds format from JWT + seed if provided separately
        let jwt = result["jwt"] as? String ?? ""
        let seed = result["seed"] as? String ?? ""
        let natsCredentials: String
        if !jwt.isEmpty && !seed.isEmpty {
            natsCredentials = """
            -----BEGIN NATS USER JWT-----
            \(jwt)
            ------END NATS USER JWT------

            -----BEGIN USER NKEY SEED-----
            \(seed)
            ------END USER NKEY SEED------
            """
        } else {
            natsCredentials = ""
        }

        return NatsResolvedInvitation(
            connectionId: result["connection_id"] as? String ?? "",
            natsCredentials: natsCredentials,
            ownerSpaceId: result["owner_space"] as? String ?? "",
            messageSpaceId: result["message_space"] as? String ?? "",
            expiresAt: result["expires_at"] as? String ?? "",
            label: result["label"] as? String ?? ""
        )
    }

    // MARK: - Private Helpers

    /// Send a request using OwnerSpaceClient.sendAndAwaitResponse() for proper
    /// request-response correlation by event_id.
    private func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[ConnectionsClient] Sending \(messageType) request via OwnerSpaceClient")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout
        )

        guard response.success else {
            let error = response.error ?? "Request failed"
            #if DEBUG
            print("[ConnectionsClient] \(messageType) failed: \(error)")
            #endif
            throw ConnectionsClientError.requestFailed(
                messageType: messageType,
                error: error,
                errorCode: response.errorCode
            )
        }

        #if DEBUG
        print("[ConnectionsClient] \(messageType) response received")
        #endif

        return response
    }

    /// Parse a connection record from a vault response dictionary.
    static func parseConnectionRecord(from dict: [String: Any]) -> NatsConnectionRecord {
        let peerProfile: PeerProfileData?
        if let profileDict = dict["peer_profile"] as? [String: Any] {
            let fields: [String: [String: String]]?
            if let fieldsDict = profileDict["fields"] as? [String: Any] {
                var parsed: [String: [String: String]] = [:]
                for (key, value) in fieldsDict {
                    if let fieldObj = value as? [String: Any] {
                        parsed[key] = [
                            "display_name": fieldObj["display_name"] as? String ?? key,
                            "value": fieldObj["value"] as? String ?? ""
                        ]
                    }
                }
                fields = parsed
            } else {
                fields = nil
            }

            // Parse wallet previews from profile
            var wallets: [WalletPreview]?
            if let walletsArray = profileDict["wallets"] as? [[String: Any]] {
                wallets = walletsArray.compactMap { w in
                    guard let address = w["address"] as? String else { return nil }
                    return WalletPreview(
                        label: w["label"] as? String ?? "",
                        address: address,
                        network: w["network"] as? String ?? "unknown"
                    )
                }
            }

            peerProfile = PeerProfileData(
                firstName: profileDict["_system_first_name"] as? String,
                lastName: profileDict["_system_last_name"] as? String,
                email: profileDict["_system_email"] as? String,
                photo: profileDict["photo"] as? String,
                publicKey: profileDict["public_key"] as? String ?? profileDict["e2e_public_key"] as? String,
                fields: fields,
                wallets: wallets
            )
        } else {
            peerProfile = nil
        }

        return NatsConnectionRecord(
            connectionId: dict["connection_id"] as? String ?? "",
            peerGuid: dict["peer_guid"] as? String ?? "",
            label: dict["label"] as? String ?? dict["peer_alias"] as? String ?? "",
            status: dict["status"] as? String ?? "unknown",
            direction: dict["direction"] as? String ?? dict["credentials_type"] as? String ?? "unknown",
            connectionType: dict["connection_type"] as? String ?? "peer",
            createdAt: dict["created_at"] as? String ?? "",
            expiresAt: dict["expires_at"] as? String,
            lastRotatedAt: dict["last_rotated_at"] as? String,
            e2ePublicKey: dict["e2e_public_key"] as? String,
            peerProfile: peerProfile
        )
    }
}

// MARK: - Data Models

/// Invitation to connect with a peer.
struct NatsConnectionInvitation {
    let connectionId: String
    let peerGuid: String
    let label: String
    let natsCredentials: String   // NATS .creds file content
    let ownerSpaceId: String
    let messageSpaceId: String
    let expiresAt: String
    let inviterProfile: [String: String]
    let inviteCode: String        // Short code for QR broker lookup
}

/// Stored connection record from vault.
struct NatsConnectionRecord {
    let connectionId: String
    let peerGuid: String
    let label: String
    let status: String            // "active", "pending", "revoked", "expired"
    let direction: String         // "outbound" (we invited) or "inbound" (they invited us)
    let connectionType: String    // "peer", "agent", "device"
    let createdAt: String
    let expiresAt: String?
    let lastRotatedAt: String?
    let e2ePublicKey: String?
    let peerProfile: PeerProfileData?
}

/// Cached peer profile data from the vault.
struct PeerProfileData: Codable, Equatable {
    let firstName: String?
    let lastName: String?
    let email: String?
    let photo: String?
    let publicKey: String?
    let fields: [String: [String: String]]?
    let wallets: [WalletPreview]?

    /// Display name built from first and last name
    var displayName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    /// Profile fields excluding system-prefixed fields
    var visibleFields: [String: [String: String]]? {
        fields?.filter { !$0.key.hasPrefix("_system_") }
    }

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case photo
        case publicKey = "public_key"
        case fields
        case wallets
    }
}

/// Preview of a wallet address from a peer's published profile.
struct WalletPreview: Codable, Equatable, Identifiable {
    let label: String
    let address: String
    let network: String

    var id: String { "\(network):\(address)" }

    var truncatedAddress: String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}

/// Rich peer profile preview for connection review screens.
struct PeerProfilePreview {
    let displayName: String
    let email: String?
    let photoBase64: String?
    let publicKey: String?
    let wallets: [WalletPreview]
    let profileFields: [String: [String: String]]?

    init(from profile: PeerProfileData) {
        self.displayName = profile.displayName
        self.email = profile.email
        self.photoBase64 = profile.photo
        self.publicKey = profile.publicKey
        self.wallets = profile.wallets ?? []
        self.profileFields = profile.visibleFields
    }
}

/// Connection list result with pagination.
struct NatsConnectionListResult {
    let items: [NatsConnectionRecord]
    let nextCursor: String?
}

/// Connection credentials for peer communication.
struct NatsConnectionCredentials {
    let connectionId: String
    let natsCredentials: String   // NATS .creds file content
    let peerMessageSpaceId: String
    let expiresAt: String?
}

/// Resolved invitation data from the broker.
struct NatsResolvedInvitation {
    let connectionId: String
    let natsCredentials: String
    let ownerSpaceId: String
    let messageSpaceId: String
    let expiresAt: String
    let label: String
}

// MARK: - Errors

enum ConnectionsClientError: LocalizedError {
    case requestFailed(messageType: String, error: String, errorCode: String?)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let messageType, let error, let errorCode):
            if let code = errorCode {
                return "Connection request '\(messageType)' failed [\(code)]: \(error)"
            }
            return "Connection request '\(messageType)' failed: \(error)"
        case .invalidResponse(let reason):
            return "Invalid connection response: \(reason)"
        }
    }
}
