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
    /// - standard: Device unlock only (no biometric required)
    /// - biometric: Biometric preferred with passcode fallback (recommended for most keys)
    /// - biometricStrict: Biometric only, NO passcode fallback (use with caution - risk of lockout)
    enum SecurityLevel {
        /// Keychain with device unlock protection only
        /// Key accessible whenever device is unlocked
        case standard

        /// Biometric authentication required, with device passcode as backup
        /// Recommended: Prevents account lockout if biometric hardware fails
        /// Uses .biometryCurrentSet to detect enrollment changes
        case biometric

        /// Biometric authentication required, NO passcode fallback
        /// WARNING: If biometric hardware fails, key is PERMANENTLY inaccessible
        /// Only use for keys that can be recovered through other means (e.g., server backup)
        case biometricStrict
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
            // Biometric with passcode fallback for hardware failure recovery
            // Uses .biometryCurrentSet to detect enrollment changes
            // Uses .or + .devicePasscode to allow passcode as backup authentication
            // This prevents account lockout if biometric hardware fails
            flags = [.biometryCurrentSet, .or, .devicePasscode, .privateKeyUsage]

        case .biometricStrict:
            // Biometric only - NO passcode fallback (maximum security)
            // WARNING: If biometric hardware fails, keys are permanently inaccessible
            // Only use this for keys that can be recovered through other means
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
    /// This performs an actual hardware check, not just API availability
    static var isSecureEnclaveAvailable: Bool {
        // Create attributes for a temporary SE key test
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            return false
        }

        // Try to create a test key in the Secure Enclave
        let testKeyTag = "com.vettid.se.availability.test.\(UUID().uuidString)"
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,  // Don't persist
                kSecAttrApplicationTag as String: testKeyTag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl
            ]
        ]

        var testError: Unmanaged<CFError>?
        let testKey = SecKeyCreateRandomKey(attributes as CFDictionary, &testError)

        // Secure Enclave is available if we could create a key
        return testKey != nil
    }

    /// Cached result of Secure Enclave availability check
    /// Computed once per app session for performance
    private static var _cachedSEAvailable: Bool?
    static var isSecureEnclaveAvailableCached: Bool {
        if let cached = _cachedSEAvailable {
            return cached
        }
        let available = isSecureEnclaveAvailable
        _cachedSEAvailable = available
        return available
    }

    /// Check if biometric authentication is available
    static var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Key Protection Level

    /// Protection level of a stored key
    enum KeyProtectionLevel {
        case secureEnclave      // Key is in Secure Enclave hardware
        case keychainProtected  // Key is in Keychain with software protection
        case unknown            // Unable to determine
        case notFound           // Key doesn't exist
    }

    /// Check the protection level of a stored key
    /// - Parameter keyId: The key identifier to check
    /// - Returns: The protection level of the key
    func getKeyProtectionLevel(keyId: String) -> KeyProtectionLevel {
        // First, try to find a Secure Enclave key
        let seQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var seResult: AnyObject?
        let seStatus = SecItemCopyMatching(seQuery as CFDictionary, &seResult)
        if seStatus == errSecSuccess {
            return .secureEnclave
        }

        // Check for regular Keychain key
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainResult: AnyObject?
        let keychainStatus = SecItemCopyMatching(keychainQuery as CFDictionary, &keychainResult)
        if keychainStatus == errSecSuccess {
            return .keychainProtected
        }

        if seStatus == errSecItemNotFound && keychainStatus == errSecItemNotFound {
            return .notFound
        }

        return .unknown
    }

    /// Verify that a key meets minimum security requirements
    /// - Parameters:
    ///   - keyId: The key identifier to verify
    ///   - requireSecureEnclave: If true, key must be in Secure Enclave
    /// - Returns: True if key meets requirements
    func verifyKeyProtection(keyId: String, requireSecureEnclave: Bool = false) -> Bool {
        let level = getKeyProtectionLevel(keyId: keyId)

        switch level {
        case .secureEnclave:
            return true
        case .keychainProtected:
            return !requireSecureEnclave
        case .unknown, .notFound:
            return false
        }
    }

    // MARK: - Secure Enclave P-256 Key Generation

    /// Result of Secure Enclave key generation
    struct SecureEnclaveKeyResult {
        let privateKey: SecKey
        let publicKey: SecKey
        let isSecureEnclaveProtected: Bool
    }

    /// Generate a P-256 key, preferring Secure Enclave when available
    ///
    /// Secure Enclave provides hardware-level protection:
    /// - Private key never leaves the SE hardware
    /// - Resistant to software attacks even with root access
    /// - Keys are bound to the specific device
    ///
    /// When SE is not available, falls back to Keychain-protected software key.
    ///
    /// - Parameters:
    ///   - keyId: Unique identifier for the key
    ///   - requireBiometric: If true, key access requires biometric authentication
    ///   - allowFallback: If true, falls back to software key when SE unavailable
    /// - Returns: SecureEnclaveKeyResult with the key and protection status
    /// - Throws: SecureKeyStoreError if key generation fails
    func generateSecureEnclaveKeyWithFallback(
        keyId: String,
        requireBiometric: Bool = false,
        allowFallback: Bool = true
    ) throws -> SecureEnclaveKeyResult {
        // Delete existing key if present
        try? deleteSecureEnclaveKey(keyId: keyId)
        try? secureDelete(keyId: keyId)

        // Try Secure Enclave first
        if Self.isSecureEnclaveAvailableCached {
            do {
                let seKey = try generateSecureEnclaveKey(keyId: keyId, requireBiometric: requireBiometric)
                guard let publicKey = SecKeyCopyPublicKey(seKey) else {
                    throw SecureKeyStoreError.storeFailed(errSecInternalError)
                }
                return SecureEnclaveKeyResult(
                    privateKey: seKey,
                    publicKey: publicKey,
                    isSecureEnclaveProtected: true
                )
            } catch {
                #if DEBUG
                print("[SecureKeyStore] Secure Enclave key generation failed: \(error)")
                #endif
                if !allowFallback {
                    throw error
                }
            }
        }

        // Fallback to software key in Keychain
        guard allowFallback else {
            throw SecureKeyStoreError.secureEnclaveNotAvailable
        }

        #if DEBUG
        print("[SecureKeyStore] Using software key fallback for \(keyId)")
        #endif

        let softwareKey = try generateSoftwareP256Key(keyId: keyId, requireBiometric: requireBiometric)
        guard let publicKey = SecKeyCopyPublicKey(softwareKey) else {
            throw SecureKeyStoreError.storeFailed(errSecInternalError)
        }

        return SecureEnclaveKeyResult(
            privateKey: softwareKey,
            publicKey: publicKey,
            isSecureEnclaveProtected: false
        )
    }

    /// Generate a P-256 key strictly in Secure Enclave (no fallback)
    ///
    /// Use this when hardware protection is mandatory (e.g., device attestation keys).
    /// Will throw if Secure Enclave is not available.
    ///
    /// - Parameters:
    ///   - keyId: Unique identifier for the key
    ///   - requireBiometric: If true, key access requires biometric authentication
    /// - Returns: The SE-protected private key
    /// - Throws: SecureKeyStoreError.secureEnclaveNotAvailable if SE not available
    func generateSecureEnclaveKey(keyId: String, requireBiometric: Bool = false) throws -> SecKey {
        guard Self.isSecureEnclaveAvailableCached else {
            throw SecureKeyStoreError.secureEnclaveNotAvailable
        }

        // Delete existing key if present
        try? deleteSecureEnclaveKey(keyId: keyId)

        var error: Unmanaged<CFError>?
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requireBiometric {
            flags.insert(.biometryCurrentSet)
        }

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
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
            if let cfError = error?.takeRetainedValue() {
                throw SecureKeyStoreError.accessControlFailed(cfError)
            }
            throw SecureKeyStoreError.storeFailed(errSecParam)
        }

        return privateKey
    }

    /// Generate a software P-256 key in Keychain (fallback when SE unavailable)
    private func generateSoftwareP256Key(keyId: String, requireBiometric: Bool) throws -> SecKey {
        var error: Unmanaged<CFError>?
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requireBiometric {
            flags.insert(.biometryCurrentSet)
            flags.insert(.or)
            flags.insert(.devicePasscode)
        }

        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        )

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
                kSecAttrSynchronizable as String: false
            ]
        ]

        if let ac = accessControl {
            var privateAttrs = attributes[kSecPrivateKeyAttrs as String] as! [String: Any]
            privateAttrs[kSecAttrAccessControl as String] = ac
            attributes[kSecPrivateKeyAttrs as String] = privateAttrs
        }

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let cfError = error?.takeRetainedValue() {
                throw SecureKeyStoreError.accessControlFailed(cfError)
            }
            throw SecureKeyStoreError.storeFailed(errSecParam)
        }

        return privateKey
    }

    /// Retrieve a Secure Enclave or software P-256 key
    func retrieveP256Key(keyId: String, context: LAContext? = nil) throws -> SecKey? {
        // Try Secure Enclave first
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let key = result {
            return (key as! SecKey)
        }

        if status == errSecItemNotFound {
            return nil
        }

        throw SecureKeyStoreError.retrieveFailed(status)
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

    /// Delete any P-256 key (SE or software)
    func deleteP256Key(keyId: String) throws {
        // Delete SE key
        try? deleteSecureEnclaveKey(keyId: keyId)

        // Delete software key
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
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
