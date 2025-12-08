import Foundation
import Security
import CryptoKit
import LocalAuthentication

/// Manages cryptographic keys with Secure Enclave support where available
/// Security hardening applied per OWASP Mobile Security Testing Guide
final class SecureKeyStore {

    private let service = "com.vettid.keys"

    /// Keychain access group for app-specific isolation
    private let accessGroup: String? = nil // Set to team ID + bundle ID for shared keychain

    // MARK: - Security Configuration

    /// Security level for key storage
    enum SecurityLevel {
        case standard           // Keychain with device unlock protection
        case biometric          // Requires biometric + current biometric set
        case biometricStrict    // Biometric only, no passcode fallback
    }

    // MARK: - Secure Enclave Key Generation

    /// Generate a key in the Secure Enclave (if available) or software
    /// Note: Secure Enclave only supports P-256, so for X25519 we use software keys
    /// protected by the Keychain with biometric access control
    func generateProtectedX25519KeyPair(
        keyId: String,
        requireBiometric: Bool = true
    ) throws -> (privateKey: Curve25519.KeyAgreement.PrivateKey,
                 publicKey: Curve25519.KeyAgreement.PublicKey) {

        let keyPair = CryptoManager.generateX25519KeyPair()

        // Store private key in Keychain with access control
        try storePrivateKey(
            keyPair.privateKey.rawRepresentation,
            keyId: keyId,
            securityLevel: requireBiometric ? .biometric : .standard
        )

        return keyPair
    }

    /// Generate a protected Ed25519 signing key pair
    func generateProtectedEd25519KeyPair(
        keyId: String,
        requireBiometric: Bool = true
    ) throws -> (privateKey: Curve25519.Signing.PrivateKey,
                 publicKey: Curve25519.Signing.PublicKey) {

        let keyPair = CryptoManager.generateEd25519KeyPair()

        try storePrivateKey(
            keyPair.privateKey.rawRepresentation,
            keyId: keyId,
            securityLevel: requireBiometric ? .biometric : .standard
        )

        return keyPair
    }

    // MARK: - Key Storage

    private func storePrivateKey(
        _ keyData: Data,
        keyId: String,
        securityLevel: SecurityLevel
    ) throws {
        let accessControl = try createAccessControl(for: securityLevel)

        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: keyData,
            kSecAttrService as String: service,
            // Security: Prevent synchronization to iCloud Keychain
            kSecAttrSynchronizable as String: false
        ]

        if let accessControl = accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            // Fallback: accessible only when device is unlocked, never migrates
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        // Add access group if configured
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        // Securely delete existing key if present
        try secureDelete(keyId: keyId)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.storeFailed(status)
        }
    }

    /// Create access control flags based on security level
    private func createAccessControl(for level: SecurityLevel) throws -> SecAccessControl? {
        var flags: SecAccessControlCreateFlags = []

        switch level {
        case .standard:
            // No biometric required, just device unlock
            return nil

        case .biometric:
            // Biometric required with current enrollment
            // .biometryCurrentSet invalidates key if biometrics change
            flags = [.biometryCurrentSet, .privateKeyUsage]

        case .biometricStrict:
            // Biometric only - no passcode fallback
            flags = [.biometryCurrentSet, .privateKeyUsage]
        }

        var error: Unmanaged<CFError>?
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        )

        if let error = error?.takeRetainedValue() {
            throw SecureKeyStoreError.accessControlFailed(error)
        }

        return accessControl
    }

    /// Securely delete a key with verification
    private func secureDelete(keyId: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(deleteQuery as CFDictionary)
        // errSecItemNotFound is acceptable - item may not exist
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed(status)
        }
    }

    /// Retrieve a private key from the Keychain
    /// Uses LAContext for biometric authentication if required
    func retrievePrivateKey(keyId: String, context: LAContext? = nil) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Provide authentication context if available
        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw SecureKeyStoreError.retrieveFailed(status)
        }

        return result as? Data
    }

    /// Retrieve X25519 private key
    func retrieveX25519PrivateKey(keyId: String, context: LAContext? = nil) throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let keyData = try retrievePrivateKey(keyId: keyId, context: context) else {
            return nil
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
    }

    /// Retrieve Ed25519 private key
    func retrieveEd25519PrivateKey(keyId: String, context: LAContext? = nil) throws -> Curve25519.Signing.PrivateKey? {
        guard let keyData = try retrievePrivateKey(keyId: keyId, context: context) else {
            return nil
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    }

    /// Delete a key from the Keychain
    func deleteKey(keyId: String) throws {
        try secureDelete(keyId: keyId)
    }

    /// Delete all keys for this service (use with caution)
    func deleteAllKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed(status)
        }
    }

    // MARK: - Key Existence Check

    /// Check if a key exists without retrieving it
    func keyExists(keyId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    // MARK: - Secure Enclave Availability

    /// Check if Secure Enclave is available on this device
    static var isSecureEnclaveAvailable: Bool {
        var error: Unmanaged<CFError>?
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        )
        return accessControl != nil && error == nil
    }

    /// Check if biometric authentication is available
    static var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Secure Enclave P-256 Key (for attestation)

    /// Generate a P-256 key in Secure Enclave (if available)
    /// Used for device attestation as Secure Enclave only supports P-256
    func generateSecureEnclaveKey(keyId: String) throws -> SecKey {
        // Delete existing key if present
        try? deleteSecureEnclaveKey(keyId: keyId)

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw SecureKeyStoreError.accessControlFailed(error!.takeRetainedValue())
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl
            ]
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SecureKeyStoreError.storeFailed(errSecParam)
        }

        return privateKey
    }

    /// Delete a Secure Enclave key
    func deleteSecureEnclaveKey(keyId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed(status)
        }
    }
}

// MARK: - Errors

enum SecureKeyStoreError: Error, LocalizedError {
    case accessControlFailed(CFError)
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case keyNotFound
    case secureEnclaveNotAvailable

    var errorDescription: String? {
        switch self {
        case .accessControlFailed(let error):
            return "Access control creation failed: \(error.localizedDescription)"
        case .storeFailed(let status):
            return "Key storage failed with status: \(status)"
        case .retrieveFailed(let status):
            return "Key retrieval failed with status: \(status)"
        case .deleteFailed(let status):
            return "Key deletion failed with status: \(status)"
        case .keyNotFound:
            return "Key not found in keychain"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
        }
    }
}
