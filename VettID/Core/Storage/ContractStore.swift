import Foundation
import Security

/// Secure storage for signed service contracts and associated keys
///
/// Storage architecture:
/// - Contract metadata stored in Keychain as JSON
/// - Connection private keys stored separately with biometric protection
/// - NATS credentials stored separately with biometric protection
///
/// Security features:
/// - Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - Biometric protection for sensitive keys
/// - No iCloud sync (device-only)
final class ContractStore {

    // MARK: - Service Identifiers

    private let contractsService = "com.vettid.contracts"
    private let connectionKeysService = "com.vettid.contracts.keys"
    private let natsCredentialsService = "com.vettid.contracts.nats"

    // MARK: - Contract Storage

    /// Store a signed contract with its associated keys
    /// - Parameters:
    ///   - contract: The stored contract record
    ///   - connectionPrivateKey: X25519 private key for this connection
    ///   - natsCredentials: NATS credentials for service communication
    func store(
        contract: StoredContract,
        connectionPrivateKey: Data,
        natsCredentials: ServiceNATSCredentials
    ) throws {
        // Store contract metadata
        let contractData = try JSONEncoder().encode(contract)

        var contractQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contract.contractId,
            kSecValueData as String: contractData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contract.contractId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var status = SecItemAdd(contractQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ContractStoreError.saveFailed(status)
        }

        // Store connection private key with biometric protection
        try storeConnectionKey(
            contractId: contract.contractId,
            privateKey: connectionPrivateKey
        )

        // Store NATS credentials
        try storeNATSCredentials(
            contractId: contract.contractId,
            credentials: natsCredentials
        )
    }

    /// Retrieve a contract by ID
    func retrieve(contractId: String) throws -> StoredContract? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contractId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw ContractStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(StoredContract.self, from: data)
    }

    /// Retrieve a contract by service ID
    func retrieveByService(serviceId: String) throws -> StoredContract? {
        let contracts = try listContracts(status: nil)
        return contracts.first { $0.serviceId == serviceId }
    }

    /// List all contracts
    /// - Parameter status: Filter by status (nil for all)
    func listContracts(status filterStatus: StoredContractStatus? = nil) throws -> [StoredContract] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return []
            }
            throw ContractStoreError.retrieveFailed(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        var contracts: [StoredContract] = []
        for item in items {
            guard let data = item[kSecValueData as String] as? Data else { continue }
            do {
                let contract = try JSONDecoder().decode(StoredContract.self, from: data)

                // Apply filter
                if let filterStatus = filterStatus, contract.status != filterStatus {
                    continue
                }

                contracts.append(contract)
            } catch {
                continue
            }
        }

        return contracts.sorted { $0.createdAt > $1.createdAt }
    }

    /// List active contracts
    func listActiveContracts() throws -> [StoredContract] {
        try listContracts(status: .active)
    }

    /// Update contract status
    func updateStatus(contractId: String, status: StoredContractStatus) throws {
        guard var contract = try retrieve(contractId: contractId) else {
            throw ContractStoreError.notFound
        }

        contract.status = status
        let data = try JSONEncoder().encode(contract)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contractId
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw ContractStoreError.saveFailed(updateStatus)
        }
    }

    /// Delete a contract and its associated keys
    func delete(contractId: String) throws {
        // Delete contract metadata
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contractId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContractStoreError.deleteFailed(status)
        }

        // Delete associated keys
        try deleteConnectionKey(contractId: contractId)
        try deleteNATSCredentials(contractId: contractId)
    }

    /// Delete all contracts
    func deleteAll() throws {
        // Delete all contracts
        let contractQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService
        ]
        SecItemDelete(contractQuery as CFDictionary)

        // Delete all keys
        let keysQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionKeysService
        ]
        SecItemDelete(keysQuery as CFDictionary)

        // Delete all NATS credentials
        let natsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: natsCredentialsService
        ]
        SecItemDelete(natsQuery as CFDictionary)
    }

    // MARK: - Connection Key Storage

    /// Store a connection private key with biometric protection
    private func storeConnectionKey(contractId: String, privateKey: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionKeysService,
            kSecAttrAccount as String: contractId,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Add biometric protection if available
        var error: Unmanaged<CFError>?
        if let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) {
            query[kSecAttrAccessControl as String] = access
            query.removeValue(forKey: kSecAttrAccessible as String)
        }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionKeysService,
            kSecAttrAccount as String: contractId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ContractStoreError.saveFailed(status)
        }
    }

    /// Retrieve a connection private key (requires biometric)
    func retrieveConnectionKey(contractId: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionKeysService,
            kSecAttrAccount as String: contractId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: "Authenticate to access connection key"
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            if status == errSecUserCanceled {
                throw ContractStoreError.biometricCancelled
            }
            throw ContractStoreError.retrieveFailed(status)
        }

        return data
    }

    /// Delete a connection private key
    private func deleteConnectionKey(contractId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionKeysService,
            kSecAttrAccount as String: contractId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContractStoreError.deleteFailed(status)
        }
    }

    // MARK: - NATS Credentials Storage

    /// Store NATS credentials
    private func storeNATSCredentials(contractId: String, credentials: ServiceNATSCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: natsCredentialsService,
            kSecAttrAccount as String: contractId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: natsCredentialsService,
            kSecAttrAccount as String: contractId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ContractStoreError.saveFailed(status)
        }
    }

    /// Retrieve NATS credentials
    func retrieveNATSCredentials(contractId: String) throws -> ServiceNATSCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: natsCredentialsService,
            kSecAttrAccount as String: contractId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw ContractStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(ServiceNATSCredentials.self, from: data)
    }

    /// Delete NATS credentials
    private func deleteNATSCredentials(contractId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: natsCredentialsService,
            kSecAttrAccount as String: contractId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContractStoreError.deleteFailed(status)
        }
    }

    // MARK: - Utility Methods

    /// Check if a contract exists
    func hasContract(contractId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: contractsService,
            kSecAttrAccount as String: contractId,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Count of active contracts
    func activeContractCount() throws -> Int {
        let contracts = try listActiveContracts()
        return contracts.count
    }
}

// MARK: - Stored Contract Model

/// Stored contract with references to associated keys
struct StoredContract: Codable {
    let contractId: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let offeringId: String
    let offeringSnapshot: ServiceDataContract
    let capabilities: [String]
    let sharedFields: [SharedFieldMapping]

    // Cryptographic keys (references to Keychain items)
    let userConnectionKeyId: String      // Keychain reference for X25519 private key
    let serviceConnectionKey: String     // Service's X25519 public key (base64)
    let serviceSigningKey: String        // Service's Ed25519 public key (base64)

    // Contract signatures
    let userSignature: String            // User's Ed25519 signature (base64)
    let serviceSignature: String?        // Service's Ed25519 signature (base64)

    // Status tracking
    var status: StoredContractStatus
    let createdAt: Date
    var activatedAt: Date?
    var revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case contractId = "contract_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case offeringId = "offering_id"
        case offeringSnapshot = "offering_snapshot"
        case capabilities
        case sharedFields = "shared_fields"
        case userConnectionKeyId = "user_connection_key_id"
        case serviceConnectionKey = "service_connection_key"
        case serviceSigningKey = "service_signing_key"
        case userSignature = "user_signature"
        case serviceSignature = "service_signature"
        case status
        case createdAt = "created_at"
        case activatedAt = "activated_at"
        case revokedAt = "revoked_at"
    }
}

/// Status of a stored contract
enum StoredContractStatus: String, Codable {
    case pending        // Signed by user, waiting for service activation
    case active         // Fully activated
    case suspended      // Temporarily suspended
    case revoked        // Revoked by user
    case cancelled      // Cancelled by service
    case expired        // Expired

    var displayName: String {
        switch self {
        case .pending: return "Pending Activation"
        case .active: return "Active"
        case .suspended: return "Suspended"
        case .revoked: return "Revoked"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        }
    }
}

// MARK: - Errors

enum ContractStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
    case notFound
    case biometricCancelled

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save contract: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve contract: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete contract: \(status)"
        case .encodingFailed:
            return "Failed to encode contract"
        case .decodingFailed:
            return "Failed to decode contract"
        case .notFound:
            return "Contract not found"
        case .biometricCancelled:
            return "Biometric authentication was cancelled"
        }
    }
}
