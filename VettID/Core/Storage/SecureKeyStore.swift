import Foundation
import Security
import CryptoKit

/// Manages cryptographic keys with Secure Enclave support where available
final class SecureKeyStore {

    private let service = "com.vettid.keys"

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
            requireBiometric: requireBiometric
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
            requireBiometric: requireBiometric
        )

        return keyPair
    }

    // MARK: - Key Storage

    private func storePrivateKey(
        _ keyData: Data,
        keyId: String,
        requireBiometric: Bool
    ) throws {
        var accessControl: SecAccessControl?

        if requireBiometric {
            var error: Unmanaged<CFError>?
            accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.biometryCurrentSet, .privateKeyUsage],
                &error
            )

            if let error = error?.takeRetainedValue() {
                throw SecureKeyStoreError.accessControlFailed(error)
            }
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: keyData,
            kSecAttrService as String: service
        ]

        if let accessControl = accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        // Delete existing key if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.storeFailed(status)
        }
    }

    /// Retrieve a private key from the Keychain
    func retrievePrivateKey(keyId: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service,
            kSecReturnData as String: true
        ]

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
    func retrieveX25519PrivateKey(keyId: String) throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let keyData = try retrievePrivateKey(keyId: keyId) else {
            return nil
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
    }

    /// Retrieve Ed25519 private key
    func retrieveEd25519PrivateKey(keyId: String) throws -> Curve25519.Signing.PrivateKey? {
        guard let keyData = try retrievePrivateKey(keyId: keyId) else {
            return nil
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    }

    /// Delete a key from the Keychain
    func deleteKey(keyId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyId.data(using: .utf8)!,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.deleteFailed(status)
        }
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
}

// MARK: - Errors

enum SecureKeyStoreError: Error {
    case accessControlFailed(CFError)
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case keyNotFound
}
