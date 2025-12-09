import Foundation
import CryptoKit
import UIKit

/// Handles the complete multi-step enrollment flow for new credentials
///
/// Flow:
/// 1. Start enrollment with invitation code → receive UTKs
/// 2. User enters password → hash and encrypt with UTK → send to server
/// 3. Finalize enrollment → receive credential package
@MainActor
final class EnrollmentService: ObservableObject {

    @Published var state: EnrollmentState = .idle
    @Published var error: EnrollmentError?

    // Session data maintained across steps
    private var enrollmentSessionId: String?
    private var userGuid: String?
    private var transactionKeys: [TransactionKeyInfo] = []
    private var passwordKeyId: String?
    private var attestationChallenge: String?
    private var attestationKeyId: String?
    private var memberAuthToken: String?

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()
    private let attestationManager = AttestationManager()

    // MARK: - Step 1: Start Enrollment

    /// Begin enrollment with an invitation code (from QR or manual entry)
    func startEnrollment(invitationCode: String) async {
        state = .startingEnrollment

        do {
            // Get device ID
            let deviceId = getDeviceId()

            // Call API (attestation will be sent separately)
            let request = EnrollStartRequest(
                invitationCode: invitationCode,
                deviceId: deviceId,
                attestationData: ""  // Attestation sent in dedicated step
            )

            let response = try await apiClient.enrollStart(request: request)

            // Store session data for subsequent steps
            enrollmentSessionId = response.enrollmentSessionId
            userGuid = response.userGuid
            transactionKeys = response.transactionKeys
            passwordKeyId = response.passwordPrompt.useKeyId

            // Check if attestation is required
            if response.attestationRequired == true,
               let challenge = response.attestationChallenge {
                attestationChallenge = challenge
                state = .attestationRequired(challenge: challenge)
            } else {
                // Skip attestation if not required
                state = .awaitingPassword(prompt: response.passwordPrompt.message)
            }

        } catch {
            handleError(error)
        }
    }

    // MARK: - Step 1b: Device Attestation

    /// Perform device attestation with App Attest
    func performAttestation() async {
        guard attestationManager.isSupported else {
            // Skip attestation for unsupported devices
            if case .attestationRequired = state {
                state = .attestationComplete
                // Proceed to password after a brief delay
                try? await Task.sleep(nanoseconds: 500_000_000)
                state = .awaitingPassword(prompt: "Create a secure password")
            }
            return
        }

        guard let sessionId = enrollmentSessionId,
              let challenge = attestationChallenge else {
            self.error = .invalidState
            state = .failed(.invalidState)
            return
        }

        state = .attesting

        do {
            // Generate attestation key
            let keyId = try await attestationManager.generateAttestationKey()
            attestationKeyId = keyId

            // Attest key with Apple using server challenge
            let attestationObject = try await attestationManager.attestKeyWithChallenge(
                keyId: keyId,
                challengeBase64: challenge
            )

            // Submit attestation to backend
            let attestationRequest = EnrollAttestationIOSRequest(
                enrollmentSessionId: sessionId,
                attestationObject: attestationObject.base64EncodedString(),
                keyId: keyId
            )

            let response = try await apiClient.enrollAttestationIOS(
                request: attestationRequest,
                authToken: memberAuthToken ?? sessionId
            )

            // Verify server response
            guard response.status == "attestation_verified" else {
                throw EnrollmentError.attestationFailed
            }

            // Store keyId for future assertions
            try attestationManager.storeKeyId(keyId)

            // Update password key ID from server response
            passwordKeyId = response.passwordKeyId

            state = .attestationComplete

            // Proceed to password after a brief delay
            try? await Task.sleep(nanoseconds: 500_000_000)
            state = .awaitingPassword(prompt: "Create a secure password")

        } catch {
            handleError(error)
        }
    }

    // MARK: - Step 2: Set Password

    /// Set password during enrollment
    /// Call this after user enters their password in the UI
    func setPassword(_ password: String) async {
        guard let sessionId = enrollmentSessionId,
              let keyId = passwordKeyId,
              let utk = transactionKeys.first(where: { $0.keyId == keyId }) else {
            self.error = .invalidState
            state = .failed(.invalidState)
            return
        }

        state = .settingPassword

        do {
            // Hash password with Argon2id
            let hashResult = try PasswordHasher.hash(password: password)

            // Encrypt password hash with UTK
            let encryptedPayload = try CryptoManager.encryptPasswordHash(
                passwordHash: hashResult.hash,
                utkPublicKeyBase64: utk.publicKey
            )

            // Call API
            let request = EnrollSetPasswordRequest(
                enrollmentSessionId: sessionId,
                encryptedPasswordHash: encryptedPayload.encryptedPasswordHash,
                keyId: keyId,
                nonce: encryptedPayload.nonce
            )

            let response = try await apiClient.enrollSetPassword(request: request)

            guard response.status == "password_set" else {
                throw EnrollmentError.passwordSetFailed
            }

            // Proceed to finalize
            await finalizeEnrollment()

        } catch {
            handleError(error)
        }
    }

    // MARK: - Step 3: Finalize Enrollment

    /// Finalize enrollment and receive credential package
    private func finalizeEnrollment() async {
        guard let sessionId = enrollmentSessionId else {
            self.error = .invalidState
            state = .failed(.invalidState)
            return
        }

        state = .finalizingEnrollment

        do {
            let request = EnrollFinalizeRequest(enrollmentSessionId: sessionId)
            let response = try await apiClient.enrollFinalize(request: request)

            guard response.status == "enrolled" else {
                throw EnrollmentError.finalizationFailed
            }

            // Store credential
            state = .storingCredential
            try storeCredential(package: response.credentialPackage, vaultStatus: response.vaultStatus)

            // Clear session data
            clearSessionData()

            state = .completed(userGuid: response.credentialPackage.userGuid)

        } catch {
            handleError(error)
        }
    }

    // MARK: - Helpers

    private func getDeviceId() -> String {
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    private func storeCredential(package: CredentialPackage, vaultStatus: String) throws {
        // Convert transaction keys
        let storedKeys = (package.transactionKeys ?? []).map { keyInfo in
            StoredUTK(
                keyId: keyInfo.keyId,
                publicKey: keyInfo.publicKey,
                algorithm: keyInfo.algorithm,
                isUsed: false
            )
        }

        // Mark the password key as used
        var allKeys = storedKeys
        if let usedKeyId = passwordKeyId {
            allKeys = allKeys.map { key in
                if key.keyId == usedKeyId {
                    return StoredUTK(keyId: key.keyId, publicKey: key.publicKey, algorithm: key.algorithm, isUsed: true)
                }
                return key
            }
        }

        let credential = StoredCredential(
            userGuid: package.userGuid,
            encryptedBlob: package.encryptedBlob,
            cekVersion: package.cekVersion,
            ledgerAuthToken: StoredLAT(
                latId: package.ledgerAuthToken.latId,
                token: package.ledgerAuthToken.token,
                version: package.ledgerAuthToken.version
            ),
            transactionKeys: allKeys,
            createdAt: Date(),
            lastUsedAt: Date(),
            vaultStatus: vaultStatus
        )

        try credentialStore.store(credential: credential)
    }

    private func clearSessionData() {
        enrollmentSessionId = nil
        userGuid = nil
        transactionKeys = []
        passwordKeyId = nil
        attestationChallenge = nil
        attestationKeyId = nil
        memberAuthToken = nil
    }

    /// Set the member auth token (from Cognito) for authenticated API calls
    func setMemberAuthToken(_ token: String) {
        memberAuthToken = token
    }

    private func handleError(_ error: Error) {
        if let enrollmentError = error as? EnrollmentError {
            self.error = enrollmentError
            state = .failed(enrollmentError)
        } else if let apiError = error as? APIError {
            let wrappedError = EnrollmentError.apiError(apiError)
            self.error = wrappedError
            state = .failed(wrappedError)
        } else {
            let wrappedError = EnrollmentError.unexpected(error)
            self.error = wrappedError
            state = .failed(wrappedError)
        }
    }

    // MARK: - Reset

    /// Reset the enrollment service to initial state
    func reset() {
        state = .idle
        error = nil
        clearSessionData()
    }
}

// MARK: - Enrollment State

enum EnrollmentState: Equatable {
    case idle
    case startingEnrollment
    case attestationRequired(challenge: String)
    case attesting
    case attestationComplete
    case awaitingPassword(prompt: String)
    case settingPassword
    case finalizingEnrollment
    case storingCredential
    case completed(userGuid: String)
    case failed(EnrollmentError)

    static func == (lhs: EnrollmentState, rhs: EnrollmentState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.startingEnrollment, .startingEnrollment),
             (.attesting, .attesting),
             (.attestationComplete, .attestationComplete),
             (.settingPassword, .settingPassword),
             (.finalizingEnrollment, .finalizingEnrollment),
             (.storingCredential, .storingCredential):
            return true
        case let (.attestationRequired(a), .attestationRequired(b)):
            return a == b
        case let (.awaitingPassword(a), .awaitingPassword(b)):
            return a == b
        case let (.completed(a), .completed(b)):
            return a == b
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .idle:
            return "Ready to enroll"
        case .startingEnrollment:
            return "Starting enrollment..."
        case .attestationRequired:
            return "Device verification required"
        case .attesting:
            return "Verifying device..."
        case .attestationComplete:
            return "Device verified"
        case .awaitingPassword:
            return "Create your password"
        case .settingPassword:
            return "Setting password..."
        case .finalizingEnrollment:
            return "Finalizing enrollment..."
        case .storingCredential:
            return "Securing credential..."
        case .completed:
            return "Enrollment complete!"
        case .failed(let error):
            return "Failed: \(error.localizedDescription)"
        }
    }

    var isProcessing: Bool {
        switch self {
        case .startingEnrollment, .attesting, .settingPassword, .finalizingEnrollment, .storingCredential:
            return true
        default:
            return false
        }
    }
}

// MARK: - Enrollment Error

enum EnrollmentError: Error, Equatable, LocalizedError {
    case attestationNotSupported
    case attestationFailed
    case invalidInvitationCode
    case invitationExpired
    case passwordSetFailed
    case finalizationFailed
    case storageFailed
    case invalidState
    case apiError(APIError)
    case unexpected(Error)

    static func == (lhs: EnrollmentError, rhs: EnrollmentError) -> Bool {
        switch (lhs, rhs) {
        case (.attestationNotSupported, .attestationNotSupported),
             (.attestationFailed, .attestationFailed),
             (.invalidInvitationCode, .invalidInvitationCode),
             (.invitationExpired, .invitationExpired),
             (.passwordSetFailed, .passwordSetFailed),
             (.finalizationFailed, .finalizationFailed),
             (.storageFailed, .storageFailed),
             (.invalidState, .invalidState):
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .attestationNotSupported:
            return "Device attestation is not supported"
        case .attestationFailed:
            return "Device attestation failed verification"
        case .invalidInvitationCode:
            return "The invitation code is invalid"
        case .invitationExpired:
            return "The invitation code has expired"
        case .passwordSetFailed:
            return "Failed to set password"
        case .finalizationFailed:
            return "Failed to finalize enrollment"
        case .storageFailed:
            return "Failed to store credential"
        case .invalidState:
            return "Invalid enrollment state"
        case .apiError(let error):
            return error.errorDescription
        case .unexpected(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}
