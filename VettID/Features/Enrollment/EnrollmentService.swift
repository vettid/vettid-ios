import Foundation
import CryptoKit

/// Handles the complete enrollment flow for new credentials
@MainActor
final class EnrollmentService: ObservableObject {

    @Published var state: EnrollmentState = .idle
    @Published var error: EnrollmentError?

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()
    private let secureKeyStore = SecureKeyStore()
    private let attestationManager = AttestationManager()

    // MARK: - Enrollment Flow

    /// Begin enrollment with an invitation code (from QR or manual entry)
    func enroll(invitationCode: String) async {
        state = .generatingKeys

        do {
            // Step 1: Generate cryptographic keys
            let keys = try await generateKeys()

            state = .attestingDevice

            // Step 2: Attest device with App Attest
            let attestationData = try await prepareAttestation(keys: keys)

            state = .registeringWithServer

            // Step 3: Register with ledger service
            let response = try await registerWithLedger(
                invitationCode: invitationCode,
                keys: keys,
                attestationData: attestationData
            )

            state = .storingCredential

            // Step 4: Store credential securely
            try storeCredential(response: response, keys: keys)

            state = .completed(credentialId: response.credentialId)

        } catch let enrollmentError as EnrollmentError {
            self.error = enrollmentError
            state = .failed(enrollmentError)
        } catch {
            let wrappedError = EnrollmentError.unexpected(error)
            self.error = wrappedError
            state = .failed(wrappedError)
        }
    }

    // MARK: - Key Generation

    private func generateKeys() async throws -> GeneratedKeys {
        // Generate CEK (Credential Encryption Key) - X25519
        let cekKeyPair = CryptoManager.generateX25519KeyPair()

        // Generate signing key - Ed25519
        let signingKeyPair = CryptoManager.generateEd25519KeyPair()

        // Generate initial pool of 20 transaction keys - X25519
        var transactionKeys: [TransactionKey] = []
        for i in 0..<20 {
            let tkKeyPair = CryptoManager.generateX25519KeyPair()
            transactionKeys.append(TransactionKey(
                keyId: "tk-\(UUID().uuidString)",
                privateKey: tkKeyPair.privateKey.rawRepresentation,
                publicKey: tkKeyPair.publicKey.rawRepresentation,
                isUsed: false
            ))
        }

        return GeneratedKeys(
            cekPrivateKey: cekKeyPair.privateKey,
            cekPublicKey: cekKeyPair.publicKey,
            signingPrivateKey: signingKeyPair.privateKey,
            signingPublicKey: signingKeyPair.publicKey,
            transactionKeys: transactionKeys
        )
    }

    // MARK: - Device Attestation

    private func prepareAttestation(keys: GeneratedKeys) async throws -> EnrollmentAttestationData {
        guard attestationManager.isSupported else {
            throw EnrollmentError.attestationNotSupported
        }

        let keyId = try await attestationManager.generateAttestationKey()
        let deviceId = await getDeviceId()

        return try await attestationManager.prepareEnrollmentAttestation(
            keyId: keyId,
            credentialPublicKey: keys.cekPublicKey.rawRepresentation,
            deviceId: deviceId
        )
    }

    private func getDeviceId() async -> String {
        // Use a consistent device identifier
        // In production, consider using identifierForVendor or a stored UUID
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    // MARK: - Server Registration

    private func registerWithLedger(
        invitationCode: String,
        keys: GeneratedKeys,
        attestationData: EnrollmentAttestationData
    ) async throws -> EnrollmentResponse {
        let deviceId = await getDeviceId()

        let request = EnrollmentRequest(
            invitationCode: invitationCode,
            deviceId: deviceId,
            cekPublicKey: keys.cekPublicKey.rawRepresentation,
            signingPublicKey: keys.signingPublicKey.rawRepresentation,
            transactionPublicKeys: keys.transactionKeys.map { $0.publicKey },
            attestationData: attestationData.attestation
        )

        do {
            return try await apiClient.enroll(request: request)
        } catch {
            throw EnrollmentError.serverRegistrationFailed(error)
        }
    }

    // MARK: - Credential Storage

    private func storeCredential(response: EnrollmentResponse, keys: GeneratedKeys) throws {
        let credential = StoredCredential(
            credentialId: response.credentialId,
            vaultId: response.vaultId,
            cekPrivateKey: keys.cekPrivateKey.rawRepresentation,
            cekPublicKey: keys.cekPublicKey.rawRepresentation,
            signingPrivateKey: keys.signingPrivateKey.rawRepresentation,
            signingPublicKey: keys.signingPublicKey.rawRepresentation,
            latCurrent: response.lat,
            transactionKeys: keys.transactionKeys,
            createdAt: Date(),
            lastUsedAt: Date()
        )

        do {
            try credentialStore.store(credential: credential)
        } catch {
            throw EnrollmentError.storageFailed(error)
        }
    }
}

// MARK: - Supporting Types

struct GeneratedKeys {
    let cekPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let cekPublicKey: Curve25519.KeyAgreement.PublicKey
    let signingPrivateKey: Curve25519.Signing.PrivateKey
    let signingPublicKey: Curve25519.Signing.PublicKey
    let transactionKeys: [TransactionKey]
}

enum EnrollmentState: Equatable {
    case idle
    case generatingKeys
    case attestingDevice
    case registeringWithServer
    case storingCredential
    case completed(credentialId: String)
    case failed(EnrollmentError)

    var description: String {
        switch self {
        case .idle:
            return "Ready to enroll"
        case .generatingKeys:
            return "Generating cryptographic keys..."
        case .attestingDevice:
            return "Verifying device integrity..."
        case .registeringWithServer:
            return "Registering with VettID..."
        case .storingCredential:
            return "Securing credential..."
        case .completed:
            return "Enrollment complete!"
        case .failed(let error):
            return "Failed: \(error.localizedDescription)"
        }
    }
}

enum EnrollmentError: Error, Equatable {
    case attestationNotSupported
    case keyGenerationFailed(String)
    case serverRegistrationFailed(Error)
    case storageFailed(Error)
    case invalidInvitationCode
    case unexpected(Error)

    static func == (lhs: EnrollmentError, rhs: EnrollmentError) -> Bool {
        switch (lhs, rhs) {
        case (.attestationNotSupported, .attestationNotSupported):
            return true
        case (.invalidInvitationCode, .invalidInvitationCode):
            return true
        case let (.keyGenerationFailed(a), .keyGenerationFailed(b)):
            return a == b
        default:
            return false
        }
    }

    var localizedDescription: String {
        switch self {
        case .attestationNotSupported:
            return "Device attestation is not supported on this device"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .serverRegistrationFailed(let error):
            return "Server registration failed: \(error.localizedDescription)"
        case .storageFailed(let error):
            return "Failed to store credential: \(error.localizedDescription)"
        case .invalidInvitationCode:
            return "The invitation code is invalid or expired"
        case .unexpected(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}
