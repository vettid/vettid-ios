import Foundation

/// Handles action-based authentication with the VettID ledger
///
/// Flow:
/// 1. Request action token → receive LAT for verification and UTK key ID
/// 2. Verify LAT matches stored LAT (phishing protection)
/// 3. Hash and encrypt password with specified UTK
/// 4. Execute authentication → receive updated credential package
@MainActor
final class AuthenticationService: ObservableObject {

    @Published var state: AuthState = .idle
    @Published var error: AuthError?

    // Session data for current auth flow
    private var actionToken: String?
    private var useKeyId: String?
    private var serverLAT: LedgerAuthToken?

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()

    // MARK: - Step 1: Request Action Token

    /// Begin authentication by requesting an action token
    /// - Parameters:
    ///   - cognitoToken: AWS Cognito authentication token
    ///   - actionType: Type of action to perform (default: authenticate)
    func requestActionToken(cognitoToken: String, actionType: ActionType = .authenticate) async {
        state = .requestingToken

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                throw AuthError.noCredential
            }

            let request = ActionRequestBody(
                userGuid: credential.userGuid,
                actionType: actionType.rawValue,
                deviceFingerprint: nil
            )

            let response = try await apiClient.actionRequest(request: request, cognitoToken: cognitoToken)

            // Store session data
            actionToken = response.actionToken
            useKeyId = response.useKeyId
            serverLAT = response.ledgerAuthToken

            // Verify LAT matches (phishing protection)
            guard credential.ledgerAuthToken.matches(response.ledgerAuthToken) else {
                throw AuthError.latMismatch
            }

            // Transition to awaiting password
            state = .awaitingPassword

        } catch {
            handleError(error)
        }
    }

    // MARK: - Step 2: Execute Authentication

    /// Execute authentication with password
    /// - Parameter password: User's password
    func authenticate(password: String) async {
        guard let token = actionToken,
              let keyId = useKeyId else {
            self.error = .invalidState
            state = .failed(.invalidState)
            return
        }

        state = .authenticating

        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                throw AuthError.noCredential
            }

            // Find the UTK to use
            guard let utk = credential.getKey(byId: keyId) else {
                throw AuthError.keyNotFound
            }

            guard !utk.isUsed else {
                throw AuthError.keyAlreadyUsed
            }

            // Hash password with Argon2id
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
                throw AuthError.authenticationFailed
            }

            // Update stored credential with new package
            let updatedCredential = credential.updatedWith(
                package: response.credentialPackage,
                usedKeyId: response.usedKeyId
            )

            try credentialStore.update(credential: updatedCredential)

            // Clear session data
            clearSessionData()

            state = .authenticated

        } catch {
            handleError(error)
        }
    }

    // MARK: - LAT Verification

    /// Verify that the server's LAT matches our stored LAT
    /// This is critical for phishing protection - ensures we're talking to the real server
    func verifyLAT() -> Bool {
        guard let serverLAT = serverLAT,
              let credential = try? credentialStore.retrieveFirst() else {
            return false
        }

        return credential.ledgerAuthToken.matches(serverLAT)
    }

    // MARK: - Helpers

    private func clearSessionData() {
        actionToken = nil
        useKeyId = nil
        serverLAT = nil
    }

    private func handleError(_ error: Error) {
        if let authError = error as? AuthError {
            self.error = authError
            state = .failed(authError)
        } else if let apiError = error as? APIError {
            let wrappedError = AuthError.apiError(apiError)
            self.error = wrappedError
            state = .failed(wrappedError)
        } else {
            let wrappedError = AuthError.unexpected(error)
            self.error = wrappedError
            state = .failed(wrappedError)
        }
    }

    // MARK: - Reset

    /// Reset the authentication service to initial state
    func reset() {
        state = .idle
        error = nil
        clearSessionData()
    }
}

// MARK: - Auth State

enum AuthState: Equatable {
    case idle
    case requestingToken
    case awaitingPassword
    case authenticating
    case authenticated
    case failed(AuthError)

    var description: String {
        switch self {
        case .idle:
            return "Ready to authenticate"
        case .requestingToken:
            return "Requesting authentication..."
        case .awaitingPassword:
            return "Enter your password"
        case .authenticating:
            return "Authenticating..."
        case .authenticated:
            return "Authentication successful"
        case .failed(let error):
            return "Failed: \(error.localizedDescription)"
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

// MARK: - Auth Error

enum AuthError: Error, Equatable, LocalizedError {
    case noCredential
    case latMismatch
    case keyNotFound
    case keyAlreadyUsed
    case authenticationFailed
    case invalidState
    case apiError(APIError)
    case unexpected(Error)

    static func == (lhs: AuthError, rhs: AuthError) -> Bool {
        switch (lhs, rhs) {
        case (.noCredential, .noCredential),
             (.latMismatch, .latMismatch),
             (.keyNotFound, .keyNotFound),
             (.keyAlreadyUsed, .keyAlreadyUsed),
             (.authenticationFailed, .authenticationFailed),
             (.invalidState, .invalidState):
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCredential:
            return "No credential found. Please enroll first."
        case .latMismatch:
            return "Server verification failed. This may be a phishing attempt."
        case .keyNotFound:
            return "Transaction key not found"
        case .keyAlreadyUsed:
            return "Transaction key has already been used"
        case .authenticationFailed:
            return "Authentication failed. Please check your password."
        case .invalidState:
            return "Invalid authentication state"
        case .apiError(let error):
            return error.errorDescription
        case .unexpected(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}
