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
    case refreshFailed(String)
    case statusCheckFailed(String)
    case syncFailed(String)
    case utkRequestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
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
