import Foundation
import DeviceCheck
import CryptoKit

/// Manages App Attest for device integrity verification
final class AttestationManager {

    private let attestService = DCAppAttestService.shared

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

    /// Attest a key with Apple's servers
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

enum AttestationError: Error {
    case notSupported
    case keyGenerationFailed(Error)
    case attestationFailed(Error)
    case assertionFailed(Error)
    case unknownError

    var localizedDescription: String {
        switch self {
        case .notSupported:
            return "App Attest is not supported on this device"
        case .keyGenerationFailed(let error):
            return "Failed to generate attestation key: \(error.localizedDescription)"
        case .attestationFailed(let error):
            return "Attestation failed: \(error.localizedDescription)"
        case .assertionFailed(let error):
            return "Assertion generation failed: \(error.localizedDescription)"
        case .unknownError:
            return "An unknown attestation error occurred"
        }
    }
}
