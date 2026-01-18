import Foundation
import CryptoKit
import UIKit

/// HTTP client for communicating with the VettID Ledger Service
/// Security hardened with certificate pinning, request signing, and replay protection
actor APIClient {

    private let baseURL: URL
    private let session: URLSession
    private let pinningDelegate: CertificatePinningDelegate
    private var requestSigner: RequestSigner?

    /// Device ID for request signing
    private let deviceId: String

    // MARK: - Initialization

    init(
        baseURL: URL = URL(string: "https://api.vettid.dev")!,
        deviceId: String? = nil
    ) {
        // Get device ID synchronously - use provided value or generate UUID
        // Note: UIDevice.current.identifierForVendor requires MainActor, so we use a fallback
        let resolvedDeviceId = deviceId ?? UUID().uuidString
        self.baseURL = baseURL
        self.deviceId = resolvedDeviceId

        // SECURITY: Certificate pinning is ALWAYS enforced.
        // For local development with proxy tools (Charles, Proxyman):
        // - Install the proxy CA certificate on the device/simulator
        // - The proxy will present a valid certificate chain
        // DO NOT add parameters to disable pinning - this is a security risk.
        self.pinningDelegate = CertificatePinningDelegate()

        // Configure URLSession with pinning delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        // Security: Disable URL caching for sensitive requests
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Security: Disable cookies (we use Bearer tokens)
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false

        // Create session with pinning delegate
        self.session = URLSession(
            configuration: config,
            delegate: pinningDelegate,
            delegateQueue: nil
        )

        // Initialize request signer
        self.requestSigner = RequestSigner(deviceId: resolvedDeviceId)

        // Set up pin validation failure handler
        pinningDelegate.onPinValidationFailed = { host, reason in
            // Log security event (in production, send to security monitoring)
            #if DEBUG
            print("SECURITY WARNING: Certificate pinning failed for \(host): \(reason)")
            #endif
            // Could trigger security alert here
        }
    }

    // MARK: - Security Configuration

    /// Signing key for authenticated requests (optional)
    private var signingKey: SymmetricKey?

    /// Whether to sign requests (enabled after configureSigningKey is called)
    private var signRequestsEnabled: Bool = false

    /// Configure signing key for authenticated requests
    /// Call this after user authenticates to enable request signing
    /// - Parameter key: Master key from which signing key will be derived
    func configureSigningKey(_ key: SymmetricKey) {
        // Derive signing key from master key using HKDF
        self.signingKey = RequestSigner.deriveSigningKey(from: key)
        self.signRequestsEnabled = true
        #if DEBUG
        print("[APIClient] Request signing enabled")
        #endif
    }

    /// Disable request signing (call on logout)
    func disableRequestSigning() {
        self.signingKey = nil
        self.signRequestsEnabled = false
    }

    /// Check if request signing is enabled
    var isRequestSigningEnabled: Bool {
        return signRequestsEnabled && signingKey != nil
    }

    // MARK: - Enrollment (Multi-Step)

    /// Step 0: Authenticate with session_token to get enrollment JWT
    /// This is a PUBLIC endpoint - no Authorization header needed
    func enrollAuthenticate(request: EnrollAuthenticateRequest) async throws -> EnrollAuthenticateResponse {
        return try await post(endpoint: "/vault/enroll/authenticate", body: request)
    }

    /// Step 1: Start enrollment (requires enrollment JWT from authenticate)
    func enrollStart(request: EnrollStartRequest, authToken: String) async throws -> EnrollStartResponse {
        return try await post(endpoint: "/vault/enroll/start", body: request, authToken: authToken)
    }

    /// Step 1b: Submit iOS device attestation
    func enrollAttestationIOS(request: EnrollAttestationIOSRequest, authToken: String) async throws -> EnrollAttestationResponse {
        return try await post(endpoint: "/vault/enroll/attestation/ios", body: request, authToken: authToken)
    }

    /// Step 2: Set password during enrollment (requires enrollment JWT)
    func enrollSetPassword(request: EnrollSetPasswordRequest, authToken: String) async throws -> EnrollSetPasswordResponse {
        return try await post(endpoint: "/vault/enroll/set-password", body: request, authToken: authToken)
    }

    /// Step 2b: Set vault PIN for DEK binding (Architecture v2.0 Section 5.7)
    /// The PIN is encrypted to the enclave's attestation-bound public key.
    func enrollSetPIN(request: EnrollSetPINRequest, authToken: String) async throws -> EnrollSetPINResponse {
        return try await post(endpoint: "/vault/enroll/set-pin", body: request, authToken: authToken)
    }

    /// Step 3: Finalize enrollment and receive credential (requires enrollment JWT)
    func enrollFinalize(request: EnrollFinalizeRequest, authToken: String) async throws -> EnrollFinalizeResponse {
        return try await post(endpoint: "/vault/enroll/finalize", body: request, authToken: authToken)
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

    // MARK: - Action-Token Vault Lifecycle

    /// Get vault status using action token authentication
    /// Flow: 1) Call actionRequest with vaultStatus, 2) Call this with the action token
    func getVaultStatusWithActionToken(actionToken: String) async throws -> ActionVaultStatusResponse {
        return try await get(endpoint: "/api/v1/vault/status", authToken: actionToken)
    }

    /// Start vault using action token authentication
    /// Flow: 1) Call actionRequest with vaultStart, 2) Call this with the action token
    func startVaultWithActionToken(actionToken: String) async throws -> ActionVaultStartResponse {
        return try await post(endpoint: "/api/v1/vault/start", body: EmptyBody(), authToken: actionToken)
    }

    /// Stop vault using action token authentication
    /// Flow: 1) Call actionRequest with vaultStop, 2) Call this with the action token
    func stopVaultWithActionToken(actionToken: String) async throws -> ActionVaultStopResponse {
        return try await post(endpoint: "/api/v1/vault/stop", body: EmptyBody(), authToken: actionToken)
    }

    /// Helper: Request action token and get vault status in one call
    func getVaultStatusAction(userGuid: String, cognitoToken: String) async throws -> ActionVaultStatusResponse {
        let actionResponse = try await actionRequest(
            request: ActionRequestBody(
                userGuid: userGuid,
                actionType: ActionType.vaultStatus.rawValue,
                deviceFingerprint: nil
            ),
            cognitoToken: cognitoToken
        )
        return try await getVaultStatusWithActionToken(actionToken: actionResponse.actionToken)
    }

    /// Helper: Request action token and start vault in one call
    func startVaultAction(userGuid: String, cognitoToken: String) async throws -> ActionVaultStartResponse {
        let actionResponse = try await actionRequest(
            request: ActionRequestBody(
                userGuid: userGuid,
                actionType: ActionType.vaultStart.rawValue,
                deviceFingerprint: nil
            ),
            cognitoToken: cognitoToken
        )
        return try await startVaultWithActionToken(actionToken: actionResponse.actionToken)
    }

    /// Helper: Request action token and stop vault in one call
    func stopVaultAction(userGuid: String, cognitoToken: String) async throws -> ActionVaultStopResponse {
        let actionResponse = try await actionRequest(
            request: ActionRequestBody(
                userGuid: userGuid,
                actionType: ActionType.vaultStop.rawValue,
                deviceFingerprint: nil
            ),
            cognitoToken: cognitoToken
        )
        return try await stopVaultWithActionToken(actionToken: actionResponse.actionToken)
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

    /// Start a stopped vault instance
    func startVaultInstance(authToken: String) async throws -> VaultLifecycleResponse {
        return try await post(endpoint: "/vault/start", body: EmptyBody(), authToken: authToken)
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

    /// Get member vault status
    func getMemberVaultStatus(authToken: String) async throws -> MemberVaultStatusResponse {
        return try await get(endpoint: "/member/vault/status", authToken: authToken)
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

    // MARK: - Backup Management (Phase 8)

    /// Trigger a manual backup
    func triggerBackup(includeMessages: Bool = true, authToken: String) async throws -> Backup {
        let request = TriggerBackupRequest(includeMessages: includeMessages)
        return try await post(endpoint: "/vault/backup", body: request, authToken: authToken)
    }

    /// List available backups
    func listBackups(authToken: String) async throws -> [Backup] {
        let response: BackupListResponse = try await get(endpoint: "/vault/backups", authToken: authToken)
        return response.backups
    }

    /// Get backup details
    func getBackup(backupId: String, authToken: String) async throws -> BackupDetailsResponse {
        return try await get(endpoint: "/vault/backups/\(backupId)", authToken: authToken)
    }

    /// Restore from a backup
    func restoreBackup(backupId: String, authToken: String) async throws -> RestoreResult {
        let request = RestoreBackupRequest(backupId: backupId)
        return try await post(endpoint: "/vault/restore", body: request, authToken: authToken)
    }

    /// Delete a backup
    func deleteBackup(backupId: String, authToken: String) async throws {
        let _: EmptyResponse = try await delete(endpoint: "/vault/backups/\(backupId)", authToken: authToken)
    }

    // MARK: - Backup Settings (Phase 8)

    /// Get backup settings
    func getBackupSettings(authToken: String) async throws -> BackupSettings {
        return try await get(endpoint: "/vault/backup/settings", authToken: authToken)
    }

    /// Update backup settings
    func updateBackupSettings(_ settings: BackupSettings, authToken: String) async throws -> BackupSettings {
        return try await put(endpoint: "/vault/backup/settings", body: settings, authToken: authToken)
    }

    // MARK: - PCR Management (Nitro Enclave)

    /// Get current expected PCR values for Nitro Enclave attestation
    /// This is a PUBLIC endpoint - no authentication required
    func getCurrentPCRs() async throws -> PCRUpdateResponse {
        return try await get(endpoint: "/vault/pcrs/current")
    }

    /// Get the PCR signing public key
    /// This is a PUBLIC endpoint - no authentication required
    func getPCRSigningKey() async throws -> PCRSigningKeyResponse {
        return try await get(endpoint: "/vault/pcrs/signing-key")
    }

    // MARK: - Protean Credential Backup (Issue #4)

    /// Backup Protean Credential to VettID
    /// Called after credential creation to enable recovery
    func backupProteanCredential(
        credentialBlob: Data,
        authToken: String
    ) async throws -> ProteanBackupResponse {
        let request = ProteanBackupRequest(
            credentialBlob: credentialBlob.base64EncodedString()
        )
        return try await post(endpoint: "/vault/backup/credential", body: request, authToken: authToken)
    }

    /// Get Protean Credential backup status
    func getProteanBackupStatus(authToken: String) async throws -> ProteanBackupStatusResponse {
        return try await get(endpoint: "/vault/backup/credential/status", authToken: authToken)
    }

    // MARK: - Protean Credential Recovery (Issue #4)

    /// Request credential recovery - initiates 24-hour delay
    func requestProteanRecovery(authToken: String) async throws -> ProteanRecoveryRequestResponse {
        return try await post(
            endpoint: "/vault/recovery/request",
            body: EmptyRequest(),
            authToken: authToken
        )
    }

    /// Check recovery request status
    func getProteanRecoveryStatus(
        recoveryId: String,
        authToken: String
    ) async throws -> ProteanRecoveryStatusResponse {
        return try await get(
            endpoint: "/vault/recovery/status?recovery_id=\(recoveryId)",
            authToken: authToken
        )
    }

    /// Cancel a pending recovery request
    func cancelProteanRecovery(
        recoveryId: String,
        authToken: String
    ) async throws {
        let request = ProteanRecoveryCancelRequest(recoveryId: recoveryId)
        let _: EmptyResponse = try await post(
            endpoint: "/vault/recovery/cancel",
            body: request,
            authToken: authToken
        )
    }

    /// Download recovered credential (available after 24-hour delay)
    /// - Note: Deprecated for Issue #8 - use confirmRestore instead
    func downloadRecoveredCredential(
        recoveryId: String,
        authToken: String
    ) async throws -> ProteanRecoveryDownloadResponse {
        return try await get(
            endpoint: "/vault/recovery/download?recovery_id=\(recoveryId)",
            authToken: authToken
        )
    }

    /// Confirm credential restore and get bootstrap credentials for NATS authentication
    /// This is the new flow (Issue #8) that returns NATS bootstrap credentials
    /// instead of downloading the credential directly via HTTP.
    ///
    /// After calling this, the app should:
    /// 1. Connect to NATS using the bootstrap credentials
    /// 2. Authenticate via NATS to the vault using `app.authenticate`
    /// 3. Vault verifies password and issues full NATS credentials
    func confirmRestore(
        recoveryId: String,
        authToken: String
    ) async throws -> RestoreConfirmResponse {
        let request = RestoreConfirmRequest(recoveryId: recoveryId)
        return try await post(
            endpoint: "/vault/credentials/restore/confirm",
            body: request,
            authToken: authToken
        )
    }

    // MARK: - Voting (Phase 9)

    /// Fetch proposals for voting
    func getProposals(
        status: String? = nil,
        page: Int = 1,
        limit: Int = 20,
        authToken: String
    ) async throws -> ProposalListResponse {
        var endpoint = "/member/proposals?page=\(page)&limit=\(limit)"
        if let status = status {
            endpoint += "&status=\(status)"
        }
        return try await get(endpoint: endpoint, authToken: authToken)
    }

    /// Get a single proposal by ID
    func getProposal(proposalId: String, authToken: String) async throws -> Proposal {
        return try await get(endpoint: "/member/proposals/\(proposalId)", authToken: authToken)
    }

    /// Get published vote list (after proposal closes)
    func getPublishedVotes(proposalId: String, authToken: String) async throws -> PublishedVoteList {
        return try await get(endpoint: "/member/proposals/\(proposalId)/votes", authToken: authToken)
    }

    /// Get Merkle proof for a specific vote
    func getVoteMerkleProof(
        proposalId: String,
        voteHash: String,
        authToken: String
    ) async throws -> MerkleProofResponse {
        return try await get(
            endpoint: "/member/proposals/\(proposalId)/votes/\(voteHash)/proof",
            authToken: authToken
        )
    }

    /// Get VettID organization public key for verifying proposal signatures
    func getOrgSigningKey() async throws -> OrgSigningKeyResponse {
        return try await get(endpoint: "/public/signing-key")
    }

    /// Submit a vault-signed vote to the backend
    /// The vote is signed by the vault using the member's credential
    func submitSignedVote(
        proposalId: String,
        signedVote: SignedVoteSubmission,
        authToken: String
    ) async throws -> SignedVoteResponse {
        return try await post(
            endpoint: "/member/votes/signed",
            body: signedVote,
            authToken: authToken
        )
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

    private func delete<T: Decodable>(
        endpoint: String,
        authToken: String? = nil
    ) async throws -> T {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest, signed: Bool = true) async throws -> T {
        // Apply request signing if enabled and requested
        var finalRequest = request
        if signed, signRequestsEnabled, let signingKey = signingKey, let requestSigner = requestSigner {
            finalRequest = requestSigner.signRequest(request, with: signingKey)
        }

        let (data, response) = try await session.data(for: finalRequest)

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
            #if DEBUG
            print("[APIClient] Decoding failed for \(T.self)")
            print("[APIClient] Error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[APIClient] Raw response: \(responseString)")
            }
            #endif
            throw APIError.decodingFailed(error)
        }
    }
}

// MARK: - Enrollment Authentication Request/Response Types

struct EnrollAuthenticateRequest: Encodable {
    let sessionToken: String
    let deviceId: String
    let deviceType: String
}

struct EnrollAuthenticateResponse: Decodable {
    let enrollmentToken: String
    let tokenType: String
    let expiresIn: Int
    let expiresAt: String
    let enrollmentSessionId: String
    let userGuid: String
}

// MARK: - Enrollment Request/Response Types

struct EnrollStartRequest: Encodable {
    let skipAttestation: Bool?
}

struct EnrollStartRequestLegacy: Encodable {
    let invitationCode: String
    let deviceId: String
    let attestationData: String  // Base64 encoded
}

struct EnrollStartResponse: Decodable {
    let enrollmentSessionId: String
    let userGuid: String
    let transactionKeys: [TransactionKeyInfo]
    let passwordKeyId: String  // Key ID to use for password encryption
    let nextStep: String?
    let attestationRequired: Bool?
    let attestationChallenge: String?  // Base64 encoded challenge for App Attest
    let passwordPrompt: PasswordPrompt?

    // Nitro Enclave attestation (required for enrollment)
    let enclaveAttestation: EnclaveAttestation?
}

// MARK: - Nitro Enclave Attestation Types

struct EnclaveAttestation: Decodable {
    let attestationDocument: String     // Base64-encoded CBOR
    let enclavePublicKey: String        // Base64 X25519 public key
    let nonce: String                   // Base64 32-byte nonce
    let expectedPcrs: [ExpectedPCRSet]
}

struct ExpectedPCRSet: Decodable {
    let pcr0: String  // Hex 48 bytes
    let pcr1: String
    let pcr2: String
    let validFrom: String?
    let validUntil: String?
}

// MARK: - iOS Attestation Request/Response Types

struct EnrollAttestationIOSRequest: Encodable {
    let enrollmentSessionId: String
    let attestationObject: String  // Base64-CBOR encoded attestation
    let keyId: String              // Base64 encoded key ID
}

struct EnrollAttestationResponse: Decodable {
    let status: String             // "attestation_verified"
    let deviceType: String         // "ios"
    let securityLevel: String      // "hardware"
    let nextStep: String           // "password_required"
    let passwordKeyId: String      // UUID for password encryption
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
    let encryptedPasswordHash: String  // Base64 encoded ciphertext + tag
    let keyId: String
    let nonce: String  // Base64 encoded 12-byte nonce
    let ephemeralPublicKey: String  // Base64 encoded 32-byte X25519 public key
}

struct EnrollSetPasswordResponse: Decodable {
    let status: String
    let nextStep: String?
}

// MARK: - PIN Setup Request/Response (Architecture v2.0 Section 5.7)

struct EnrollSetPINRequest: Encodable {
    let encryptedPIN: String         // Base64 encoded ciphertext (PIN encrypted to enclave key)
    let nonce: String                // Base64 encoded nonce for replay protection
    let ephemeralPublicKey: String   // Base64 encoded X25519 ephemeral public key

    enum CodingKeys: String, CodingKey {
        case encryptedPIN = "encrypted_pin"
        case nonce
        case ephemeralPublicKey = "ephemeral_public_key"
    }
}

struct EnrollSetPINResponse: Decodable {
    let status: String               // "pin_set" or "success"
    let nextStep: String?            // "finalize" or nil

    enum CodingKeys: String, CodingKey {
        case status
        case nextStep = "next_step"
    }
}

struct EnrollFinalizeRequest: Encodable {
    // Empty - session info is passed via JWT
}

struct EnrollFinalizeResponse: Decodable {
    let status: String
    let credentialPackage: CredentialPackage
    let vaultStatus: String?
    let message: String?
    let natsConnection: NatsConnectionInfo?  // NATS credentials from auto-provisioned vault
    let vaultInstanceId: String?             // EC2 instance ID for the vault
}

// MARK: - NATS Connection Info (returned from enrollFinalize)

struct NatsConnectionInfo: Decodable {
    let endpoint: String           // NATS server URL
    let credentials: String        // Full .creds file content (JWT + seed)
    let ownerSpace: String         // OwnerSpace topic prefix
    let messageSpace: String       // MessageSpace topic prefix
    let topics: NatsTopics?        // Optional topic permissions
}

struct NatsTopics: Decodable {
    let publish: [String]          // Topics the app can publish to
    let subscribe: [String]        // Topics the app can subscribe to
}

struct CredentialPackage: Codable {
    let userGuid: String
    let credentialId: String?
    let sealedCredential: String        // Base64 enclave-sealed blob
    let enclavePublicKey: String        // Identity public key
    let backupKey: String               // For backup encryption
    let ephemeralPublicKey: String?
    let nonce: String?
    let ledgerAuthToken: LedgerAuthToken
    let transactionKeys: [TransactionKeyInfo]?
    let newTransactionKeys: [TransactionKeyInfo]?
}

struct LedgerAuthToken: Codable {
    let latId: String?  // Optional - may not be present in new API
    let token: String  // lat_xxx format or hex
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
    let sealedCredential: String  // Base64 enclave-sealed blob
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

/// Response from GET /member/vault/status (Android equivalent)
struct MemberVaultStatusResponse: Decodable {
    let status: String  // "not_enrolled", "enrolled", "provisioning", "running", "stopped", "terminated"
    let instanceId: String?
    let publicIp: String?
    let privateIp: String?
    let region: String?
    let launchedAt: String?
    let lastHeartbeat: String?
}

struct VaultActionResponse: Decodable {
    let success: Bool
    let message: String
}

// MARK: - Action-Token Vault Lifecycle Types

/// Response from GET /api/v1/vault/status (action-token authenticated)
struct ActionVaultStatusResponse: Decodable {
    // Enrollment status
    let enrollmentStatus: String  // not_enrolled, pending, enrolled, active, error
    let userGuid: String?
    let enrolledAt: String?
    let lastAuthAt: String?
    let lastSyncAt: String?
    let deviceType: String?  // android, ios
    let securityLevel: String?
    let transactionKeysRemaining: Int?
    let credentialVersion: Int?

    // Instance status (if vault exists)
    let instanceStatus: String?  // running, stopped, stopping, starting, pending, terminated, provisioning, initializing
    let instanceId: String?
    let instanceIp: String?
    let natsEndpoint: String?

    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case enrollmentStatus = "enrollment_status"
        case userGuid = "user_guid"
        case enrolledAt = "enrolled_at"
        case lastAuthAt = "last_auth_at"
        case lastSyncAt = "last_sync_at"
        case deviceType = "device_type"
        case securityLevel = "security_level"
        case transactionKeysRemaining = "transaction_keys_remaining"
        case credentialVersion = "credential_version"
        case instanceStatus = "instance_status"
        case instanceId = "instance_id"
        case instanceIp = "instance_ip"
        case natsEndpoint = "nats_endpoint"
        case errorMessage = "error_message"
    }
}

/// Response from POST /api/v1/vault/start (action-token authenticated)
struct ActionVaultStartResponse: Decodable {
    let status: String  // starting, running, pending
    let instanceId: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case status
        case instanceId = "instance_id"
        case message
    }
}

/// Response from POST /api/v1/vault/stop (action-token authenticated)
struct ActionVaultStopResponse: Decodable {
    let status: String  // stopping, stopped
    let instanceId: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case status
        case instanceId = "instance_id"
        case message
    }
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

// MARK: - Backup Types (Phase 8)

struct BackupListResponse: Decodable {
    let backups: [Backup]
}

struct BackupDetailsResponse: Decodable {
    let backup: Backup
    let contents: BackupContents?
}

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
    // Vault lifecycle actions (for mobile apps)
    case vaultStart = "vault_start"
    case vaultStop = "vault_stop"
    case vaultStatus = "vault_status"
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

// MARK: - PCR Types (Nitro Enclave)

/// Response from GET /vault/pcrs/current
/// Backend returns a single PCR configuration with signature
struct PCRUpdateResponse: Decodable {
    let pcrs: PCRValues
    let version: String
    let publishedAt: String
    let signature: String
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case pcrs
        case version
        case publishedAt = "published_at"
        case signature
        case keyId = "key_id"
    }

    /// Convert to store format (array of PCR sets for compatibility)
    var pcrSets: [PCRSetDTO] {
        [PCRSetDTO(
            id: version,
            pcr0: pcrs.pcr0,
            pcr1: pcrs.pcr1,
            pcr2: pcrs.pcr2,
            validFrom: ISO8601DateFormatter().date(from: publishedAt) ?? Date(),
            validUntil: nil,
            isCurrent: true
        )]
    }

    /// Signed-at date for downgrade protection
    var signedAt: Date {
        ISO8601DateFormatter().date(from: publishedAt) ?? Date()
    }
}

/// PCR values from the backend
struct PCRValues: Decodable {
    let pcr0: String
    let pcr1: String
    let pcr2: String
    let pcr3: String?

    enum CodingKeys: String, CodingKey {
        case pcr0 = "PCR0"
        case pcr1 = "PCR1"
        case pcr2 = "PCR2"
        case pcr3 = "PCR3"
    }
}

/// Individual PCR set (for store compatibility)
struct PCRSetDTO {
    let id: String
    let pcr0: String
    let pcr1: String
    let pcr2: String
    let validFrom: Date
    let validUntil: Date?
    let isCurrent: Bool

    /// Convert to ExpectedPCRStore.PCRSet
    func toPCRSet() -> ExpectedPCRStore.PCRSet {
        ExpectedPCRStore.PCRSet(
            id: id,
            pcr0: pcr0,
            pcr1: pcr1,
            pcr2: pcr2,
            validFrom: validFrom,
            validUntil: validUntil,
            isCurrent: isCurrent
        )
    }
}

/// Response from GET /vault/pcrs/signing-key
struct PCRSigningKeyResponse: Decodable {
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
    }
}

// MARK: - Protean Credential Backup Types (Issue #4)

/// Request to backup Protean Credential
struct ProteanBackupRequest: Encodable {
    let credentialBlob: String  // Base64 encoded

    enum CodingKeys: String, CodingKey {
        case credentialBlob = "credential_blob"
    }
}

/// Response from Protean Credential backup
struct ProteanBackupResponse: Decodable {
    let backupId: String
    let createdAt: String
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case backupId = "backup_id"
        case createdAt = "created_at"
        case sizeBytes = "size_bytes"
    }
}

/// Response from backup status check
struct ProteanBackupStatusResponse: Decodable {
    let hasBackup: Bool
    let backupId: String?
    let createdAt: String?
    let sizeBytes: Int?
    let version: Int?

    enum CodingKeys: String, CodingKey {
        case hasBackup = "has_backup"
        case backupId = "backup_id"
        case createdAt = "created_at"
        case sizeBytes = "size_bytes"
        case version
    }
}

// MARK: - Protean Credential Recovery Types (Issue #4)

/// Response from recovery request
struct ProteanRecoveryRequestResponse: Decodable {
    let recoveryId: String
    let requestedAt: String
    let availableAt: String  // 24 hours later
    let status: String       // "pending"

    enum CodingKeys: String, CodingKey {
        case recoveryId = "recovery_id"
        case requestedAt = "requested_at"
        case availableAt = "available_at"
        case status
    }
}

/// Response from recovery status check
struct ProteanRecoveryStatusResponse: Decodable {
    let recoveryId: String
    let status: String       // "pending", "ready", "cancelled", "expired"
    let requestedAt: String
    let availableAt: String
    let remainingSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case recoveryId = "recovery_id"
        case status
        case requestedAt = "requested_at"
        case availableAt = "available_at"
        case remainingSeconds = "remaining_seconds"
    }
}

/// Request to cancel recovery
struct ProteanRecoveryCancelRequest: Encodable {
    let recoveryId: String

    enum CodingKeys: String, CodingKey {
        case recoveryId = "recovery_id"
    }
}

/// Response from recovery download (after 24 hours)
struct ProteanRecoveryDownloadResponse: Decodable {
    let credentialBlob: String  // Base64 encoded
    let version: Int

    enum CodingKeys: String, CodingKey {
        case credentialBlob = "credential_blob"
        case version
    }
}

/// Recovery status enum for easier handling
enum ProteanRecoveryStatus: String, Codable {
    case pending
    case ready
    case cancelled
    case expired
}

// MARK: - Credential Restore Types (Issue #8)

/// Request to confirm credential restore (step 2 of recovery)
struct RestoreConfirmRequest: Encodable {
    let recoveryId: String

    enum CodingKeys: String, CodingKey {
        case recoveryId = "recovery_id"
    }
}

/// Response from restore confirm - contains bootstrap credentials for NATS auth
struct RestoreConfirmResponse: Decodable {
    let success: Bool
    let status: String  // "pending_authentication"
    let message: String

    let credentialBackup: CredentialBackup
    let vaultBootstrap: VaultBootstrap

    enum CodingKeys: String, CodingKey {
        case success
        case status
        case message
        case credentialBackup = "credential_backup"
        case vaultBootstrap = "vault_bootstrap"
    }
}

/// Encrypted credential backup from Lambda
struct CredentialBackup: Decodable {
    let encryptedCredential: String  // Base64
    let backupId: String
    let createdAt: String
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case encryptedCredential = "encrypted_credential"
        case backupId = "backup_id"
        case createdAt = "created_at"
        case keyId = "key_id"
    }
}

/// Bootstrap credentials for NATS connection during restore
struct VaultBootstrap: Decodable {
    let credentials: String  // Full NATS creds file content
    let ownerSpace: String
    let messageSpace: String
    let natsEndpoint: String
    let authTopic: String  // {OwnerSpace}.forVault.app.authenticate
    let responseTopic: String  // {OwnerSpace}.forApp.app.authenticate.>
    let credentialsTtlSeconds: Int

    enum CodingKeys: String, CodingKey {
        case credentials
        case ownerSpace = "owner_space"
        case messageSpace = "message_space"
        case natsEndpoint = "nats_endpoint"
        case authTopic = "auth_topic"
        case responseTopic = "response_topic"
        case credentialsTtlSeconds = "credentials_ttl_seconds"
    }
}

// MARK: - Helper Types (Phase 7)

/// Empty request body for endpoints that don't need one
struct EmptyRequest: Encodable {}

/// Empty response for endpoints that return no body
struct EmptyResponse: Decodable {}

// MARK: - Voting Types (Phase 9)

/// Response from GET /public/signing-key
struct OrgSigningKeyResponse: Decodable {
    let publicKey: String  // Base64-encoded ECDSA public key
    let keyId: String
    let algorithm: String  // "ECDSA_SHA_256"
}
