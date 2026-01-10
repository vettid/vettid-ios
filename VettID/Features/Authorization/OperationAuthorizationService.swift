import Foundation

/// Service for authorizing sensitive vault operations with password
/// (Architecture v2.0 Section 5.10)
///
/// Flow:
/// 1. Request challenge from vault-manager via NATS
/// 2. User enters password
/// 3. Hash password with Argon2id, encrypt with challenge UTK
/// 4. Submit authorized operation to vault-manager
///
/// The challenge is single-use (replay protection) and tied to a specific operation.
@MainActor
final class OperationAuthorizationService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AuthorizationState = .idle
    @Published var error: AuthorizationError?

    // MARK: - Current Challenge

    private var currentChallenge: OperationChallenge?

    // MARK: - Dependencies

    private let natsConnectionManager: NatsConnectionManager

    // MARK: - Initialization

    init(natsConnectionManager: NatsConnectionManager) {
        self.natsConnectionManager = natsConnectionManager
    }

    // MARK: - Challenge Flow

    /// Request a challenge for an operation that requires authorization
    ///
    /// - Parameters:
    ///   - operationType: Type of operation being authorized
    ///   - operationId: Unique ID for the operation
    /// - Returns: Challenge response with UTK for password encryption
    func requestChallenge(
        for operationType: AuthorizableOperation,
        operationId: String = UUID().uuidString
    ) async throws -> OperationChallenge {
        state = .requestingChallenge

        do {
            let challenge = try await requestChallengeFromVault(
                operationType: operationType,
                operationId: operationId
            )

            currentChallenge = challenge
            state = .awaitingPassword

            return challenge
        } catch {
            let authError = AuthorizationError.challengeFailed(error.localizedDescription)
            self.error = authError
            state = .failed(authError)
            throw authError
        }
    }

    /// Authorize an operation with password
    ///
    /// - Parameters:
    ///   - password: User's password for authorization
    ///   - onAuthorized: Closure called with authorization token when successful
    func authorize(
        password: String,
        onAuthorized: @escaping (AuthorizationToken) async throws -> Void
    ) async throws {
        guard let challenge = currentChallenge else {
            throw AuthorizationError.noChallenge
        }

        state = .authorizing

        do {
            // Hash password with Argon2id
            let hashResult = try PasswordHasher.hash(password: password)

            // Encrypt password hash with challenge UTK
            let encryptedPayload = try CryptoManager.encryptPasswordHash(
                passwordHash: hashResult.hash,
                utkPublicKeyBase64: challenge.utkPublicKey
            )

            // Submit authorization to vault
            let token = try await submitAuthorization(
                challenge: challenge,
                encryptedPayload: encryptedPayload,
                salt: hashResult.salt.base64EncodedString()
            )

            // Clear challenge (single-use)
            currentChallenge = nil

            // Execute the authorized operation
            state = .executing
            try await onAuthorized(token)

            state = .completed
        } catch let error as AuthorizationError {
            self.error = error
            state = .failed(error)
            throw error
        } catch {
            let authError = AuthorizationError.authorizationFailed(error.localizedDescription)
            self.error = authError
            state = .failed(authError)
            throw authError
        }
    }

    /// Cancel current authorization flow
    func cancel() {
        currentChallenge = nil
        state = .idle
        error = nil
    }

    /// Reset service to idle state
    func reset() {
        currentChallenge = nil
        state = .idle
        error = nil
    }

    // MARK: - NATS Communication

    private func requestChallengeFromVault(
        operationType: AuthorizableOperation,
        operationId: String
    ) async throws -> OperationChallenge {
        guard natsConnectionManager.connectionState == .connected else {
            throw AuthorizationError.notConnected
        }

        let requestId = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let request = ChallengeRequest(
            id: requestId,
            operationType: operationType.rawValue,
            operationId: operationId,
            deviceId: getDeviceId(),
            timestamp: timestamp
        )

        // Send challenge request
        let requestTopic = "challenge.request"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[Authorization] Sent challenge request for \(operationType.rawValue)")
        #endif

        // Subscribe to response
        let responseTopic = "forApp.challenge.response.>"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Wait for response with timeout
        let timeout: TimeInterval = 30
        let response: ChallengeResponse = try await withThrowingTaskGroup(of: ChallengeResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(ChallengeResponse.self, from: message.data) {
                        if response.requestId == requestId {
                            return response
                        }
                    }
                }
                throw AuthorizationError.challengeFailed("Response stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AuthorizationError.challengeFailed("Challenge request timed out")
            }

            guard let result = try await group.next() else {
                throw AuthorizationError.challengeFailed("Challenge failed")
            }

            group.cancelAll()
            return result
        }

        // Clean up subscription
        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            throw AuthorizationError.challengeFailed(response.message ?? "Challenge denied")
        }

        return OperationChallenge(
            challengeId: response.challengeId,
            operationType: operationType,
            operationId: operationId,
            utkPublicKey: response.utkPublicKey,
            expiresAt: response.expiresAt
        )
    }

    private func submitAuthorization(
        challenge: OperationChallenge,
        encryptedPayload: EncryptedPasswordPayload,
        salt: String
    ) async throws -> AuthorizationToken {
        let requestId = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let request = AuthorizationRequest(
            id: requestId,
            challengeId: challenge.challengeId,
            operationType: challenge.operationType.rawValue,
            operationId: challenge.operationId,
            encryptedPasswordHash: encryptedPayload.encryptedPasswordHash,
            ephemeralPublicKey: encryptedPayload.ephemeralPublicKey,
            nonce: encryptedPayload.nonce,
            salt: salt,
            timestamp: timestamp
        )

        // Send authorization
        let requestTopic = "challenge.authorize"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[Authorization] Sent authorization for challenge \(challenge.challengeId)")
        #endif

        // Subscribe to response
        let responseTopic = "forApp.challenge.authorized.>"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Wait for response
        let timeout: TimeInterval = 30
        let response: AuthorizationResponse = try await withThrowingTaskGroup(of: AuthorizationResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(AuthorizationResponse.self, from: message.data) {
                        if response.challengeId == challenge.challengeId {
                            return response
                        }
                    }
                }
                throw AuthorizationError.authorizationFailed("Response stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AuthorizationError.authorizationFailed("Authorization timed out")
            }

            guard let result = try await group.next() else {
                throw AuthorizationError.authorizationFailed("Authorization failed")
            }

            group.cancelAll()
            return result
        }

        // Clean up subscription
        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            if response.message?.lowercased().contains("password") == true {
                throw AuthorizationError.incorrectPassword
            }
            throw AuthorizationError.authorizationFailed(response.message ?? "Authorization denied")
        }

        return AuthorizationToken(
            token: response.authToken,
            operationType: challenge.operationType,
            operationId: challenge.operationId,
            expiresAt: response.expiresAt
        )
    }

    private func getDeviceId() -> String {
        let key = "com.vettid.device_id"
        if let deviceId = UserDefaults.standard.string(forKey: key) {
            return deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Authorization State

enum AuthorizationState: Equatable {
    case idle
    case requestingChallenge
    case awaitingPassword
    case authorizing
    case executing
    case completed
    case failed(AuthorizationError)

    var isProcessing: Bool {
        switch self {
        case .requestingChallenge, .authorizing, .executing:
            return true
        default:
            return false
        }
    }

    var needsPassword: Bool {
        if case .awaitingPassword = self { return true }
        return false
    }
}

// MARK: - Authorization Error

enum AuthorizationError: Error, Equatable, LocalizedError {
    case notConnected
    case noChallenge
    case challengeFailed(String)
    case authorizationFailed(String)
    case incorrectPassword
    case expired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to vault. Please check your connection."
        case .noChallenge:
            return "No challenge available. Please try again."
        case .challengeFailed(let message):
            return "Challenge failed: \(message)"
        case .authorizationFailed(let message):
            return "Authorization failed: \(message)"
        case .incorrectPassword:
            return "Incorrect password. Please try again."
        case .expired:
            return "Authorization expired. Please try again."
        case .cancelled:
            return "Authorization cancelled."
        }
    }
}

// MARK: - Authorizable Operations

/// Operations that require password authorization
enum AuthorizableOperation: String, CaseIterable {
    case deleteCredential = "credential.delete"
    case exportCredential = "credential.export"
    case rotateKeys = "keys.rotate"
    case deleteSecret = "secret.delete"
    case exportSecret = "secret.export"
    case revokeConnection = "connection.revoke"
    case terminateVault = "vault.terminate"
    case changePassword = "password.change"
    case deleteProfile = "profile.delete"

    var displayName: String {
        switch self {
        case .deleteCredential: return "Delete Credential"
        case .exportCredential: return "Export Credential"
        case .rotateKeys: return "Rotate Keys"
        case .deleteSecret: return "Delete Secret"
        case .exportSecret: return "Export Secret"
        case .revokeConnection: return "Revoke Connection"
        case .terminateVault: return "Terminate Vault"
        case .changePassword: return "Change Password"
        case .deleteProfile: return "Delete Profile"
        }
    }

    var warningMessage: String {
        switch self {
        case .deleteCredential:
            return "This will permanently delete your credential."
        case .exportCredential:
            return "Your credential will be exported. Keep it secure."
        case .rotateKeys:
            return "Your encryption keys will be rotated."
        case .deleteSecret:
            return "This secret will be permanently deleted."
        case .exportSecret:
            return "This secret will be exported."
        case .revokeConnection:
            return "This connection will be permanently revoked."
        case .terminateVault:
            return "Your vault will be permanently terminated. This cannot be undone."
        case .changePassword:
            return "Your password will be changed."
        case .deleteProfile:
            return "Your profile data will be permanently deleted."
        }
    }
}

// MARK: - Challenge Types

/// Challenge from vault-manager
struct OperationChallenge {
    let challengeId: String
    let operationType: AuthorizableOperation
    let operationId: String
    let utkPublicKey: String  // Base64 X25519 public key
    let expiresAt: Date?
}

/// Authorization token for authorized operation
struct AuthorizationToken {
    let token: String
    let operationType: AuthorizableOperation
    let operationId: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiry = expiresAt else { return false }
        return Date() > expiry
    }
}

// MARK: - NATS Request/Response Types

struct ChallengeRequest: Encodable {
    let id: String
    let operationType: String
    let operationId: String
    let deviceId: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case operationType = "operation_type"
        case operationId = "operation_id"
        case deviceId = "device_id"
        case timestamp
    }
}

struct ChallengeResponse: Decodable {
    let success: Bool
    let message: String?
    let requestId: String
    let challengeId: String
    let utkPublicKey: String  // Base64 X25519 public key for encrypting password
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case requestId = "request_id"
        case challengeId = "challenge_id"
        case utkPublicKey = "utk_public_key"
        case expiresAt = "expires_at"
    }
}

struct AuthorizationRequest: Encodable {
    let id: String
    let challengeId: String
    let operationType: String
    let operationId: String
    let encryptedPasswordHash: String  // Base64
    let ephemeralPublicKey: String  // Base64
    let nonce: String  // Base64
    let salt: String  // Base64
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case challengeId = "challenge_id"
        case operationType = "operation_type"
        case operationId = "operation_id"
        case encryptedPasswordHash = "encrypted_password_hash"
        case ephemeralPublicKey = "ephemeral_public_key"
        case nonce
        case salt
        case timestamp
    }
}

struct AuthorizationResponse: Decodable {
    let success: Bool
    let message: String?
    let challengeId: String
    let authToken: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case challengeId = "challenge_id"
        case authToken = "auth_token"
        case expiresAt = "expires_at"
    }
}
