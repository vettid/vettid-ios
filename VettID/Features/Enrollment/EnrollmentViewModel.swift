import Foundation
import SwiftUI

// MARK: - QR Code Data Model

/// Represents the JSON data encoded in enrollment QR codes
struct EnrollmentQRCodeData: Codable {
    let type: String
    let version: Int
    let apiUrl: String
    let sessionToken: String?      // For QR code flow (web-initiated)
    let invitationCode: String?    // For direct invitation code flow
    let userGuid: String

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case apiUrl = "api_url"
        case sessionToken = "session_token"
        case invitationCode = "invitation_code"
        case userGuid = "user_guid"
    }

    /// Whether this is a QR code flow (has session_token)
    var isQRFlow: Bool { sessionToken != nil }

    /// Whether this is an invitation code flow
    var isInvitationFlow: Bool { invitationCode != nil }
}

/// Manages the complete enrollment flow state
@MainActor
final class EnrollmentViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: EnrollmentState = .initial
    @Published var scannedCode: String?
    @Published var password: String = ""
    @Published var confirmPassword: String = ""
    @Published var passwordStrength: PasswordStrength = .weak
    @Published var pin: String = ""           // NEW: 6-digit vault PIN
    @Published var confirmPin: String = ""    // NEW: PIN confirmation
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - Session Data

    private var enrollmentToken: String?  // JWT from /vault/enroll/authenticate
    private var enrollmentSessionId: String?
    private var userGuid: String?
    private var transactionKeys: [TransactionKeyInfo] = []
    private var passwordKeyId: String?
    private var attestationKeyId: String?
    private var attestationChallenge: String?
    private var memberAuthToken: String?

    // MARK: - Dependencies

    private var apiClient: APIClient!
    private let credentialStore = CredentialStore()
    private let attestationManager = AttestationManager()

    // Nitro Enclave attestation
    private var enclavePublicKey: Data?  // Verified enclave key for password encryption
    private let nitroVerifier = NitroAttestationVerifier()

    // NATS-based enrollment (Architecture v2.0)
    private var enrollmentNatsHandler: EnrollmentNatsHandler?
    private var natsConnectionManager: NatsConnectionManager?
    private var natsBootstrapCredentials: NatsCredentials?
    private var natsOwnerSpace: String?
    private var vaultUTKs: [VaultReadyResponse.UTKInfo] = []
    private var useNatsFlow: Bool = true  // Enable NATS-based enrollment by default

    // MARK: - Enrollment State

    enum EnrollmentState: Equatable {
        case initial
        case scanningQR
        case processingInvitation
        case connectingToNats        // NATS flow: connecting with bootstrap creds
        case requestingAttestation   // NATS flow: requesting attestation from supervisor
        case attestationRequired(challenge: String)
        case attesting(progress: Double)
        case attestationComplete
        case settingPIN              // PIN setup step (before password in NATS flow)
        case processingPIN           // Sending PIN to supervisor
        case waitingForVault         // NATS flow: waiting for vault ready + UTKs
        case settingPassword
        case processingPassword
        case creatingCredential      // NATS flow: credential being created
        case finalizing
        case settingUpNats
        case verifyingEnrollment     // NATS flow: final verification
        case complete(userGuid: String)
        case error(message: String, retryable: Bool)

        var title: String {
            switch self {
            case .initial, .scanningQR:
                return "Scan QR Code"
            case .processingInvitation:
                return "Processing..."
            case .connectingToNats:
                return "Connecting..."
            case .requestingAttestation, .attestationRequired, .attesting:
                return "Device Verification"
            case .attestationComplete:
                return "Verified"
            case .settingPIN, .processingPIN:
                return "Create Vault PIN"
            case .waitingForVault:
                return "Initializing Vault"
            case .settingPassword, .processingPassword:
                return "Create Password"
            case .creatingCredential:
                return "Creating Credential"
            case .finalizing:
                return "Completing Setup"
            case .settingUpNats:
                return "Setting Up Messaging"
            case .verifyingEnrollment:
                return "Verifying..."
            case .complete:
                return "Welcome to VettID"
            case .error:
                return "Error"
            }
        }

        var canGoBack: Bool {
            switch self {
            case .initial, .scanningQR, .settingPassword, .settingPIN:
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

    // MARK: - PIN Validation

    /// Validate the 6-digit vault PIN
    var isPINValid: Bool {
        pin.count == 6 &&
        pin.allSatisfy { $0.isNumber } &&
        pin == confirmPin &&
        !isWeakPIN(pin)
    }

    var pinValidationErrors: [String] {
        var errors: [String] = []

        if pin.count != 6 {
            errors.append("PIN must be 6 digits")
        }
        if !pin.isEmpty && !pin.allSatisfy({ $0.isNumber }) {
            errors.append("PIN must contain only numbers")
        }
        if !pin.isEmpty && isWeakPIN(pin) {
            errors.append("PIN is too weak (avoid sequences and repeated digits)")
        }
        if !confirmPin.isEmpty && pin != confirmPin {
            errors.append("PINs don't match")
        }

        return errors
    }

    /// Check for weak PIN patterns (sequences, repeated digits)
    private func isWeakPIN(_ pin: String) -> Bool {
        // Check for repeated digits (e.g., 111111, 222222)
        if Set(pin).count == 1 { return true }

        // Check for sequential patterns (e.g., 123456, 654321)
        let digits = pin.compactMap { Int(String($0)) }
        guard digits.count == 6 else { return true }

        let ascending = zip(digits, digits.dropFirst()).allSatisfy { $1 - $0 == 1 }
        let descending = zip(digits, digits.dropFirst()).allSatisfy { $0 - $1 == 1 }
        if ascending || descending { return true }

        // Check for common weak PINs
        let weakPINs = ["000000", "111111", "222222", "333333", "444444",
                        "555555", "666666", "777777", "888888", "999999",
                        "123456", "654321", "123123", "112233"]
        if weakPINs.contains(pin) { return true }

        return false
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
        #if DEBUG
        print("[Enrollment] handleScannedCode called with: \(code.prefix(100))...")
        #endif
        scannedCode = code
        state = .processingInvitation

        do {
            // Parse QR code JSON data to extract api_url and session_token or invitation_code
            let qrData = try parseQRCodeData(code)
            #if DEBUG
            print("[Enrollment] Parsed QR data - apiUrl: \(qrData.apiUrl), userGuid: \(qrData.userGuid)")
            #endif

            // Create API client with the URL from QR code
            guard let apiUrl = URL(string: qrData.apiUrl) else {
                throw EnrollmentError.invalidInvitationCode
            }
            apiClient = APIClient(baseURL: apiUrl)

            // Route to appropriate flow based on QR data content
            if qrData.isQRFlow, let sessionToken = qrData.sessionToken {
                // QR Code Flow: Authenticate with session_token first
                await startQRCodeFlow(sessionToken: sessionToken)
            } else if qrData.isInvitationFlow, let invitationCode = qrData.invitationCode {
                // Invitation Code Flow: Start enrollment directly
                await startInvitationCodeFlow(invitationCode: invitationCode)
            } else {
                // Fallback: Assume session token for backwards compatibility
                await startQRCodeFlow(sessionToken: qrData.sessionToken ?? code)
            }

        } catch {
            #if DEBUG
            print("[Enrollment] Error during handleScannedCode: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// Handle direct invitation code entry (without QR scan)
    func handleInvitationCode(_ code: String, apiUrl: String? = nil) async {
        #if DEBUG
        print("[Enrollment] handleInvitationCode called with: \(code.prefix(20))...")
        #endif
        scannedCode = code
        state = .processingInvitation

        do {
            // Use provided API URL or default from configuration
            let url: URL
            if let apiUrl = apiUrl {
                guard let parsedUrl = URL(string: apiUrl) else {
                    throw EnrollmentError.invalidInvitationCode
                }
                url = parsedUrl
            } else {
                url = AppConfiguration.enrollmentAPIURL
            }
            apiClient = APIClient(baseURL: url)

            await startInvitationCodeFlow(invitationCode: code)

        } catch {
            #if DEBUG
            print("[Enrollment] Error during handleInvitationCode: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// QR Code Flow: Authenticate with session_token to get enrollment JWT
    private func startQRCodeFlow(sessionToken: String) async {
        do {
            let deviceId = getDeviceId()

            // Step 1: Authenticate with session_token to get enrollment JWT
            #if DEBUG
            print("[Enrollment] Step 1: Authenticating with session token...")
            #endif
            let authRequest = EnrollAuthenticateRequest(
                sessionToken: sessionToken,
                deviceId: deviceId,
                deviceType: "ios"
            )
            let authResponse = try await apiClient.enrollAuthenticate(request: authRequest)
            #if DEBUG
            print("[Enrollment] Auth successful - enrollmentSessionId: \(authResponse.enrollmentSessionId)")
            #endif

            // Store the enrollment token (JWT) for subsequent calls
            enrollmentToken = authResponse.enrollmentToken
            enrollmentSessionId = authResponse.enrollmentSessionId
            userGuid = authResponse.userGuid

            // Check if NATS-based flow is enabled and finalize returns NATS creds
            if useNatsFlow {
                await startNatsBasedEnrollment()
            } else {
                // Legacy API-based flow
                let startRequest = EnrollStartRequest(skipAttestation: true)
                let response = try await apiClient.enrollStart(request: startRequest, authToken: authResponse.enrollmentToken)
                await handleEnrollStartResponse(response)
            }

        } catch {
            #if DEBUG
            print("[Enrollment] Error during QR code flow: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    // MARK: - NATS-Based Enrollment Flow (Architecture v2.0)

    /// Start NATS-based enrollment after authentication
    ///
    /// Flow:
    /// 1. Call finalize to get NATS bootstrap credentials
    /// 2. Connect to NATS
    /// 3. Request attestation via NATS (with app-generated nonce)
    /// 4. Prompt for PIN → send via NATS
    /// 5. Wait for vault ready + UTKs
    /// 6. Prompt for password → send via NATS
    /// 7. Receive credential
    /// 8. Verify enrollment
    private func startNatsBasedEnrollment() async {
        guard let token = enrollmentToken else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        do {
            // Step 1: Call finalize to get NATS bootstrap credentials
            #if DEBUG
            print("[Enrollment] NATS Flow: Getting bootstrap credentials...")
            #endif
            state = .connectingToNats

            let request = EnrollFinalizeRequest()
            let response = try await apiClient.enrollFinalize(request: request, authToken: token)

            // Extract NATS connection info
            guard let natsInfo = response.natsConnection else {
                #if DEBUG
                print("[Enrollment] No NATS connection info in finalize response, falling back to API flow")
                #endif
                useNatsFlow = false
                let startRequest = EnrollStartRequest(skipAttestation: true)
                let startResponse = try await apiClient.enrollStart(request: startRequest, authToken: token)
                await handleEnrollStartResponse(startResponse)
                return
            }

            // Parse NATS credentials
            let credentials = NatsCredentials(from: natsInfo)
            natsBootstrapCredentials = credentials
            natsOwnerSpace = natsInfo.ownerSpace

            // Step 2: Connect to NATS
            #if DEBUG
            print("[Enrollment] NATS Flow: Connecting to NATS...")
            #endif
            let connectionManager = NatsConnectionManager(userGuidProvider: { [weak self] in
                self?.userGuid
            })
            natsConnectionManager = connectionManager

            let handler = EnrollmentNatsHandler(natsConnectionManager: connectionManager)
            enrollmentNatsHandler = handler

            try await handler.connect(credentials: credentials, ownerSpace: natsInfo.ownerSpace)

            // Step 3: Request attestation via NATS
            #if DEBUG
            print("[Enrollment] NATS Flow: Requesting attestation...")
            #endif
            state = .requestingAttestation

            let enclaveKey = try await handler.requestAndVerifyAttestation()
            self.enclavePublicKey = enclaveKey

            #if DEBUG
            print("[Enrollment] NATS Flow: Attestation verified, proceeding to PIN setup")
            #endif
            state = .attestationComplete

            // Brief pause for UI feedback
            try await Task.sleep(nanoseconds: 500_000_000)

            // Step 4: Prompt for PIN (UI will handle this)
            state = .settingPIN

        } catch {
            #if DEBUG
            print("[Enrollment] NATS enrollment error: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// Submit PIN via NATS (Architecture v2.0)
    func submitPINViaNats() async {
        guard isPINValid else { return }
        guard let handler = enrollmentNatsHandler else {
            // Fall back to API-based PIN submission
            await submitPIN()
            return
        }

        state = .processingPIN

        do {
            // Step 5: Submit encrypted PIN to supervisor via NATS
            #if DEBUG
            print("[Enrollment] NATS Flow: Submitting PIN...")
            #endif
            try await handler.submitPIN(pin)

            // Step 6: Wait for vault ready + UTKs
            #if DEBUG
            print("[Enrollment] NATS Flow: Waiting for vault ready...")
            #endif
            state = .waitingForVault

            let vaultReady = try await handler.waitForVaultReady()
            vaultUTKs = vaultReady.utks ?? []

            #if DEBUG
            print("[Enrollment] NATS Flow: Vault ready with \(vaultUTKs.count) UTKs")
            #endif

            // Step 7: Prompt for password
            state = .settingPassword

        } catch {
            #if DEBUG
            print("[Enrollment] NATS PIN submission error: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// Submit password via NATS for credential creation (Architecture v2.0)
    func submitPasswordViaNats() async {
        guard isPasswordValid else { return }
        guard let handler = enrollmentNatsHandler else {
            // Fall back to API-based password submission
            await submitPassword()
            return
        }

        // Get UTK for password encryption
        guard let utk = vaultUTKs.first else {
            handleError(EnrollmentError.noTransactionKeys, retryable: false)
            return
        }

        state = .processingPassword

        do {
            // Step 8: Submit password for credential creation
            #if DEBUG
            print("[Enrollment] NATS Flow: Creating credential...")
            #endif
            state = .creatingCredential

            let credentialResponse = try await handler.submitPassword(password, utkPublicKey: utk.publicKey)

            // Store new UTKs if returned
            if let newUTKs = credentialResponse.utks {
                vaultUTKs = newUTKs
            }

            // Store the encrypted credential
            if let encryptedCred = credentialResponse.encryptedCredential {
                try storeNatsCredential(encryptedCredential: encryptedCred)
            }

            // Step 9: Verify enrollment
            #if DEBUG
            print("[Enrollment] NATS Flow: Verifying enrollment...")
            #endif
            state = .verifyingEnrollment

            try await handler.verifyEnrollment()

            #if DEBUG
            print("[Enrollment] NATS Flow: Enrollment complete!")
            #endif

            // Clear sensitive data
            clearSessionData()

            state = .complete(userGuid: userGuid ?? "unknown")

        } catch {
            #if DEBUG
            print("[Enrollment] NATS credential creation error: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// Store credential received via NATS
    private func storeNatsCredential(encryptedCredential: String) throws {
        // Build stored credential from NATS response
        let storedKeys = vaultUTKs.map { utk in
            StoredUTK(
                keyId: utk.id,
                publicKey: utk.publicKey,
                algorithm: "X25519",
                isUsed: false
            )
        }

        let credential = StoredCredential(
            userGuid: userGuid ?? "",
            sealedCredential: encryptedCredential,
            enclavePublicKey: enclavePublicKey?.base64EncodedString() ?? "",
            backupKey: "",  // Generated during NATS finalization
            ledgerAuthToken: StoredLAT(
                latId: UUID().uuidString,
                token: "",
                version: 1
            ),
            transactionKeys: storedKeys,
            createdAt: Date(),
            lastUsedAt: Date(),
            vaultStatus: "running"
        )

        try credentialStore.store(credential: credential)

        // Store NATS credentials for future use
        if let natsCreds = natsBootstrapCredentials {
            try NatsCredentialStore().saveCredentials(natsCreds)
        }
    }

    /// Invitation Code Flow: Start enrollment directly with invitation code
    /// Note: This flow gets the enrollmentToken in the enrollStart response
    private func startInvitationCodeFlow(invitationCode: String) async {
        do {
            let deviceId = getDeviceId()

            // For invitation code flow, we need to call a different endpoint
            // that accepts invitation_code directly and returns enrollment token
            #if DEBUG
            print("[Enrollment] Starting invitation code flow...")
            #endif

            // First, authenticate to get enrollment token
            // The invitation code is used as the session token in this flow
            let authRequest = EnrollAuthenticateRequest(
                sessionToken: invitationCode,
                deviceId: deviceId,
                deviceType: "ios"
            )

            do {
                let authResponse = try await apiClient.enrollAuthenticate(request: authRequest)

                // Store the enrollment token (JWT) for subsequent calls
                enrollmentToken = authResponse.enrollmentToken
                enrollmentSessionId = authResponse.enrollmentSessionId
                userGuid = authResponse.userGuid

                // Call enrollStart with the JWT token
                let startRequest = EnrollStartRequest(skipAttestation: true)
                let response = try await apiClient.enrollStart(request: startRequest, authToken: authResponse.enrollmentToken)

                await handleEnrollStartResponse(response)
            } catch {
                // If authenticate fails, the code might be a legacy invitation code
                // Try alternative flow or report error
                #if DEBUG
                print("[Enrollment] Invitation code flow failed: \(error)")
                #endif
                throw EnrollmentError.invalidInvitationCode
            }

        } catch {
            #if DEBUG
            print("[Enrollment] Error during invitation code flow: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// Handle the response from enrollStart (common to both flows)
    private func handleEnrollStartResponse(_ response: EnrollStartResponse) async {
        // Store session data from start response
        transactionKeys = response.transactionKeys
        passwordKeyId = response.passwordKeyId

        // Verify Nitro Enclave attestation (required)
        guard let attestation = response.enclaveAttestation else {
            handleError(EnrollmentError.missingAttestation, retryable: false)
            return
        }

        do {
            let attestationResult = try verifyEnclaveAttestation(attestation)
            self.enclavePublicKey = attestationResult.enclavePublicKey

            #if DEBUG
            print("[Enrollment] Enclave attestation verified, public key: \(enclavePublicKey!.base64EncodedString().prefix(20))...")
            #endif

            // Proceed directly to password (no App Attest needed with Nitro)
            state = .attestationComplete
            await proceedToPassword()
        } catch {
            handleError(error, retryable: false)
        }
    }

    /// Verify Nitro Enclave attestation document
    private func verifyEnclaveAttestation(_ attestation: EnclaveAttestation) throws -> NitroAttestationVerifier.AttestationResult {
        guard let documentData = Data(base64Encoded: attestation.attestationDocument) else {
            throw EnrollmentError.invalidAttestation
        }

        guard let pcrSet = attestation.expectedPcrs.first else {
            throw EnrollmentError.missingPCRs
        }

        let expectedPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: pcrSet.pcr0,
            pcr1: pcrSet.pcr1,
            pcr2: pcrSet.pcr2,
            validFrom: Date(),
            validUntil: nil
        )

        let nonce = Data(base64Encoded: attestation.nonce)

        let result = try nitroVerifier.verify(
            attestationDocument: documentData,
            expectedPCRs: expectedPCRs,
            nonce: nonce
        )

        // Verify extracted key matches response
        guard let responseKey = Data(base64Encoded: attestation.enclavePublicKey) else {
            throw EnrollmentError.invalidAttestation
        }

        guard result.enclavePublicKey == responseKey else {
            throw EnrollmentError.publicKeyMismatch
        }

        return result
    }

    func performAttestation() async {
        guard attestationManager.isSupported else {
            // Skip attestation for simulator/unsupported devices
            state = .attestationComplete
            await proceedToPassword()
            return
        }

        guard let token = enrollmentToken,
              let sessionId = enrollmentSessionId,
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

            // Use the enrollment JWT token for authentication
            let response = try await apiClient.enrollAttestationIOS(
                request: attestationRequest,
                authToken: token
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
        guard let token = enrollmentToken,
              let keyId = passwordKeyId,
              let enclaveKey = enclavePublicKey else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .processingPassword

        do {
            // Hash password with Argon2id
            let hashResult = try PasswordHasher.hash(password: password)

            // Encrypt password hash to enclave public key (verified during attestation)
            let encryptedPayload = try CryptoManager.encryptPasswordHash(
                passwordHash: hashResult.hash,
                utkPublicKeyBase64: enclaveKey.base64EncodedString()
            )

            // Submit to API (session info is in the JWT)
            let request = EnrollSetPasswordRequest(
                encryptedPasswordHash: encryptedPayload.encryptedPasswordHash,
                keyId: keyId,
                nonce: encryptedPayload.nonce,
                ephemeralPublicKey: encryptedPayload.ephemeralPublicKey
            )

            let response = try await apiClient.enrollSetPassword(request: request, authToken: token)

            #if DEBUG
            print("[Enrollment] Set password response - status: \(response.status), nextStep: \(response.nextStep ?? "nil")")
            #endif

            // Accept any successful response (HTTP 200 already verified by APIClient)
            // Server returns status: "password_set" on success
            guard response.status.lowercased().contains("password") || response.status.lowercased().contains("success") else {
                throw EnrollmentError.passwordSetFailed
            }

            // Proceed to PIN setup (Architecture v2.0 - two-factor model)
            state = .settingPIN

        } catch {
            handleError(error, retryable: true)
        }
    }

    /// Submit vault PIN for DEK binding (Architecture v2.0 Section 5.7)
    ///
    /// The PIN is encrypted to the enclave's attestation-bound public key and sent
    /// to the supervisor, which uses it for DEK derivation during vault warming.
    func submitPIN() async {
        guard isPINValid else { return }
        guard let token = enrollmentToken,
              let enclaveKey = enclavePublicKey else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .processingPIN

        do {
            // Generate a nonce to prevent replay attacks
            let nonce = CryptoManager.randomBytes(count: 16)

            // Encrypt PIN to enclave public key (from verified attestation)
            // The supervisor will receive this and use it for DEK derivation
            let encryptedPIN = try CryptoManager.encryptToPublicKey(
                plaintext: Data(pin.utf8),
                publicKey: enclaveKey,
                additionalData: nonce
            )

            // Send encrypted PIN to supervisor via Lambda
            let request = EnrollSetPINRequest(
                encryptedPIN: encryptedPIN.ciphertext.base64EncodedString(),
                nonce: nonce.base64EncodedString(),
                ephemeralPublicKey: encryptedPIN.ephemeralPublicKey.base64EncodedString()
            )

            let response = try await apiClient.enrollSetPIN(request: request, authToken: token)

            #if DEBUG
            print("[Enrollment] Set PIN response - status: \(response.status)")
            #endif

            guard response.status.lowercased().contains("pin") || response.status.lowercased().contains("success") else {
                throw EnrollmentError.pinSetFailed
            }

            // Finalize enrollment
            await finalizeEnrollment()

        } catch {
            handleError(error, retryable: true)
        }
    }

    private func finalizeEnrollment() async {
        guard let token = enrollmentToken else {
            handleError(EnrollmentError.invalidState, retryable: false)
            return
        }

        state = .finalizing

        do {
            // Session info is passed via JWT
            let request = EnrollFinalizeRequest()
            let response = try await apiClient.enrollFinalize(request: request, authToken: token)

            guard response.status == "enrolled" else {
                throw EnrollmentError.finalizationFailed
            }

            // Store credential
            try storeCredential(package: response.credentialPackage, vaultStatus: response.vaultStatus ?? "unknown")

            let completedUserGuid = response.credentialPackage.userGuid

            // Set up NATS account for real-time messaging
            await setupNatsAccount(authToken: token)

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
        pin = ""
        confirmPin = ""
        errorMessage = nil
        showError = false
        clearSessionData()
    }

    // MARK: - Private Helpers

    private func parseQRCodeData(_ qrContent: String) throws -> EnrollmentQRCodeData {
        // Try to parse as JSON first (new format)
        if let jsonData = qrContent.data(using: .utf8) {
            do {
                let decoder = JSONDecoder()
                let qrData = try decoder.decode(EnrollmentQRCodeData.self, from: jsonData)

                // Validate the QR code type
                guard qrData.type == "vettid_enrollment" else {
                    throw EnrollmentError.invalidInvitationCode
                }

                return qrData
            } catch is DecodingError {
                // Fall through to legacy handling
            }
        }

        // Legacy format: QR code might be a URL with code parameter
        // Create a fallback with default API URL
        if let url = URL(string: qrContent),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return EnrollmentQRCodeData(
                type: "vettid_enrollment",
                version: 1,
                apiUrl: "https://api.vettid.dev",
                sessionToken: code,
                invitationCode: nil,
                userGuid: ""
            )
        }

        // If not JSON or URL, assume it's just the raw session token with default API
        return EnrollmentQRCodeData(
            type: "vettid_enrollment",
            version: 1,
            apiUrl: "https://api.vettid.dev",
            sessionToken: qrContent,
            invitationCode: nil,
            userGuid: ""
        )
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
            sealedCredential: package.sealedCredential,
            enclavePublicKey: package.enclavePublicKey,
            backupKey: package.backupKey,
            ledgerAuthToken: StoredLAT(
                latId: package.ledgerAuthToken.latId ?? package.ledgerAuthToken.token,
                token: package.ledgerAuthToken.token,
                version: package.ledgerAuthToken.version
            ),
            transactionKeys: allKeys,
            createdAt: Date(),
            lastUsedAt: Date(),
            vaultStatus: "running"  // Enclave is always running
        )

        try credentialStore.store(credential: credential)
    }

    private func clearSessionData() {
        enrollmentToken = nil
        enrollmentSessionId = nil
        userGuid = nil
        transactionKeys = []
        passwordKeyId = nil
        attestationKeyId = nil
        attestationChallenge = nil
        memberAuthToken = nil
        enclavePublicKey = nil
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

