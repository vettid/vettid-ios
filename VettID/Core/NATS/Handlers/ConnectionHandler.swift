import Foundation

/// Handler for vault connection operations via NATS
///
/// Manages peer connections including invitations, key storage, rotation, and revocation.
/// All connection cryptographic material is stored securely in the vault.
///
/// NATS Topics:
/// - `connection.invite.create` - Create connection invitation
/// - `connection.credentials.store` - Store peer credentials
/// - `connection.rotate` - Rotate connection keys
/// - `connection.revoke` - Revoke a connection
/// - `connection.list` - List all connections
/// - `connection.get` - Get connection details
actor ConnectionHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Invitation Operations

    /// Create a connection invitation
    /// - Parameters:
    ///   - expiresInMinutes: Invitation validity period
    ///   - label: Optional label for the connection
    /// - Returns: Invitation details including code
    func createInvite(
        expiresInMinutes: Int = 60,
        label: String? = nil
    ) async throws -> ConnectionInviteResult {
        var payload: [String: AnyCodableValue] = [
            "expires_in_minutes": AnyCodableValue(expiresInMinutes)
        ]

        if let label = label {
            payload["label"] = AnyCodableValue(label)
        }

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.invite.create",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.inviteCreationFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let code = result["code"]?.value as? String else {
            throw ConnectionHandlerError.invalidResponse
        }

        return ConnectionInviteResult(
            code: code,
            publicKey: result["public_key"]?.value as? String,
            expiresAt: (result["expires_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    // MARK: - Credential Storage

    /// Store connection credentials for a peer
    /// - Parameters:
    ///   - peerId: Peer's connection ID
    ///   - credentials: Encrypted credentials data
    /// - Returns: Response indicating success/failure
    func storeConnectionCredentials(
        peerId: String,
        credentials: Data
    ) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "peer_id": AnyCodableValue(peerId),
            "credentials": AnyCodableValue(credentials.base64EncodedString())
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.credentials.store",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Retrieve connection credentials for a peer
    /// - Parameter peerId: Peer's connection ID
    /// - Returns: Connection credential data
    func getConnectionCredentials(peerId: String) async throws -> ConnectionCredentials {
        let payload: [String: AnyCodableValue] = [
            "peer_id": AnyCodableValue(peerId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.credentials.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.credentialRetrievalFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ConnectionHandlerError.invalidResponse
        }

        return ConnectionCredentials(
            peerId: peerId,
            publicKey: result["public_key"]?.value as? String,
            sharedSecret: (result["shared_secret"]?.value as? String).flatMap { Data(base64Encoded: $0) },
            createdAt: (result["created_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    // MARK: - Connection Management

    /// Rotate keys for a connection
    /// - Parameter connectionId: Connection to rotate
    /// - Returns: New public key for the connection
    func rotateConnection(connectionId: String) async throws -> ConnectionRotationResult {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.rotate",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.rotationFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ConnectionHandlerError.invalidResponse
        }

        return ConnectionRotationResult(
            connectionId: connectionId,
            newPublicKey: result["new_public_key"]?.value as? String,
            rotatedAt: Date()
        )
    }

    /// Revoke a connection
    /// - Parameter connectionId: Connection to revoke
    /// - Returns: Response indicating success/failure
    func revokeConnection(connectionId: String) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.revoke",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// List all connections
    /// - Parameter includeRevoked: Whether to include revoked connections
    /// - Returns: List of connection information
    func listConnections(includeRevoked: Bool = false) async throws -> [VaultConnectionInfo] {
        let payload: [String: AnyCodableValue] = [
            "include_revoked": AnyCodableValue(includeRevoked)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.listFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let connectionsArray = result["connections"]?.value as? [[String: Any]] else {
            return []
        }

        return connectionsArray.compactMap { dict -> VaultConnectionInfo? in
            guard let id = dict["id"] as? String else { return nil }
            return VaultConnectionInfo(
                id: id,
                label: dict["label"] as? String,
                peerDisplayName: dict["peer_display_name"] as? String,
                status: ConnectionStatus(rawValue: dict["status"] as? String ?? "") ?? .active,
                createdAt: (dict["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                lastActivityAt: (dict["last_activity_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }
    }

    /// Get details for a specific connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Detailed connection information
    func getConnection(connectionId: String) async throws -> VaultConnectionDetails {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.getFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ConnectionHandlerError.invalidResponse
        }

        return VaultConnectionDetails(
            id: connectionId,
            label: result["label"]?.value as? String,
            peerDisplayName: result["peer_display_name"]?.value as? String,
            peerPublicKey: result["peer_public_key"]?.value as? String,
            status: ConnectionStatus(rawValue: result["status"]?.value as? String ?? "") ?? .active,
            createdAt: (result["created_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            lastActivityAt: (result["last_activity_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            messageCount: result["message_count"]?.value as? Int ?? 0,
            sharedData: result["shared_data"]?.value as? [String: String] ?? [:]
        )
    }

    /// Accept a connection invitation
    /// - Parameters:
    ///   - code: Invitation code
    ///   - label: Optional label for the connection
    /// - Returns: Connection acceptance result
    func acceptInvitation(
        code: String,
        label: String? = nil
    ) async throws -> ConnectionAcceptResult {
        var payload: [String: AnyCodableValue] = [
            "code": AnyCodableValue(code)
        ]

        if let label = label {
            payload["label"] = AnyCodableValue(label)
        }

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.invite.accept",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ConnectionHandlerError.acceptFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let connectionId = result["connection_id"]?.value as? String else {
            throw ConnectionHandlerError.invalidResponse
        }

        return ConnectionAcceptResult(
            connectionId: connectionId,
            peerDisplayName: result["peer_display_name"]?.value as? String,
            peerPublicKey: result["peer_public_key"]?.value as? String
        )
    }
}

// MARK: - Supporting Types

/// Result from creating an invitation
struct ConnectionInviteResult {
    let code: String
    let publicKey: String?
    let expiresAt: Date?
}

/// Stored connection credentials
struct ConnectionCredentials {
    let peerId: String
    let publicKey: String?
    let sharedSecret: Data?
    let createdAt: Date?
}

/// Result from key rotation
struct ConnectionRotationResult {
    let connectionId: String
    let newPublicKey: String?
    let rotatedAt: Date
}

/// Basic connection information from vault NATS handler
struct VaultConnectionInfo: Identifiable {
    let id: String
    let label: String?
    let peerDisplayName: String?
    let status: ConnectionStatus
    let createdAt: Date?
    let lastActivityAt: Date?
}

/// Detailed connection information from vault NATS handler
struct VaultConnectionDetails {
    let id: String
    let label: String?
    let peerDisplayName: String?
    let peerPublicKey: String?
    let status: ConnectionStatus
    let createdAt: Date?
    let lastActivityAt: Date?
    let messageCount: Int
    let sharedData: [String: String]
}

/// Result from accepting an invitation
struct ConnectionAcceptResult {
    let connectionId: String
    let peerDisplayName: String?
    let peerPublicKey: String?
}

// MARK: - Errors

enum ConnectionHandlerError: LocalizedError {
    case inviteCreationFailed(String)
    case credentialRetrievalFailed(String)
    case rotationFailed(String)
    case revocationFailed(String)
    case listFailed(String)
    case getFailed(String)
    case acceptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .inviteCreationFailed(let reason):
            return "Failed to create invitation: \(reason)"
        case .credentialRetrievalFailed(let reason):
            return "Failed to retrieve credentials: \(reason)"
        case .rotationFailed(let reason):
            return "Failed to rotate connection: \(reason)"
        case .revocationFailed(let reason):
            return "Failed to revoke connection: \(reason)"
        case .listFailed(let reason):
            return "Failed to list connections: \(reason)"
        case .getFailed(let reason):
            return "Failed to get connection: \(reason)"
        case .acceptFailed(let reason):
            return "Failed to accept invitation: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        }
    }
}
