import Foundation

/// Handler for vault credential operations via NATS
///
/// Manages credential lifecycle including refresh, rotation, and synchronization.
/// Credentials include LAT (Ledger Auth Token), UTKs (Use Transaction Keys),
/// and the encrypted credential blob.
///
/// NATS Topics:
/// - `credentials.refresh` - Request fresh credentials
/// - `credentials.status` - Check credential status
/// - `credential.store` - Store updated credentials
/// - `credential.sync` - Synchronize with vault
actor CredentialsHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Credential Creation and Unsealing (KMS-sealed)

    /// Create a new credential in the enclave
    /// The credential is sealed using KMS envelope encryption with PCR0 binding
    /// - Parameters:
    ///   - encryptedPin: Base64-encoded encrypted PIN (encrypted to enclave public key)
    ///   - authType: Authentication type ("pin", "password", "pattern")
    /// - Returns: Sealed credential blob
    func createCredential(encryptedPin: String, authType: String = "pin") async throws -> CredentialCreateResult {
        let payload: [String: AnyCodableValue] = [
            "encrypted_pin": AnyCodableValue(encryptedPin),
            "auth_type": AnyCodableValue(authType)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "credential.create",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CredentialsHandlerError.createFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let credential = result["credential"]?.value as? String else {
            throw CredentialsHandlerError.invalidResponse
        }

        return CredentialCreateResult(sealedCredential: credential)
    }

    /// Unseal a credential with authentication challenge
    /// Requires KMS attestation in production (PCR0-bound)
    /// - Parameters:
    ///   - sealedCredential: Base64-encoded sealed credential blob
    ///   - challengeId: Challenge identifier from authentication request
    ///   - response: PIN/password response to the challenge
    /// - Returns: Session token for subsequent operations
    func unsealCredential(sealedCredential: String, challengeId: String, response: String) async throws -> CredentialUnsealResult {
        let payload: [String: AnyCodableValue] = [
            "sealed_credential": AnyCodableValue(sealedCredential),
            "challenge": AnyCodableValue([
                "challenge_id": challengeId,
                "response": response
            ])
        ]

        let vaultResponse = try await vaultResponseHandler.submitRawAndAwait(
            type: "credential.unseal",
            payload: payload,
            timeout: defaultTimeout
        )

        guard vaultResponse.isSuccess else {
            throw CredentialsHandlerError.unsealFailed(vaultResponse.error ?? "Unknown error")
        }

        guard let result = vaultResponse.result,
              let unsealResult = result["unseal_result"]?.value as? [String: Any],
              let sessionToken = unsealResult["session_token"] as? String else {
            throw CredentialsHandlerError.invalidResponse
        }

        let expiresAt = (unsealResult["expires_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return CredentialUnsealResult(sessionToken: sessionToken, expiresAt: expiresAt)
    }

    // MARK: - Credential Operations

    /// Request fresh credentials from the vault
    /// - Returns: New credential package
    func refreshCredentials() async throws -> CredentialRefreshResult {
        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "credentials.refresh",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CredentialsHandlerError.refreshFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw CredentialsHandlerError.invalidResponse
        }

        return try parseCredentialResult(result)
    }

    /// Check current credential status
    /// - Returns: Status information about credentials
    func checkStatus() async throws -> CredentialStatusInfo {
        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "credentials.status",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CredentialsHandlerError.statusCheckFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw CredentialsHandlerError.invalidResponse
        }

        return CredentialStatusInfo(
            isValid: (result["is_valid"]?.value as? Bool) ?? false,
            latVersion: result["lat_version"]?.value as? Int,
            utkCount: result["utk_count"]?.value as? Int ?? 0,
            expiresAt: (result["expires_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            needsRotation: (result["needs_rotation"]?.value as? Bool) ?? false
        )
    }

    /// Store updated credential package in vault
    /// - Parameter package: Credential data to store
    /// - Returns: Response indicating success/failure
    func storeCredential(package: CredentialStoreRequest) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "sealed_credential": AnyCodableValue(package.sealedCredential),
            "enclave_public_key": AnyCodableValue(package.enclavePublicKey),
            "backup_key": AnyCodableValue(package.backupKey),
            "lat_token": AnyCodableValue(package.latToken),
            "lat_version": AnyCodableValue(package.latVersion)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "credential.store",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Synchronize credentials with vault
    /// Ensures local and vault credentials are in sync
    /// - Returns: Sync result with any updates
    func syncCredential() async throws -> CredentialSyncResult {
        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "credential.sync",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CredentialsHandlerError.syncFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            return CredentialSyncResult(
                inSync: true,
                updatedCredentials: nil,
                newUtks: nil
            )
        }

        let inSync = (result["in_sync"]?.value as? Bool) ?? true

        var updatedCredentials: CredentialRefreshResult?
        if let credDict = result["credentials"]?.value as? [String: Any] {
            updatedCredentials = try parseCredentialResult(credDict.mapValues { AnyCodableValue($0) })
        }

        var newUtks: [TransactionKeyInfo]?
        if let utksArray = result["new_utks"]?.value as? [[String: Any]] {
            newUtks = utksArray.compactMap { dict -> TransactionKeyInfo? in
                guard let keyId = dict["key_id"] as? String,
                      let publicKey = dict["public_key"] as? String,
                      let algorithm = dict["algorithm"] as? String else {
                    return nil
                }
                return TransactionKeyInfo(keyId: keyId, publicKey: publicKey, algorithm: algorithm)
            }
        }

        return CredentialSyncResult(
            inSync: inSync,
            updatedCredentials: updatedCredentials,
            newUtks: newUtks
        )
    }

    /// Request additional UTKs (Use Transaction Keys)
    /// - Parameter count: Number of keys to request
    /// - Returns: New transaction keys
    func requestUtks(count: Int = 5) async throws -> [TransactionKeyInfo] {
        let payload: [String: AnyCodableValue] = [
            "count": AnyCodableValue(count)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "credentials.utks.request",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CredentialsHandlerError.utkRequestFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let utksArray = result["utks"]?.value as? [[String: Any]] else {
            return []
        }

        return utksArray.compactMap { dict -> TransactionKeyInfo? in
            guard let keyId = dict["key_id"] as? String,
                  let publicKey = dict["public_key"] as? String,
                  let algorithm = dict["algorithm"] as? String else {
                return nil
            }
            return TransactionKeyInfo(keyId: keyId, publicKey: publicKey, algorithm: algorithm)
        }
    }

    // MARK: - Private Helpers

    private func parseCredentialResult(_ result: [String: AnyCodableValue]) throws -> CredentialRefreshResult {
        guard let sealedCredential = result["sealed_credential"]?.value as? String,
              let enclavePublicKey = result["enclave_public_key"]?.value as? String,
              let backupKey = result["backup_key"]?.value as? String else {
            throw CredentialsHandlerError.invalidResponse
        }

        var latToken: String?
        var latVersion: Int?
        var latId: String?

        if let lat = result["lat"]?.value as? [String: Any] {
            latToken = lat["token"] as? String
            latVersion = lat["version"] as? Int
            latId = lat["lat_id"] as? String
        }

        var utks: [TransactionKeyInfo]?
        if let utksArray = result["utks"]?.value as? [[String: Any]] {
            utks = utksArray.compactMap { dict -> TransactionKeyInfo? in
                guard let keyId = dict["key_id"] as? String,
                      let publicKey = dict["public_key"] as? String,
                      let algorithm = dict["algorithm"] as? String else {
                    return nil
                }
                return TransactionKeyInfo(keyId: keyId, publicKey: publicKey, algorithm: algorithm)
            }
        }

        return CredentialRefreshResult(
            sealedCredential: sealedCredential,
            enclavePublicKey: enclavePublicKey,
            backupKey: backupKey,
            latToken: latToken,
            latVersion: latVersion,
            latId: latId,
            transactionKeys: utks
        )
    }
}

// MARK: - Supporting Types

/// Result from credential creation (KMS-sealed)
struct CredentialCreateResult {
    let sealedCredential: String
}

/// Result from credential unsealing
struct CredentialUnsealResult {
    let sessionToken: String
    let expiresAt: Date?
}

/// Result from credential refresh
struct CredentialRefreshResult {
    let sealedCredential: String
    let enclavePublicKey: String
    let backupKey: String
    let latToken: String?
    let latVersion: Int?
    let latId: String?
    let transactionKeys: [TransactionKeyInfo]?
}

/// Credential status information
struct CredentialStatusInfo {
    let isValid: Bool
    let latVersion: Int?
    let utkCount: Int
    let expiresAt: Date?
    let needsRotation: Bool
}

/// Request to store credentials
struct CredentialStoreRequest {
    let sealedCredential: String
    let enclavePublicKey: String
    let backupKey: String
    let latToken: String
    let latVersion: Int
}

/// Result from credential sync
struct CredentialSyncResult {
    let inSync: Bool
    let updatedCredentials: CredentialRefreshResult?
    let newUtks: [TransactionKeyInfo]?
}

// MARK: - Errors

enum CredentialsHandlerError: LocalizedError {
    case createFailed(String)
    case unsealFailed(String)
    case refreshFailed(String)
    case statusCheckFailed(String)
    case syncFailed(String)
    case utkRequestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .createFailed(let reason):
            return "Failed to create credential: \(reason)"
        case .unsealFailed(let reason):
            return "Failed to unseal credential: \(reason)"
        case .refreshFailed(let reason):
            return "Failed to refresh credentials: \(reason)"
        case .statusCheckFailed(let reason):
            return "Failed to check credential status: \(reason)"
        case .syncFailed(let reason):
            return "Failed to sync credentials: \(reason)"
        case .utkRequestFailed(let reason):
            return "Failed to request UTKs: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        }
    }
}
