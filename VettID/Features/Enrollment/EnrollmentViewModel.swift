import Foundation
import SwiftUI

/// Manages the complete enrollment flow state
@MainActor
final class EnrollmentViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: EnrollmentState = .initial
    @Published var scannedCode: String?
    @Published var password: String = ""
    @Published var confirmPassword: String = ""
    @Published var passwordStrength: PasswordStrength = .weak
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - Session Data

    private var enrollmentSessionId: String?
    private var userGuid: String?
    private var transactionKeys: [TransactionKeyInfo] = []
    private var passwordKeyId: String?
    private var attestationKeyId: String?
    private var attestationChallenge: String?
    private var memberAuthToken: String?

    // MARK: - Dependencies

    private let apiClient = APIClient()
    private let credentialStore = CredentialStore()
    private let attestationManager = AttestationManager()

    // MARK: - Enrollment State

    enum EnrollmentState: Equatable {
        case initial
        case scanningQR
        case processingInvitation
        case attestationRequired(challenge: String)
        case attesting(progress: Double)
        case attestationComplete
        case settingPassword
        case processingPassword
        case finalizing
        case settingUpNats
        case complete(userGuid: String)
        case error(message: String, retryable: Bool)

        var title: String {
            switch self {
            case .initial, .scanningQR:
                return "Scan QR Code"
            case .processingInvitation:
                return "Processing..."
            case .attestationRequired, .attesting:
                return "Device Verification"
            case .attestationComplete, .settingPassword, .processingPassword:
                return "Create Password"
            case .finalizing:
                return "Completing Setup"
            case .settingUpNats:
                return "Setting Up Messaging"
            case .complete:
                return "Welcome to VettID"
            case .error:
                return "Error"
            }
        }

        var canGoBack: Bool {
            switch self {
            case .initial, .scanningQR, .settingPassword:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Password Strength

    enum PasswordStrength: Int, Comparable {
        case weak = 0
        case fair = 1
        case good = 2
        case strong = 3
        case veryStrong = 4

        static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var color: Color {
            switch self {
            case .weak: return .red
            case .fair: return .orange
            case .good: return .yellow
            case .strong: return .green
            case .veryStrong: return .green
            }
        }

        var label: String {
            switch self {
            case .weak: return "Weak"
            case .fair: return "Fair"
            case .good: return "Good"
            case .strong: return "Strong"
            case .veryStrong: return "Very Strong"
            }
        }
    }

    // MARK: - Password Validation

    var isPasswordValid: Bool {
        password.count >= 12 &&
        password == confirmPassword &&
        passwordStrength >= .good
    }

    var passwordValidationErrors: [String] {
        var errors: [String] = []

        if password.count < 12 {
            errors.append("At least 12 characters required")
        }
        if !password.isEmpty && passwordStrength < .good {
            errors.append("Password is too weak")
        }
        if !confirmPassword.isEmpty && password != confirmPassword {
            errors.append("Passwords don't match")
        }

        return errors
    }

    // MARK: - Password Strength Calculation

    func updatePasswordStrength() {
        passwordStrength = calculateStrength(password)
    }

    private func calculateStrength(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .weak }

        var score = 0

        // Length scoring
        if password.count >= 12 { score += 1 }
        if password.count >= 16 { score += 1 }
        if password.count >= 20 { score += 1 }

        // Character variety
        let hasLowercase = password.range(of: "[a-z]", options: .regularExpression) != nil
        let hasUppercase = password.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasNumbers = password.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = password.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil

        let varietyCount = [hasLowercase, hasUppercase, hasNumbers, hasSpecial].filter { $0 }.count
        score += varietyCount

        // Map score to strength
        switch score {
        case 0...2: return .weak
        case 3: return .fair
        case 4: return .good
        case 5...6: return .strong
        default: return .veryStrong
        }
    }

    // MARK: - Enrollment Flow Actions

    func startScanning() {
        state = .scanningQR
        errorMessage = nil
    }

    func handleScannedCode(_ code: String) async {
        scannedCode = code
        state = .processingInvitation

        do {
            // Parse invitation code from QR
            let invitationCode = parseInvitationCode(code)

            // Call API to start enrollment
            let deviceId = getDeviceId()
            let request = EnrollStartRequest(
                invitationCode: invitationCode,
                deviceId: deviceId,
                attestationData: ""  // Will be sent in attestation step
            )

            let response = try await apiClient.enrollStart(request: request)

            // Store session data
            enrollmentSessionId = response.enrollmentSessionId
            userGuid = response.userGuid
            transactionKeys = response.transactionKeys
            passwordKeyId = response.passwordPrompt.useKeyId

            // Check if attestation is required and store challenge
            if response.attestationRequired == true,
               let challenge = response.attestationChallenge {
                attestationChallenge = challenge
                state = .attestationRequired(challenge: challenge)
            } else {
                // Skip attestation if not required (unsupported device fallback)
                state = .attestationComplete
                await proceedToPassword()
            }

        } catch {
            handleError(error, retryable: true)
        }
    }

    func performAttestation() async {
        guard attestationManager.isSupported else {
            // Skip attestation for simulator/unsupported devices
            state = .attestationComplete
            await proceedToPassword()
            return
        }

        guard let sessionId = enrollmentSessionId,
              let challenge = attestationChallenge else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .attesting(progress: 0.0)

        do {
            // Step 1: Generate attestation key
            state = .attesting(progress: 0.2)
            let keyId = try await attestationManager.generateAttestationKey()
            attestationKeyId = keyId

            // Step 2: Attest key with Apple using the server challenge
            state = .attesting(progress: 0.4)
            let attestationObject = try await attestationManager.attestKeyWithChallenge(
                keyId: keyId,
                challengeBase64: challenge
            )

            // Step 3: Submit attestation to backend for verification
            state = .attesting(progress: 0.6)
            let attestationRequest = EnrollAttestationIOSRequest(
                enrollmentSessionId: sessionId,
                attestationObject: attestationObject.base64EncodedString(),
                keyId: keyId
            )

            // Note: memberAuthToken would come from Cognito JWT
            // For enrollment, the session ID acts as temporary auth
            let response = try await apiClient.enrollAttestationIOS(
                request: attestationRequest,
                authToken: memberAuthToken ?? sessionId
            )

            // Verify server response
            guard response.status == "attestation_verified" else {
                throw AttestationError.serverVerificationFailed(response.status)
            }

            // Step 4: Store keyId for future assertions
            state = .attesting(progress: 0.8)
            try attestationManager.storeKeyId(keyId)

            // Update password key ID from server response
            passwordKeyId = response.passwordKeyId

            state = .attesting(progress: 1.0)
            try await Task.sleep(nanoseconds: 300_000_000)

            state = .attestationComplete
            await proceedToPassword()

        } catch let error as AttestationError {
            // Handle attestation errors specifically
            handleError(error, retryable: true)
        } catch {
            // For other errors, provide option to retry
            handleError(error, retryable: true)
        }
    }

    private func proceedToPassword() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        state = .settingPassword
    }

    func submitPassword() async {
        guard isPasswordValid else { return }
        guard let sessionId = enrollmentSessionId,
              let keyId = passwordKeyId,
              let utk = transactionKeys.first(where: { $0.keyId == keyId }) else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .processingPassword

        do {
            // Hash password with Argon2id
            let hashResult = try PasswordHasher.hash(password: password)

            // Encrypt password hash with UTK
            let encryptedPayload = try CryptoManager.encryptPasswordHash(
                passwordHash: hashResult.hash,
                utkPublicKeyBase64: utk.publicKey
            )

            // Submit to API
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

            // Finalize enrollment
            await finalizeEnrollment()

        } catch {
            handleError(error, retryable: true)
        }
    }

    private func finalizeEnrollment() async {
        guard let sessionId = enrollmentSessionId else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .finalizing

        do {
            let request = EnrollFinalizeRequest(enrollmentSessionId: sessionId)
            let response = try await apiClient.enrollFinalize(request: request)

            guard response.status == "enrolled" else {
                throw EnrollmentError.finalizationFailed
            }

            // Store credential
            try storeCredential(package: response.credentialPackage, vaultStatus: response.vaultStatus)

            let completedUserGuid = response.credentialPackage.userGuid

            // Set up NATS account for real-time messaging
            await setupNatsAccount(authToken: memberAuthToken ?? sessionId)

            // Clear sensitive data
            clearSessionData()

            state = .complete(userGuid: completedUserGuid)

        } catch {
            handleError(error, retryable: true)
        }
    }

    /// Set up NATS account after enrollment for real-time vault communication
    private func setupNatsAccount(authToken: String) async {
        state = .settingUpNats

        do {
            // Check if account already exists
            let status = try await apiClient.getNatsStatus(authToken: authToken)

            if !status.hasAccount {
                // Create NATS account
                let accountResponse = try await apiClient.createNatsAccount(authToken: authToken)

                // Store account info
                let accountInfo = NatsAccountInfo(
                    ownerSpaceId: accountResponse.ownerSpaceId,
                    messageSpaceId: accountResponse.messageSpaceId,
                    status: accountResponse.status,
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                try NatsCredentialStore().saveAccountInfo(accountInfo)
            }

            // Generate initial NATS token for the app
            let tokenResponse = try await apiClient.generateNatsToken(
                request: .app(deviceId: getDeviceId()),
                authToken: authToken
            )

            // Store credentials for later connection
            let credentials = NatsCredentials(from: tokenResponse)
            try NatsCredentialStore().saveCredentials(credentials)

        } catch {
            // NATS setup failure is not critical - user can set it up later
            // Log the error but don't fail enrollment
            #if DEBUG
            print("[Enrollment] NATS setup failed: \(error.localizedDescription)")
            #endif
        }
    }

    func retry() {
        switch state {
        case .error(_, let retryable):
            if retryable {
                state = .initial
                errorMessage = nil
            }
        default:
            break
        }
    }

    func reset() {
        state = .initial
        scannedCode = nil
        password = ""
        confirmPassword = ""
        passwordStrength = .weak
        errorMessage = nil
        showError = false
        clearSessionData()
    }

    // MARK: - Private Helpers

    private func parseInvitationCode(_ qrContent: String) -> String {
        // QR code might be a URL or just the code
        if let url = URL(string: qrContent),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return code
        }
        // If not a URL, assume it's the raw code
        return qrContent
    }

    private func getDeviceId() -> String {
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    private func createClientDataHash() -> Data {
        let clientData = "\(getDeviceId()):\(Date().timeIntervalSince1970)"
        return clientData.data(using: .utf8) ?? Data()
    }

    private func storeCredential(package: CredentialPackage, vaultStatus: String) throws {
        let storedKeys = (package.transactionKeys ?? []).map { keyInfo in
            StoredUTK(
                keyId: keyInfo.keyId,
                publicKey: keyInfo.publicKey,
                algorithm: keyInfo.algorithm,
                isUsed: false
            )
        }

        // Mark password key as used
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
        attestationKeyId = nil
        attestationChallenge = nil
        memberAuthToken = nil
        password = ""
        confirmPassword = ""
    }

    private func handleError(_ error: Error, retryable: Bool) {
        let message: String
        if let enrollmentError = error as? EnrollmentError {
            message = enrollmentError.localizedDescription
        } else if let apiError = error as? APIError {
            message = apiError.localizedDescription
        } else if let attestationError = error as? AttestationError {
            message = attestationError.localizedDescription
        } else {
            message = error.localizedDescription
        }

        errorMessage = message
        state = .error(message: message, retryable: retryable)
    }

    /// Set the member auth token (from Cognito) for authenticated API calls
    func setMemberAuthToken(_ token: String) {
        memberAuthToken = token
    }
}

