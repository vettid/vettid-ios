import Foundation

/// HTTP client for communicating with the VettID Ledger Service
actor APIClient {

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://api.vettid.com")!) {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Enrollment (Multi-Step)

    /// Step 1: Start enrollment with invitation code
    func enrollStart(request: EnrollStartRequest) async throws -> EnrollStartResponse {
        return try await post(endpoint: "/api/v1/enroll/start", body: request)
    }

    /// Step 2: Set password during enrollment
    func enrollSetPassword(request: EnrollSetPasswordRequest) async throws -> EnrollSetPasswordResponse {
        return try await post(endpoint: "/api/v1/enroll/set-password", body: request)
    }

    /// Step 3: Finalize enrollment and receive credential
    func enrollFinalize(request: EnrollFinalizeRequest) async throws -> EnrollFinalizeResponse {
        return try await post(endpoint: "/api/v1/enroll/finalize", body: request)
    }

    // MARK: - Authentication (Action-Based)

    /// Step 1: Request scoped action token
    func actionRequest(request: ActionRequestBody, cognitoToken: String) async throws -> ActionRequestResponse {
        return try await post(endpoint: "/api/v1/action/request", body: request, authToken: cognitoToken)
    }

    /// Step 2: Execute authentication with action token
    func authExecute(request: AuthExecuteRequest, actionToken: String) async throws -> AuthExecuteResponse {
        return try await post(endpoint: "/api/v1/auth/execute", body: request, authToken: actionToken)
    }

    // MARK: - Vault Operations (Phase 5 - Not Yet Deployed)

    /// Get current vault status
    func getVaultStatus(vaultId: String, authToken: String) async throws -> VaultStatusResponse {
        return try await get(endpoint: "/member/vaults/\(vaultId)/status", authToken: authToken)
    }

    /// Start vault
    func startVault(vaultId: String, authToken: String) async throws -> VaultActionResponse {
        return try await post(endpoint: "/member/vaults/\(vaultId)/start", body: EmptyBody(), authToken: authToken)
    }

    /// Stop vault
    func stopVault(vaultId: String, authToken: String) async throws -> VaultActionResponse {
        return try await post(endpoint: "/member/vaults/\(vaultId)/stop", body: EmptyBody(), authToken: authToken)
    }

    // MARK: - Vault Lifecycle (Phase 5)

    /// Provision a new vault EC2 instance
    func provisionVault(authToken: String) async throws -> ProvisionVaultResponse {
        return try await post(endpoint: "/vault/provision", body: EmptyBody(), authToken: authToken)
    }

    /// Initialize vault after EC2 is running
    func initializeVault(authToken: String) async throws -> InitializeVaultResponse {
        return try await post(endpoint: "/vault/initialize", body: EmptyBody(), authToken: authToken)
    }

    /// Stop vault (preserve state)
    func stopVaultInstance(authToken: String) async throws -> VaultLifecycleResponse {
        return try await post(endpoint: "/vault/stop", body: EmptyBody(), authToken: authToken)
    }

    /// Terminate vault (cleanup)
    func terminateVault(authToken: String) async throws -> VaultLifecycleResponse {
        return try await post(endpoint: "/vault/terminate", body: EmptyBody(), authToken: authToken)
    }

    /// Get vault health status
    func getVaultHealth(authToken: String) async throws -> VaultHealthResponse {
        return try await get(endpoint: "/vault/health", authToken: authToken)
    }

    // MARK: - NATS Operations (Phase 4)

    /// Create NATS account for the user
    func createNatsAccount(authToken: String) async throws -> NatsAccountResponse {
        return try await post(endpoint: "/vault/nats/account", body: EmptyBody(), authToken: authToken)
    }

    /// Generate NATS token for app or vault
    func generateNatsToken(request: NatsTokenRequest, authToken: String) async throws -> NatsTokenResponse {
        return try await post(endpoint: "/vault/nats/token", body: request, authToken: authToken)
    }

    /// Get NATS account status
    func getNatsStatus(authToken: String) async throws -> NatsStatusResponse {
        return try await get(endpoint: "/vault/nats/status", authToken: authToken)
    }

    // MARK: - Handler Registry (Phase 6)

    /// List available handlers from registry
    func listHandlers(
        category: String? = nil,
        page: Int = 1,
        limit: Int = 20,
        authToken: String
    ) async throws -> HandlerListResponse {
        var endpoint = "/registry/handlers?page=\(page)&limit=\(limit)"
        if let category = category {
            endpoint += "&category=\(category)"
        }
        return try await get(endpoint: endpoint, authToken: authToken)
    }

    /// Get handler details
    func getHandler(id: String, authToken: String) async throws -> HandlerDetailResponse {
        return try await get(endpoint: "/registry/handlers/\(id)", authToken: authToken)
    }

    // MARK: - Handler Management (Phase 6)

    /// Install handler on vault
    func installHandler(
        handlerId: String,
        version: String,
        authToken: String
    ) async throws -> InstallHandlerResponse {
        let request = InstallHandlerRequest(handlerId: handlerId, version: version)
        return try await post(endpoint: "/vault/handlers/install", body: request, authToken: authToken)
    }

    /// Uninstall handler from vault
    func uninstallHandler(handlerId: String, authToken: String) async throws -> UninstallHandlerResponse {
        let request = UninstallHandlerRequest(handlerId: handlerId)
        return try await post(endpoint: "/vault/handlers/uninstall", body: request, authToken: authToken)
    }

    /// List installed handlers on vault
    func listInstalledHandlers(authToken: String) async throws -> InstalledHandlersResponse {
        return try await get(endpoint: "/vault/handlers", authToken: authToken)
    }

    /// Execute handler with input
    func executeHandler(
        handlerId: String,
        input: [String: AnyCodableValue],
        timeoutMs: Int = 30000,
        authToken: String
    ) async throws -> ExecuteHandlerResponse {
        let request = HandlerExecutionRequest(input: input, timeoutMs: timeoutMs)
        return try await post(endpoint: "/vault/handlers/\(handlerId)/execute", body: request, authToken: authToken)
    }

    // MARK: - Connections (Phase 7)

    /// Create a connection invitation
    func createInvitation(
        expiresInMinutes: Int = 60,
        publicKey: Data,
        authToken: String
    ) async throws -> ConnectionInvitation {
        let request = CreateInvitationRequest(
            expiresInMinutes: expiresInMinutes,
            publicKey: publicKey.base64EncodedString()
        )
        return try await post(endpoint: "/connections/invite", body: request, authToken: authToken)
    }

    /// Accept a connection invitation
    func acceptInvitation(
        code: String,
        publicKey: Data,
        authToken: String
    ) async throws -> AcceptInvitationResponse {
        let request = AcceptInvitationRequest(
            code: code,
            publicKey: publicKey.base64EncodedString()
        )
        return try await post(endpoint: "/connections/accept", body: request, authToken: authToken)
    }

    /// Revoke a connection
    func revokeConnection(connectionId: String, authToken: String) async throws {
        let request = RevokeConnectionRequest(connectionId: connectionId)
        let _: EmptyResponse = try await post(endpoint: "/connections/revoke", body: request, authToken: authToken)
    }

    /// List all connections
    func listConnections(authToken: String) async throws -> [Connection] {
        let response: ConnectionListResponse = try await get(endpoint: "/connections", authToken: authToken)
        return response.connections
    }

    /// Get connection details
    func getConnection(id: String, authToken: String) async throws -> Connection {
        return try await get(endpoint: "/connections/\(id)", authToken: authToken)
    }

    /// Get connection's profile
    func getConnectionProfile(connectionId: String, authToken: String) async throws -> Profile {
        let response: ProfileResponse = try await get(endpoint: "/connections/\(connectionId)/profile", authToken: authToken)
        return response.profile
    }

    // MARK: - Profiles (Phase 7)

    /// Get own profile
    func getProfile(authToken: String) async throws -> Profile {
        let response: ProfileResponse = try await get(endpoint: "/profile", authToken: authToken)
        return response.profile
    }

    /// Update own profile
    func updateProfile(_ profile: Profile, authToken: String) async throws -> Profile {
        let request = UpdateProfileRequest(
            displayName: profile.displayName,
            bio: profile.bio,
            location: profile.location
        )
        let response: ProfileResponse = try await put(endpoint: "/profile", body: request, authToken: authToken)
        return response.profile
    }

    /// Publish profile to connections
    func publishProfile(authToken: String) async throws {
        let _: EmptyResponse = try await post(endpoint: "/profile/publish", body: EmptyRequest(), authToken: authToken)
    }

    // MARK: - Messaging (Phase 7)

    /// Send an encrypted message
    func sendMessage(
        connectionId: String,
        encryptedContent: Data,
        nonce: Data,
        contentType: MessageContentType = .text,
        authToken: String
    ) async throws -> Message {
        let request = SendMessageRequest(
            connectionId: connectionId,
            encryptedContent: encryptedContent.base64EncodedString(),
            nonce: nonce.base64EncodedString(),
            contentType: contentType.rawValue
        )
        return try await post(endpoint: "/messages/send", body: request, authToken: authToken)
    }

    /// Get message history for a connection
    func getMessageHistory(
        connectionId: String,
        limit: Int = 50,
        before: Date? = nil,
        authToken: String
    ) async throws -> [Message] {
        var endpoint = "/messages/\(connectionId)?limit=\(limit)"
        if let before = before {
            let formatter = ISO8601DateFormatter()
            endpoint += "&before=\(formatter.string(from: before))"
        }
        let response: MessageHistoryResponse = try await get(endpoint: endpoint, authToken: authToken)
        return response.messages
    }

    /// Get unread message counts
    func getUnreadCount(authToken: String) async throws -> [String: Int] {
        let response: UnreadCountResponse = try await get(endpoint: "/messages/unread", authToken: authToken)
        return response.counts
    }

    /// Mark a message as read
    func markAsRead(messageId: String, authToken: String) async throws {
        let _: EmptyResponse = try await post(endpoint: "/messages/\(messageId)/read", body: EmptyRequest(), authToken: authToken)
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(endpoint: String, authToken: String? = nil) async throws -> T {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func post<T: Encodable, R: Decodable>(
        endpoint: String,
        body: T,
        authToken: String? = nil
    ) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func put<T: Encodable, R: Decodable>(
        endpoint: String,
        body: T,
        authToken: String? = nil
    ) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.serverError(httpResponse.statusCode, errorResponse.message)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}

// MARK: - Enrollment Request/Response Types

struct EnrollStartRequest: Encodable {
    let invitationCode: String
    let deviceId: String
    let attestationData: String  // Base64 encoded
}

struct EnrollStartResponse: Decodable {
    let enrollmentSessionId: String
    let userGuid: String
    let transactionKeys: [TransactionKeyInfo]
    let passwordPrompt: PasswordPrompt
}

struct TransactionKeyInfo: Codable {
    let keyId: String
    let publicKey: String  // Base64 encoded X25519 public key
    let algorithm: String
}

struct PasswordPrompt: Decodable {
    let useKeyId: String
    let message: String
}

struct EnrollSetPasswordRequest: Encodable {
    let enrollmentSessionId: String
    let encryptedPasswordHash: String  // Base64 encoded
    let keyId: String
    let nonce: String  // Base64 encoded 96-bit nonce
}

struct EnrollSetPasswordResponse: Decodable {
    let status: String
    let nextStep: String
}

struct EnrollFinalizeRequest: Encodable {
    let enrollmentSessionId: String
}

struct EnrollFinalizeResponse: Decodable {
    let status: String
    let credentialPackage: CredentialPackage
    let vaultStatus: String
}

struct CredentialPackage: Codable {
    let userGuid: String
    let encryptedBlob: String  // Base64 encoded
    let cekVersion: Int
    let ledgerAuthToken: LedgerAuthToken
    let transactionKeys: [TransactionKeyInfo]?
    let newTransactionKeys: [TransactionKeyInfo]?
}

struct LedgerAuthToken: Codable {
    let latId: String
    let token: String  // Hex encoded
    let version: Int
}

// MARK: - Authentication Request/Response Types

struct ActionRequestBody: Encodable {
    let userGuid: String
    let actionType: String
    let deviceFingerprint: String?
}

struct ActionRequestResponse: Decodable {
    let actionToken: String  // JWT scoped to specific endpoint
    let actionTokenExpiresAt: String
    let ledgerAuthToken: LedgerAuthToken
    let actionEndpoint: String
    let useKeyId: String
}

struct AuthExecuteRequest: Encodable {
    let encryptedBlob: String  // Base64 encoded
    let cekVersion: Int
    let encryptedPasswordHash: String  // Base64 encoded
    let ephemeralPublicKey: String  // Base64 encoded X25519 public key
    let nonce: String  // Base64 encoded
    let keyId: String
}

struct AuthExecuteResponse: Decodable {
    let status: String
    let actionResult: ActionResult
    let credentialPackage: CredentialPackage
    let usedKeyId: String
}

struct ActionResult: Decodable {
    let authenticated: Bool
    let message: String
    let timestamp: String
}

// MARK: - Vault Types

struct VaultStatusResponse: Decodable {
    let vaultId: String
    let status: String
    let instanceId: String?
    let publicIP: String?
    let lastHeartbeat: Date?
}

struct VaultActionResponse: Decodable {
    let success: Bool
    let message: String
}

// MARK: - Vault Lifecycle Types (Phase 5)

struct ProvisionVaultResponse: Decodable {
    let instanceId: String
    let status: String  // "provisioning", "running", "failed"
    let region: String
    let availabilityZone: String
    let privateIp: String?
    let estimatedReadyAt: String
}

struct InitializeVaultResponse: Decodable {
    let status: String  // "initialized", "failed"
    let localNatsStatus: String
    let centralNatsStatus: String
    let ownerSpaceId: String
    let messageSpaceId: String
}

struct VaultLifecycleResponse: Decodable {
    let status: String
    let message: String
}

struct VaultHealthResponse: Decodable {
    let status: String  // "healthy", "unhealthy", "degraded"
    let uptimeSeconds: Int
    let localNats: LocalNatsHealth
    let centralNats: CentralNatsHealth
    let vaultManager: VaultManagerHealth
    let lastEventAt: String?
}

struct LocalNatsHealth: Decodable {
    let status: String
    let connections: Int
}

struct CentralNatsHealth: Decodable {
    let status: String
    let latencyMs: Int
}

struct VaultManagerHealth: Decodable {
    let status: String
    let memoryMb: Int
    let cpuPercent: Float
    let handlersLoaded: Int
}

struct EmptyBody: Encodable {}

// MARK: - Error Types

struct APIErrorResponse: Decodable {
    let message: String
    let code: String?
}

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case serverError(Int, String)
    case decodingFailed(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Action Types

enum ActionType: String, Encodable {
    case authenticate
    case addSecret = "add_secret"
    case retrieveSecret = "retrieve_secret"
    case addPolicy = "add_policy"
    case modifyCredential = "modify_credential"
}

// MARK: - Handler Registry Types (Phase 6)

struct HandlerListResponse: Decodable {
    let handlers: [HandlerSummary]
    let total: Int
    let page: Int
    let hasMore: Bool
}

struct HandlerSummary: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    let category: String
    let iconUrl: String?
    let publisher: String
    let installed: Bool
    let installedVersion: String?
}

struct HandlerDetailResponse: Codable {
    let id: String
    let name: String
    let description: String
    let version: String
    let category: String
    let iconUrl: String?
    let publisher: String
    let publishedAt: String
    let sizeBytes: Int
    let permissions: [HandlerPermission]
    let inputSchema: [String: AnyCodableValue]
    let outputSchema: [String: AnyCodableValue]
    let changelog: String?
    let installed: Bool
    let installedVersion: String?
}

struct HandlerPermission: Codable, Equatable {
    let type: String      // "network", "storage", "crypto"
    let scope: String     // e.g., "api.example.com" for network
    let description: String
}

// MARK: - Handler Management Types (Phase 6)

struct InstallHandlerRequest: Encodable {
    let handlerId: String
    let version: String
}

struct InstallHandlerResponse: Decodable {
    let status: String      // "installed", "failed"
    let handlerId: String
    let version: String
    let installedAt: String?
}

struct UninstallHandlerRequest: Encodable {
    let handlerId: String
}

struct UninstallHandlerResponse: Decodable {
    let status: String      // "uninstalled", "failed"
    let handlerId: String
}

struct InstalledHandlersResponse: Decodable {
    let handlers: [InstalledHandler]
}

struct InstalledHandler: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let installedAt: String
    let lastExecutedAt: String?
    let executionCount: Int
}

struct HandlerExecutionRequest: Encodable {
    let input: [String: AnyCodableValue]
    let timeoutMs: Int
}

struct ExecuteHandlerResponse: Decodable {
    let requestId: String
    let status: String      // "success", "error", "timeout"
    let output: [String: AnyCodableValue]?
    let error: String?
    let executionTimeMs: Int
}

// MARK: - Helper Types (Phase 7)

/// Empty request body for endpoints that don't need one
struct EmptyRequest: Encodable {}

/// Empty response for endpoints that return no body
struct EmptyResponse: Decodable {}
