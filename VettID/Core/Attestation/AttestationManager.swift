import Foundation
import DeviceCheck
import CryptoKit
import Security

/// Manages App Attest for device integrity verification during enrollment
final class AttestationManager {

    private let attestService = DCAppAttestService.shared
    private let keychainService = "com.vettid.attestation"
    private let attestKeyIdKey = "vettid_app_attest_key_id"

    // MARK: - Attestation Support

    /// Check if App Attest is supported on this device
    var isSupported: Bool {
        attestService.isSupported
    }

    // MARK: - Key Generation

    /// Generate a new attestation key
    func generateAttestationKey() async throws -> String {
        guard isSupported else {
            throw AttestationError.notSupported
        }

        return try await withCheckedThrowingContinuation { continuation in
            attestService.generateKey { keyId, error in
                if let error = error {
                    continuation.resume(throwing: AttestationError.keyGenerationFailed(error))
                } else if let keyId = keyId {
                    continuation.resume(returning: keyId)
                } else {
                    continuation.resume(throwing: AttestationError.unknownError)
                }
            }
        }
    }

    // MARK: - Attestation

    /// Attest a key with Apple's servers using the session challenge
    func attestKey(keyId: String, clientData: Data) async throws -> Data {
        guard isSupported else {
            throw AttestationError.notSupported
        }

        // Create hash of client data for attestation
        let clientDataHash = SHA256.hash(data: clientData)
        let hashData = Data(clientDataHash)

        return try await withCheckedThrowingContinuation { continuation in
            attestService.attestKey(keyId, clientDataHash: hashData) { attestation, error in
                if let error = error {
                    continuation.resume(throwing: AttestationError.attestationFailed(error))
                } else if let attestation = attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: AttestationError.unknownError)
                }
            }
        }
    }

    /// Attest a key using the challenge from the enrollment session (base64 encoded)
    func attestKeyWithChallenge(keyId: String, challengeBase64: String) async throws -> Data {
        guard isSupported else {
            throw AttestationError.notSupported
        }

        guard let challengeData = Data(base64Encoded: challengeBase64) else {
            throw AttestationError.invalidChallenge
        }

        // Create client data hash from the challenge
        let clientDataHash = SHA256.hash(data: challengeData)
        let hashData = Data(clientDataHash)

        return try await withCheckedThrowingContinuation { continuation in
            attestService.attestKey(keyId, clientDataHash: hashData) { attestation, error in
                if let error = error {
                    continuation.resume(throwing: AttestationError.attestationFailed(error))
                } else if let attestation = attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: AttestationError.unknownError)
                }
            }
        }
    }

    // MARK: - Key Storage

    /// Store the attestation key ID in Keychain for future assertions
    func storeKeyId(_ keyId: String) throws {
        // Delete existing key if present
        try? deleteStoredKeyId()

        let keyIdData = keyId.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: attestKeyIdKey,
            kSecValueData as String: keyIdData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AttestationError.keyStorageFailed(status)
        }
    }

    /// Retrieve the stored attestation key ID
    func getStoredKeyId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: attestKeyIdKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let keyId = String(data: data, encoding: .utf8) else {
            return nil
        }

        return keyId
    }

    /// Delete the stored attestation key ID
    func deleteStoredKeyId() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: attestKeyIdKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AttestationError.keyDeletionFailed(status)
        }
    }

    /// Check if we have a stored attestation key ID
    var hasStoredKeyId: Bool {
        return getStoredKeyId() != nil
    }

    // MARK: - Assertions

    /// Generate an assertion for a request
    func generateAssertion(keyId: String, clientData: Data) async throws -> Data {
        guard isSupported else {
            throw AttestationError.notSupported
        }

        let clientDataHash = SHA256.hash(data: clientData)
        let hashData = Data(clientDataHash)

        return try await withCheckedThrowingContinuation { continuation in
            attestService.generateAssertion(keyId, clientDataHash: hashData) { assertion, error in
                if let error = error {
                    continuation.resume(throwing: AttestationError.assertionFailed(error))
                } else if let assertion = assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: AttestationError.unknownError)
                }
            }
        }
    }

    // MARK: - Enrollment Helper

    /// Prepare attestation data for enrollment request
    func prepareEnrollmentAttestation(
        keyId: String,
        credentialPublicKey: Data,
        deviceId: String
    ) async throws -> EnrollmentAttestationData {
        // Create client data that binds the attestation to the credential
        let clientData = EnrollmentClientData(
            credentialPublicKey: credentialPublicKey.base64EncodedString(),
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970
        )

        let clientDataJson = try JSONEncoder().encode(clientData)

        // Generate attestation
        let attestation = try await attestKey(keyId: keyId, clientData: clientDataJson)

        return EnrollmentAttestationData(
            keyId: keyId,
            attestation: attestation,
            clientData: clientDataJson
        )
    }

    /// Prepare assertion for authenticated requests
    func prepareRequestAssertion(
        keyId: String,
        requestBody: Data
    ) async throws -> Data {
        return try await generateAssertion(keyId: keyId, clientData: requestBody)
    }
}

// MARK: - Supporting Types

struct EnrollmentClientData: Codable {
    let credentialPublicKey: String
    let deviceId: String
    let timestamp: Double
}

struct EnrollmentAttestationData {
    let keyId: String
    let attestation: Data
    let clientData: Data
}

// MARK: - Errors

enum AttestationError: Error, LocalizedError {
    case notSupported
    case keyGenerationFailed(Error)
    case attestationFailed(Error)
    case assertionFailed(Error)
    case invalidChallenge
    case keyStorageFailed(OSStatus)
    case keyDeletionFailed(OSStatus)
    case serverVerificationFailed(String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest is not supported on this device"
        case .keyGenerationFailed(let error):
            return "Failed to generate attestation key: \(error.localizedDescription)"
        case .attestationFailed(let error):
            return "Attestation failed: \(error.localizedDescription)"
        case .assertionFailed(let error):
            return "Assertion generation failed: \(error.localizedDescription)"
        case .invalidChallenge:
            return "Invalid attestation challenge format"
        case .keyStorageFailed(let status):
            return "Failed to store attestation key: \(status)"
        case .keyDeletionFailed(let status):
            return "Failed to delete attestation key: \(status)"
        case .serverVerificationFailed(let message):
            return "Server attestation verification failed: \(message)"
        case .unknownError:
            return "An unknown attestation error occurred"
        }
    }
}
