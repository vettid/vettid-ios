import Foundation
import SwiftUI
import os

private let enrollLog = Logger(subsystem: "com.vettid.app", category: "enrollment")

// MARK: - QR Code Data Model

/// Represents the JSON data encoded in enrollment QR codes
struct EnrollmentQRCodeData: Codable {
    let type: String
    let version: Int
    let apiUrl: String
    let sessionToken: String?      // For QR code flow (web-initiated)
    let invitationCode: String?    // For direct invitation code flow
    /// Optional — only present on QRs that came from the new Nitro
    /// flow. Older / portal-issued QRs may omit it, so decode must
    /// not fail on its absence. Mirrors Android's nullable userGuid.
    let userGuid: String?

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
    private var vaultUTKs: [NatsPINSetupResponse.UTKInfo] = []
    /// Registration profile pulled from the nats-bootstrap response.
    /// Sent INSIDE the encrypted PIN payload during pin.setup so the
    /// vault stores `first_name`/`last_name`/`email` on initialise.
    /// Mirrors Android `pendingRegistrationProfile`.
    private var pendingRegistrationProfile: EnrollmentNatsHandler.RegistrationProfile?
    private var useNatsFlow: Bool = true  // Enable NATS-based enrollment by default

    // MARK: - Enrollment Identity Data

    /// Identity information from enrollment response for confirmation
    struct EnrollmentIdentity: Equatable {
        let firstName: String
        let lastName: String
        let email: String
    }

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
        case confirmIdentity(EnrollmentIdentity)  // Confirm identity from enrollment response
        case identityRejected        // User rejected identity — mismatch reported
        case settingPIN              // PIN setup step (before password in NATS flow)
        case processingPIN           // Sending PIN to supervisor
        case waitingForVault         // NATS flow: waiting for vault ready + UTKs
        case settingPassword
        case processingPassword
        case creatingCredential      // NATS flow: credential being created
        case confirmProfile          // Confirm public profile before finishing
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
            case .confirmIdentity:
                return "Confirm Identity"
            case .identityRejected:
                return "Identity Mismatch"
            case .settingPIN, .processingPIN:
                return "Create Vault PIN"
            case .waitingForVault:
                return "Initializing Vault"
            case .settingPassword, .processingPassword:
                return "Create Password"
            case .creatingCredential:
                return "Creating Credential"
            case .confirmProfile:
                return "Your Profile"
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

    /// Validate the vault PIN. 4-8 digits, matching Android's
    /// NitroEnrollmentClient.setupPin: `pin.length !in 4..8`.
    var isPINValid: Bool {
        (4...8).contains(pin.count) &&
        pin.allSatisfy { $0.isNumber } &&
        pin == confirmPin &&
        !isWeakPIN(pin)
    }

    var pinValidationErrors: [String] {
        var errors: [String] = []

        if !pin.isEmpty && !(4...8).contains(pin.count) {
            errors.append("PIN must be 4–8 digits")
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

    /// Check for weak PIN patterns (sequences, repeated digits, common values).
    private func isWeakPIN(_ pin: String) -> Bool {
        guard (4...8).contains(pin.count) else { return true }

        // Check for repeated digits (e.g., 1111, 222222)
        if Set(pin).count == 1 { return true }

        let digits = pin.compactMap { Int(String($0)) }
        guard digits.count == pin.count else { return true }

        // Check for monotonic sequences (e.g., 1234, 123456, 87654321)
        let ascending = zip(digits, digits.dropFirst()).allSatisfy { $1 - $0 == 1 }
        let descending = zip(digits, digits.dropFirst()).allSatisfy { $0 - $1 == 1 }
        if ascending || descending { return true }

        // Check for common weak PINs across allowed lengths.
        let weakPINs: Set<String> = [
            "0000", "1111", "2222", "3333", "4444", "5555", "6666", "7777", "8888", "9999",
            "1234", "4321",
            "000000", "111111", "222222", "333333", "444444",
            "555555", "666666", "777777", "888888", "999999",
            "123456", "654321", "123123", "112233",
            "12345678", "87654321"
        ]
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
        enrollLog.info("handleScannedCode: len=\(code.count, privacy: .public) prefix=\(code.prefix(40), privacy: .public)")
        scannedCode = code
        state = .processingInvitation

        // Short enrollment code (`XXXX-XXXX`, 8 chars + hyphen) issued
        // by the web portal — resolve via POST /vault/enroll/resolve-code
        // to get the full QR-equivalent payload, then continue with
        // the standard flow. Mirrors Android's `processQRCode` short-
        // code branch. Lenient on input: accept the 8 chars with or
        // without the hyphen, then send the canonical `XXXX-XXXX` form.
        if let canonical = Self.normalizedShortCode(code) {
            enrollLog.info("matched short-code regex, resolving canonical=\(canonical, privacy: .public)")
            await resolveShortCodeAndContinue(canonical)
            return
        }

        do {
            // Parse QR code JSON data to extract api_url and session_token or invitation_code
            let qrData = try parseQRCodeData(code)
            enrollLog.info("Parsed QR data apiUrl=\(qrData.apiUrl, privacy: .public) hasSession=\(qrData.sessionToken != nil, privacy: .public) hasInvite=\(qrData.invitationCode != nil, privacy: .public)")
            await continueWithQRData(qrData, fallbackTokenIfMissing: code)
        } catch {
            enrollLog.error("handleScannedCode threw: \(String(describing: error), privacy: .public)")
            handleError(error, retryable: true)
        }
    }

    /// Continue the enrollment flow with a fully-populated QR payload —
    /// either parsed from the scanned JSON or returned by
    /// `/vault/enroll/resolve-code`. Factored out so both the QR-scan
    /// and short-code paths share it.
    private func continueWithQRData(
        _ qrData: EnrollmentQRCodeData,
        fallbackTokenIfMissing: String
    ) async {
        guard let apiUrl = URL(string: qrData.apiUrl) else {
            handleError(EnrollmentError.invalidInvitationCode, retryable: true)
            return
        }
        apiClient = APIClient(baseURL: apiUrl)

        if qrData.isQRFlow, let sessionToken = qrData.sessionToken {
            await startQRCodeFlow(sessionToken: sessionToken)
        } else if qrData.isInvitationFlow, let invitationCode = qrData.invitationCode {
            await startInvitationCodeFlow(invitationCode: invitationCode)
        } else {
            // Fallback for older-format QRs that only have a bare token
            await startQRCodeFlow(sessionToken: qrData.sessionToken ?? fallbackTokenIfMissing)
        }
    }

    /// Hit `/vault/enroll/resolve-code` with the 8-char portal code
    /// and continue with the returned QR payload.
    private func resolveShortCodeAndContinue(_ code: String) async {
        do {
            let resolverClient = APIClient(baseURL: AppConfiguration.enrollmentAPIURL)
            apiClient = resolverClient
            let request = ResolveEnrollmentCodeRequest(
                enrollmentCode: code,
                deviceId: getDeviceId(),
                deviceType: "ios"
            )
            enrollLog.info("POST resolve-code base=\(AppConfiguration.enrollmentAPIURL.absoluteString, privacy: .public) code=\(code, privacy: .public)")
            let qrData = try await resolverClient.resolveEnrollmentCode(request: request)
            enrollLog.info("resolve-code OK apiUrl=\(qrData.apiUrl, privacy: .public) hasSession=\(qrData.sessionToken != nil, privacy: .public)")
            await continueWithQRData(qrData, fallbackTokenIfMissing: code)
        } catch {
            enrollLog.error("resolve-code failed: \(String(describing: error), privacy: .public)")
            handleError(error, retryable: true)
        }
    }

    /// Read `exp` (seconds since epoch) from a NATS JWT payload. We
    /// only need a best-effort expiration for credential lifecycle —
    /// return nil if the JWT is malformed or has no `exp` claim and
    /// let the caller fall back.
    private static func parseJWTExp(jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard
            let payloadData = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let exp = payload["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 8-character portal short code. Accepts `ABCD-1234`, `ABCD1234`,
    /// or whitespace/lowercase variants — returns the canonical
    /// `XXXX-XXXX` form to send to the resolver, or nil if it doesn't
    /// look like a short code at all.
    static func normalizedShortCode(_ raw: String) -> String? {
        let upper = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        // Without hyphen
        if upper.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil {
            let idx = upper.index(upper.startIndex, offsetBy: 4)
            return "\(upper[..<idx])-\(upper[idx...])"
        }
        // With hyphen
        if upper.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil {
            return upper
        }
        return nil
    }

    /// Handle direct invitation code entry (without QR scan)
    func handleInvitationCode(_ code: String, apiUrl: String? = nil) async {
        #if DEBUG
        print("[Enrollment] handleInvitationCode called with: \(code.prefix(20))...")
        #endif
        scannedCode = code
        state = .processingInvitation

        // If the user typed an 8-char portal code (`XXXX-XXXX`), route
        // through resolve-code so manual entry matches the QR-scan flow.
        if let canonical = Self.normalizedShortCode(code) {
            await resolveShortCodeAndContinue(canonical)
            return
        }

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

    /// Resolve a short enrollment/invitation code (e.g. broker-issued short codes)
    func resolveShortCode(_ code: String) async {
        #if DEBUG
        print("[Enrollment] resolveShortCode called with: \(code)")
        #endif
        state = .processingInvitation

        do {
            // Use default enrollment API URL for short code resolution
            let url = AppConfiguration.enrollmentAPIURL
            apiClient = APIClient(baseURL: url)

            // Short codes are resolved through the invitation code flow
            // The vault/API handles mapping from short code to full invitation credentials
            await startInvitationCodeFlow(invitationCode: code)

        } catch {
            #if DEBUG
            print("[Enrollment] Error resolving short code: \(error)")
            #endif
            handleError(error, retryable: true)
        }
    }

    /// QR Code Flow: Authenticate with session_token to get enrollment JWT
    private func startQRCodeFlow(sessionToken: String) async {
        do {
            let deviceId = getDeviceId()

            enrollLog.info("startQRCodeFlow: POST enroll/authenticate")
            let authRequest = EnrollAuthenticateRequest(
                sessionToken: sessionToken,
                deviceId: deviceId,
                deviceType: "ios"
            )
            let authResponse = try await apiClient.enrollAuthenticate(request: authRequest)
            enrollLog.info("authenticate OK sessionId=\(authResponse.enrollmentSessionId, privacy: .public)")

            // Store the enrollment token (JWT) for subsequent calls
            enrollmentToken = authResponse.enrollmentToken
            enrollmentSessionId = authResponse.enrollmentSessionId
            userGuid = authResponse.userGuid

            // Check if NATS-based flow is enabled and finalize returns NATS creds
            if useNatsFlow {
                await startNatsBasedEnrollment()
            } else {
                let startRequest = EnrollStartRequest(skipAttestation: true)
                let response = try await apiClient.enrollStart(request: startRequest, authToken: authResponse.enrollmentToken)
                await handleEnrollStartResponse(response)
            }

        } catch {
            enrollLog.error("startQRCodeFlow threw: \(String(describing: error), privacy: .public)")
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
            // Step 1: Get NATS bootstrap credentials. Mirrors Android's
            // post-`authenticate` step — `/vault/enroll/nats-bootstrap`
            // returns the NATS creds we use to drive PIN/password/
            // finalize over messaging. (The old `enrollFinalize`-first
            // path was removed; the server now rejects it with 400
            // "Enrollment not properly initialized.")
            enrollLog.info("NATS Flow: POST nats-bootstrap")
            state = .connectingToNats

            let deviceId = getDeviceId()
            let bootstrapRequest = EnrollNatsBootstrapRequest.test(deviceId: deviceId)
            let bootstrap = try await apiClient.enrollNatsBootstrap(
                request: bootstrapRequest,
                authToken: token
            )

            enrollLog.info("nats-bootstrap OK userGuid=\(bootstrap.userGuid, privacy: .public) endpoint=\(bootstrap.natsEndpoint, privacy: .public)")
            userGuid = bootstrap.userGuid

            // Capture the registration profile for the encrypted PIN
            // payload. Matches Android `connectToNatsAndContinue` which
            // caches it in `pendingRegistrationProfile`.
            if let bp = bootstrap.registrationProfile,
               let first = bp.firstName, !first.isEmpty,
               let last = bp.lastName, !last.isEmpty,
               let email = bp.email, !email.isEmpty {
                pendingRegistrationProfile = EnrollmentNatsHandler.RegistrationProfile(
                    firstName: first,
                    lastName: last,
                    email: email
                )
                enrollLog.info("nats-bootstrap registrationProfile captured for \(email, privacy: .public)")
            }

            // Build NatsCredentials from the structured response fields
            // directly. The bootstrap response carries `nats_jwt` and
            // `nats_seed` as their own keys; we previously parsed those
            // out of the `nats_creds` PEM-style blob, but that parser
            // was fragile (subtle dash-count / line-ending mismatches
            // → silent nil). Read the JWT `exp` claim ourselves so the
            // expiration date is correct.
            let credentials = NatsCredentials(
                tokenId: bootstrap.tokenId,
                jwt: bootstrap.natsJwt,
                seed: bootstrap.natsSeed,
                endpoint: bootstrap.natsEndpoint,
                expiresAt: Self.parseJWTExp(jwt: bootstrap.natsJwt)
                    ?? ISO8601DateFormatter().date(from: bootstrap.expiresAt)
                    ?? Date().addingTimeInterval(3600),
                permissions: NatsPermissions(
                    publish: ["\(bootstrap.ownerSpace).forVault.>"],
                    subscribe: ["\(bootstrap.ownerSpace).forApp.>"]
                )
            )
            natsBootstrapCredentials = credentials
            natsOwnerSpace = bootstrap.ownerSpace

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

            try await handler.connect(credentials: credentials, ownerSpace: bootstrap.ownerSpace)

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
            handleError(EnrollmentError.invalidState, retryable: true)
            return
        }

        state = .processingPIN

        do {
            // Submit encrypted PIN to supervisor via NATS. Android-shape
            // response carries UTKs + ecies_public_key inline, so there's
            // no separate `vault.ready` wait — matches Android's
            // RetryingEnrollmentClient.setupPin.
            #if DEBUG
            print("[Enrollment] NATS Flow: Submitting PIN...")
            #endif
            let pinResponse = try await handler.submitPIN(pin, profile: pendingRegistrationProfile)
            vaultUTKs = pinResponse.utks ?? []

            // Persist the ECIES public key returned in the PIN setup
            // response. Required at PIN-unlock / vault-warming time to
            // ECIES-encrypt the PIN before publishing — matches
            // Android (PinUnlockViewModel + storeEnclavePublicKey).
            if let eciesB64 = pinResponse.eciesPublicKey,
               let eciesBytes = Data(base64Encoded: eciesB64) {
                do {
                    try credentialStore.storeEnclavePublicKey(eciesBytes)
                    #if DEBUG
                    print("[Enrollment] Stored ECIES public key (\(eciesBytes.count) bytes) for PIN unlock")
                    #endif
                } catch {
                    handleError(
                        EnrollmentError.invalidState,
                        retryable: true
                    )
                    return
                }
            } else {
                // Android treats this as a hard failure ("CRITICAL: No
                // ECIES public key in PIN setup response — cannot
                // continue"). Without it the user can't unlock later.
                handleError(
                    EnrollmentNatsError.pinSetupFailed("Missing ECIES public key in PIN setup response"),
                    retryable: true
                )
                return
            }

            #if DEBUG
            print("[Enrollment] NATS Flow: PIN setup OK, \(vaultUTKs.count) UTKs received")
            #endif

            // Prompt for password
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

            // Submit password with PHC format and get back both response and hash result
            let (credentialResponse, phcResult) = try await handler.submitPassword(
                password,
                utkId: utk.id,
                utkPublicKey: utk.publicKey
            )

            // Create local data from PHC result for offline password re-hashing
            let localData = VaultLocalData.from(phcResult: phcResult)

            // Store new UTKs if returned (translate from the credential-
            // response UTK type to the PIN-response UTK type the rest of
            // the wizard holds).
            if let newUTKs = credentialResponse.utks {
                vaultUTKs = newUTKs.map { NatsPINSetupResponse.UTKInfo(id: $0.id, publicKey: $0.publicKey) }
            }

            // Store the encrypted credential with local data
            if let encryptedCred = credentialResponse.encryptedCredential {
                try storeNatsCredential(encryptedCredential: encryptedCred, localData: localData)
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
    /// - Parameters:
    ///   - encryptedCredential: The sealed credential blob from the vault
    ///   - localData: Password salt and Argon2id params for offline re-hashing
    private func storeNatsCredential(encryptedCredential: String, localData: VaultLocalData? = nil) throws {
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
            vaultStatus: "running",
            localData: localData
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
            // SECURITY (Area E #50): wrap the @Published String into
            // a wipeable SecurePassword right at the launch boundary
            // and immediately clear the ViewModel state. The Argon2id
            // hash goes through the SecurePassword overload, which
            // zeros its internal byte copy before returning. Mirrors
            // Android 95bcabf.
            let pw = SecurePassword(string: password)
            password = ""
            confirmPassword = ""
            defer { pw.wipe() }

            // Hash password with Argon2id
            let hashResult = try PasswordHasher.hash(password: pw)

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
    // submitPIN()/finalizeEnrollment() HTTP fallback removed — the
    // deprecated `enrollSetPIN` Lambda was returning 404 against the
    // current backend. All enrollment now flows through NATS via
    // `submitPINViaNats` / EnrollmentNatsHandler.submitPIN, matching
    // Android.

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

    // MARK: - Identity Confirmation

    /// Confirm the identity shown to the user
    func confirmIdentity() {
        // After identity is confirmed, proceed to PIN setup
        state = .settingPIN
    }

    /// Reject identity — report mismatch and cancel enrollment
    func rejectIdentity() {
        state = .identityRejected
        // Report mismatch to supervisor via NATS
        Task {
            await enrollmentNatsHandler?.reportIdentityMismatch()
        }
    }

    // MARK: - Profile Confirmation

    /// Confirm and publish the default public profile
    func confirmProfile() async {
        // In production: publish profile via NATS
        // For now, proceed to completion
        if let guid = userGuid {
            state = .complete(userGuid: guid)
        }
    }

    /// Skip profile publishing
    func skipProfile() {
        if let guid = userGuid {
            state = .complete(userGuid: guid)
        }
    }

    // MARK: - Retry

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

