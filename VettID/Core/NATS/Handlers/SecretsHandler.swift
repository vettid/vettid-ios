import Foundation

/// Handler for vault secrets operations via NATS
///
/// Provides encrypted storage and retrieval of secrets in the vault's datastore.
/// All operations are performed via NATS topics for real-time communication.
///
/// NATS Topics:
/// - `secrets.datastore.add` - Add a new secret
/// - `secrets.datastore.update` - Update existing secret
/// - `secrets.datastore.retrieve` - Get a secret by key
/// - `secrets.datastore.delete` - Remove a secret
/// - `secrets.datastore.list` - List secrets with optional filter
actor SecretsHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Secret Operations

    /// Add a new secret to the vault datastore
    /// - Parameters:
    ///   - key: Unique identifier for the secret
    ///   - value: Secret data (will be encrypted by vault)
    ///   - metadata: Optional metadata about the secret
    /// - Returns: Response indicating success/failure
    func addSecret(
        key: String,
        value: Data,
        metadata: SecretMetadata? = nil
    ) async throws -> VaultEventResponse {
        var payload: [String: AnyCodableValue] = [
            "key": AnyCodableValue(key),
            "value": AnyCodableValue(value.base64EncodedString())
        ]

        if let metadata = metadata {
            payload["metadata"] = AnyCodableValue([
                "label": metadata.label ?? "",
                "category": metadata.category ?? "general",
                "tags": metadata.tags ?? []
            ])
        }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "secrets.datastore.add",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Update an existing secret
    /// - Parameters:
    ///   - key: Secret identifier
    ///   - value: New secret data
    /// - Returns: Response indicating success/failure
    func updateSecret(key: String, value: Data) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "key": AnyCodableValue(key),
            "value": AnyCodableValue(value.base64EncodedString())
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "secrets.datastore.update",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Retrieve a secret from the vault
    /// - Parameter key: Secret identifier
    /// - Returns: Secret data with metadata
    func retrieveSecret(key: String) async throws -> SecretData {
        let payload: [String: AnyCodableValue] = [
            "key": AnyCodableValue(key)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "secrets.datastore.retrieve",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw SecretsHandlerError.retrievalFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let valueBase64 = result["value"]?.value as? String,
              let valueData = Data(base64Encoded: valueBase64) else {
            throw SecretsHandlerError.invalidResponse
        }

        let metadata = SecretMetadata(
            label: result["label"]?.value as? String,
            category: result["category"]?.value as? String,
            tags: result["tags"]?.value as? [String],
            createdAt: (result["created_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            updatedAt: (result["updated_at"]?.value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )

        return SecretData(key: key, value: valueData, metadata: metadata)
    }

    /// Delete a secret from the vault
    /// - Parameter key: Secret identifier
    /// - Returns: Response indicating success/failure
    func deleteSecret(key: String) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "key": AnyCodableValue(key)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "secrets.datastore.delete",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// List secrets in the vault with optional filtering
    /// - Parameter filter: Optional filter criteria
    /// - Returns: List of secret metadata (not values)
    func listSecrets(filter: SecretFilter? = nil) async throws -> [SecretMetadata] {
        var payload: [String: AnyCodableValue] = [:]

        if let filter = filter {
            if let category = filter.category {
                payload["category"] = AnyCodableValue(category)
            }
            if let tags = filter.tags {
                payload["tags"] = AnyCodableValue(tags)
            }
            if let limit = filter.limit {
                payload["limit"] = AnyCodableValue(limit)
            }
            if let offset = filter.offset {
                payload["offset"] = AnyCodableValue(offset)
            }
        }

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "secrets.datastore.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw SecretsHandlerError.listFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let secretsArray = result["secrets"]?.value as? [[String: Any]] else {
            return []
        }

        return secretsArray.compactMap { dict -> SecretMetadata? in
            guard let key = dict["key"] as? String else { return nil }
            return SecretMetadata(
                key: key,
                label: dict["label"] as? String,
                category: dict["category"] as? String,
                tags: dict["tags"] as? [String],
                createdAt: (dict["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                updatedAt: (dict["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }
    }
}

// MARK: - Supporting Types

/// Metadata about a secret
struct SecretMetadata: Codable, Equatable {
    let key: String?
    let label: String?
    let category: String?
    let tags: [String]?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        key: String? = nil,
        label: String? = nil,
        category: String? = nil,
        tags: [String]? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.label = label
        self.category = category
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Retrieved secret data with metadata
struct SecretData: Equatable {
    let key: String
    let value: Data
    let metadata: SecretMetadata
}

/// Filter criteria for listing secrets
struct SecretFilter {
    let category: String?
    let tags: [String]?
    let limit: Int?
    let offset: Int?

    init(
        category: String? = nil,
        tags: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.category = category
        self.tags = tags
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - Errors

enum SecretsHandlerError: LocalizedError {
    case retrievalFailed(String)
    case listFailed(String)
    case invalidResponse
    case secretNotFound

    var errorDescription: String? {
        switch self {
        case .retrievalFailed(let reason):
            return "Failed to retrieve secret: \(reason)"
        case .listFailed(let reason):
            return "Failed to list secrets: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        case .secretNotFound:
            return "Secret not found"
        }
    }
}
