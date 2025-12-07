import Foundation
import SwiftUI

/// Manages the complete authentication flow with action-based security
///
/// Flow:
/// 1. Request action token → receive LAT for verification and UTK key ID
/// 2. Display LAT verification to user (anti-phishing)
/// 3. User enters password
/// 4. Execute authentication → receive updated credential package
/// 5. Update stored credential with rotated keys
@MainActor
final class AuthenticationViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: AuthenticationState = .initial
    @Published var password: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - LAT Verification Display

    @Published var serverLatId: String = ""
    @Published var latVerified: Bool = false

    // MARK: - Session Data

    private var actionToken: String?
    private var useKeyId: String?
    private var serverLAT: LedgerAuthToken?
    private var actionEndpoint: String?
    private var tokenExpiresAt: Date?

    // MARK: - Dependencies

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()

    // MARK: - Authentication State

    enum AuthenticationState: Equatable {
        case initial
        case requestingToken
        case verifyingLAT
        case awaitingPassword
        case authenticating
        case success
        case credentialRotated(newCekVersion: Int, newLatVersion: Int)
        case error(message: String, retryable: Bool)

        var title: String {
            switch self {
            case .initial:
                return "Authenticate"
            case .requestingToken:
                return "Connecting..."
            case .verifyingLAT:
                return "Verify Server"
            case .awaitingPassword:
                return "Enter Password"
            case .authenticating:
                return "Authenticating..."
            case .success, .credentialRotated:
                return "Success"
            case .error:
                return "Error"
            }
        }

        var canGoBack: Bool {
            switch self {
            case .initial, .verifyingLAT, .awaitingPassword:
                return true
            default:
                return false
            }
        }

        var isProcessing: Bool {
            switch self {
            case .requestingToken, .authenticating:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Step 1: Request Action Token

    /// Begin authentication by requesting an action token
    /// - Parameter cognitoToken: AWS Cognito authentication token (optional for now)
    func requestActionToken(cognitoToken: String = "") async {
        state = .requestingToken
        errorMessage = nil

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                throw AuthenticationError.noCredential
            }

            let request = ActionRequestBody(
                userGuid: credential.userGuid,
                actionType: ActionType.authenticate.rawValue,
                deviceFingerprint: getDeviceFingerprint()
            )

            let response = try await apiClient.actionRequest(request: request, cognitoToken: cognitoToken)

            // Store session data
            actionToken = response.actionToken
            useKeyId = response.useKeyId
            serverLAT = response.ledgerAuthToken
            actionEndpoint = response.actionEndpoint

            // Parse expiration
            let formatter = ISO8601DateFormatter()
            tokenExpiresAt = formatter.date(from: response.actionTokenExpiresAt)

            // Set LAT display for verification
            serverLatId = response.ledgerAuthToken.latId

            // Move to LAT verification step
            state = .verifyingLAT

        } catch {
            handleError(error, retryable: true)
        }
    }

    // MARK: - Step 2: Verify LAT (Anti-Phishing)

    /// Verify that the server's LAT matches our stored LAT
    /// Returns true if LAT matches, false if potential phishing
    func verifyLAT() -> Bool {
        guard let serverLAT = serverLAT,
              let credential = try? credentialStore.retrieveFirst() else {
            return false
        }

        let matches = credential.ledgerAuthToken.matches(serverLAT)
        latVerified = matches
        return matches
    }

    /// User confirms LAT verification and proceeds to password entry
    func confirmLATVerification() {
        guard verifyLAT() else {
            handleError(AuthenticationError.latMismatch, retryable: false)
            return
        }

        state = .awaitingPassword
    }

    /// User reports LAT mismatch (potential phishing)
    func reportLATMismatch() {
        handleError(AuthenticationError.latMismatch, retryable: false)
    }

    // MARK: - Step 3: Execute Authentication

    /// Execute authentication with password
    func authenticate() async {
        guard let token = actionToken,
              let keyId = useKeyId else {
            handleError(AuthenticationError.invalidState, retryable: false)
            return
        }

        // Check token expiration
        if let expiresAt = tokenExpiresAt, Date() > expiresAt {
            handleError(AuthenticationError.tokenExpired, retryable: true)
            return
        }

        guard !password.isEmpty else {
            handleError(AuthenticationError.emptyPassword, retryable: true)
            return
        }

        state = .authenticating

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                throw AuthenticationError.noCredential
            }

            // Find the UTK to use
            guard let utk = credential.getKey(byId: keyId) else {
                throw AuthenticationError.keyNotFound
            }

            guard !utk.isUsed else {
                throw AuthenticationError.keyAlreadyUsed
            }

            // Hash password with Argon2id (or PBKDF2 fallback)
            let hashResult = try PasswordHasher.hash(password: password)

            // Encrypt password hash with UTK
            let encryptedPayload = try CryptoManager.encryptPasswordHash(
                passwordHash: hashResult.hash,
                utkPublicKeyBase64: utk.publicKey
            )

            // Build request
            let request = AuthExecuteRequest(
                encryptedBlob: credential.encryptedBlob,
                cekVersion: credential.cekVersion,
                encryptedPasswordHash: encryptedPayload.encryptedPasswordHash,
                ephemeralPublicKey: encryptedPayload.ephemeralPublicKey,
                nonce: encryptedPayload.nonce,
                keyId: keyId
            )

            let response = try await apiClient.authExecute(request: request, actionToken: token)

            guard response.status == "success" && response.actionResult.authenticated else {
                throw AuthenticationError.authenticationFailed
            }

            // Update stored credential with rotated package
            let updatedCredential = credential.updatedWith(
                package: response.credentialPackage,
                usedKeyId: response.usedKeyId
            )

            try credentialStore.update(credential: updatedCredential)

            // Clear sensitive data
            clearSessionData()

            // Show success with rotation info
            state = .credentialRotated(
                newCekVersion: response.credentialPackage.cekVersion,
                newLatVersion: response.credentialPackage.ledgerAuthToken.version
            )

        } catch {
            handleError(error, retryable: error is AuthenticationError ? (error as! AuthenticationError).isRetryable : true)
        }
    }

    // MARK: - Credential Info

    /// Get remaining unused key count
    var remainingKeyCount: Int {
        guard let credential = try? credentialStore.retrieveFirst() else {
            return 0
        }
        return credential.unusedKeyCount
    }

    /// Check if user needs to re-enroll (no keys left)
    var needsReenrollment: Bool {
        remainingKeyCount == 0
    }

    // MARK: - Reset

    func reset() {
        state = .initial
        password = ""
        errorMessage = nil
        showError = false
        serverLatId = ""
        latVerified = false
        clearSessionData()
    }

    // MARK: - Private Helpers

    private func clearSessionData() {
        actionToken = nil
        useKeyId = nil
        serverLAT = nil
        actionEndpoint = nil
        tokenExpiresAt = nil
        password = ""
    }

    private func getDeviceFingerprint() -> String {
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    private func handleError(_ error: Error, retryable: Bool) {
        let message: String
        if let authError = error as? AuthenticationError {
            message = authError.localizedDescription
        } else if let apiError = error as? APIError {
            message = apiError.localizedDescription
        } else {
            message = error.localizedDescription
        }

        errorMessage = message
        showError = true
        state = .error(message: message, retryable: retryable)
    }
}

// MARK: - Authentication Error

enum AuthenticationError: Error, LocalizedError {
    case noCredential
    case latMismatch
    case keyNotFound
    case keyAlreadyUsed
    case authenticationFailed
    case invalidState
    case tokenExpired
    case emptyPassword
    case apiError(APIError)
    case unexpected(Error)

    var isRetryable: Bool {
        switch self {
        case .noCredential, .latMismatch, .keyNotFound, .keyAlreadyUsed:
            return false
        case .authenticationFailed, .tokenExpired, .emptyPassword:
            return true
        case .invalidState:
            return false
        case .apiError:
            return true
        case .unexpected:
            return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCredential:
            return "No credential found. Please enroll first."
        case .latMismatch:
            return "Server verification failed. This may be a phishing attempt. Do not enter your password."
        case .keyNotFound:
            return "Transaction key not found"
        case .keyAlreadyUsed:
            return "Transaction key has already been used. Please try again."
        case .authenticationFailed:
            return "Authentication failed. Please check your password."
        case .invalidState:
            return "Invalid authentication state. Please try again."
        case .tokenExpired:
            return "Authentication session expired. Please try again."
        case .emptyPassword:
            return "Please enter your password."
        case .apiError(let error):
            return error.errorDescription
        case .unexpected(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}
