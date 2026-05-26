import Foundation
import os

private let natsEnrollLog = Logger(subsystem: "com.vettid.app", category: "enrollment-nats")

/// Handles NATS-based enrollment operations for Nitro Enclave vault
/// (Architecture v2.0 Section 5.6)
///
/// After getting NATS bootstrap credentials from /vault/enroll/finalize,
/// the remaining enrollment steps happen over NATS:
/// - Attestation request (with app-generated nonce)
/// - PIN submission to supervisor (encrypted)
/// - Password submission to vault-manager (encrypted)
/// - Vault ready message (receives UTKs)
actor EnrollmentNatsHandler {

    // MARK: - Dependencies

    private let natsConnectionManager: NatsConnectionManager
    private let nitroVerifier: NitroAttestationVerifier
    private let pcrStore: ExpectedPCRStore

    // MARK: - State

    private var ownerSpace: String?
    private var attestationNonce: Data?
    private var verifiedEnclavePublicKey: Data?

    // MARK: - Initialization

    init(natsConnectionManager: NatsConnectionManager) {
        self.natsConnectionManager = natsConnectionManager
        self.nitroVerifier = NitroAttestationVerifier()
        self.pcrStore = ExpectedPCRStore()
    }

    // MARK: - NATS Connection

    /// Connect to NATS using bootstrap credentials from
    /// /vault/enroll/nats-bootstrap. Skips the E2E session bootstrap
    /// — the vault isn't running yet, so its `forApp.app.bootstrap.>`
    /// reply will never come.
    func connect(credentials: NatsCredentials, ownerSpace: String) async throws {
        self.ownerSpace = ownerSpace
        natsEnrollLog.info("connecting to NATS endpoint=\(credentials.endpoint, privacy: .public) ownerSpace=\(ownerSpace, privacy: .public)")
        do {
            try await natsConnectionManager.connectWithEnrollmentCredentials(
                credentials,
                ownerSpace: ownerSpace,
                performE2EBootstrap: false
            )
            natsEnrollLog.info("connected to NATS")
        } catch {
            natsEnrollLog.error("connect failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Phase 3: Attestation

    /// Request attestation from supervisor with app-generated nonce
    ///
    /// Flow:
    /// 1. Generate random 32-byte nonce
    /// 2. Send attestation request to supervisor via NATS
    /// 3. Receive attestation document
    /// 4. Verify: AWS signature, PCRs, timestamp, nonce
    /// 5. Extract and store verified enclave public key
    ///
    /// - Returns: Verified enclave public key for encrypting PIN/password
    func requestAndVerifyAttestation() async throws -> Data {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        // Step 10: Generate random nonce (32 bytes)
        let nonce = CryptoManager.randomBytes(count: 32)
        attestationNonce = nonce

        // Step 11: Send attestation request to supervisor. Topic +
        // envelope shape mirror Android's `requestAttestation` —
        // `{ownerSpace}.forVault.attestation` (no `.request` suffix)
        // with a `{id, type, payload, timestamp}` envelope. The
        // enclave's request subscription only matches that exact
        // subject; the previous iOS form was silently dropped.
        let requestId = UUID().uuidString
        let request = NatsAttestationRequest(
            id: requestId,
            type: "attestation.request",
            payload: NatsAttestationRequest.Payload(nonce: nonce.base64EncodedString()),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Subscribe BEFORE publishing so we don't miss a fast reply.
        // Match Android — single subject, no wildcard.
        let responseTopic = "\(ownerSpace).forApp.attestation.response"
        natsEnrollLog.info("subscribing to \(responseTopic, privacy: .public)")
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        let requestTopic = "\(ownerSpace).forVault.attestation"
        natsEnrollLog.info("publishing attestation request to \(requestTopic, privacy: .public) requestId=\(requestId, privacy: .public)")
        try await natsConnectionManager.publish(request, to: requestTopic)
        natsEnrollLog.info("attestation request published, waiting for response (60s timeout)")

        // Wait for response with timeout
        let timeout: TimeInterval = 60
        let response: NatsAttestationResponse = try await withThrowingTaskGroup(of: NatsAttestationResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    natsEnrollLog.info("attestation response received bytes=\(message.data.count, privacy: .public)")
                    do {
                        let response = try NatsAttestationResponse.parse(data: message.data)
                        natsEnrollLog.info("attestation response decoded requestId=\(response.requestId ?? "nil", privacy: .public)")
                        if response.requestId == nil || response.requestId == requestId {
                            return response
                        } else {
                            natsEnrollLog.info("attestation response requestId mismatch got=\(response.requestId ?? "nil", privacy: .public) want=\(requestId, privacy: .public)")
                        }
                    } catch {
                        let raw = String(data: message.data, encoding: .utf8) ?? "<binary \(message.data.count)B>"
                        natsEnrollLog.error("attestation response parse failed: \(String(describing: error), privacy: .public) raw=\(raw.prefix(400), privacy: .public)")
                    }
                }
                throw EnrollmentNatsError.attestationFailed("Response stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentNatsError.timeout("Attestation request timed out")
            }

            guard let result = try await group.next() else {
                throw EnrollmentNatsError.attestationFailed("No response received")
            }

            group.cancelAll()
            return result
        }

        natsEnrollLog.info("post-group: returned with docLen=\(response.attestationDocument.count, privacy: .public) keyLen=\(response.enclavePublicKey.count, privacy: .public)")

        // NOTE: Skipping the explicit `unsubscribe(from: responseTopic)`
        // call here — it was reliably crashing the app (after the
        // task-group returned, before the continuation finished tearing
        // down). The subscription is auto-cleaned when the connection
        // closes at end of enrollment. The race/use-after-free in the
        // AppleNatsClient unsubscribe path is tracked separately.

        guard response.success else {
            natsEnrollLog.error("attestation failed: \(response.message ?? "denied", privacy: .public)")
            throw EnrollmentNatsError.attestationFailed(response.message ?? "Attestation denied")
        }

        // Step 13-14: Verify attestation document
        guard let documentData = Data(base64Encoded: response.attestationDocument) else {
            natsEnrollLog.error("attestation document is not base64")
            throw EnrollmentNatsError.attestationFailed("Invalid attestation document encoding")
        }
        natsEnrollLog.info("attestation CBOR bytes=\(documentData.count, privacy: .public)")

        // Get expected PCRs (from PCR store or response)
        let expectedPCRs: NitroAttestationVerifier.ExpectedPCRs
        do {
            expectedPCRs = try await getExpectedPCRs(from: response)
            natsEnrollLog.info("expected PCRs resolved")
        } catch {
            natsEnrollLog.error("getExpectedPCRs threw: \(String(describing: error), privacy: .public)")
            throw error
        }

        // Verify attestation with our nonce. On failure, wrap the
        // underlying NitroAttestationError so the UI shows the
        // verification step that rejected the doc — e.g.
        // "Attestation verification failed: PCR0 mismatch …",
        // "Attestation verification failed: Invalid COSE signature …"
        // — instead of just the bare detail. Mirrors Android 88c65b6
        // (release-build attestation rejection fix).
        let result: NitroAttestationVerifier.AttestationResult
        do {
            result = try nitroVerifier.verify(
                attestationDocument: documentData,
                expectedPCRs: expectedPCRs,
                nonce: nonce  // Critical: must match the nonce we sent
            )
            natsEnrollLog.info("nitro verify OK enclaveKeyLen=\(result.enclavePublicKey.count, privacy: .public)")
        } catch {
            natsEnrollLog.error("nitro verify threw: \(String(describing: error), privacy: .public)")
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw EnrollmentNatsError.attestationFailed(detail)
        }

        // Verify the extracted key matches what was in the response
        if let responseKey = Data(base64Encoded: response.enclavePublicKey) {
            guard result.enclavePublicKey == responseKey else {
                throw EnrollmentNatsError.attestationFailed("Public key mismatch")
            }
        }

        verifiedEnclavePublicKey = result.enclavePublicKey

        #if DEBUG
        print("[EnrollmentNats] Attestation verified, enclave key: \(result.enclavePublicKey.base64EncodedString().prefix(20))...")
        #endif

        return result.enclavePublicKey
    }

    private func getExpectedPCRs(from response: NatsAttestationResponse) async throws -> NitroAttestationVerifier.ExpectedPCRs {
        // Try to get from PCR store first
        if let stored = pcrStore.getCurrentPCRSet() {
            return stored.toExpectedPCRs()
        }

        // Fall back to PCRs from response
        guard let pcrs = response.expectedPcrs else {
            throw EnrollmentNatsError.attestationFailed("No expected PCRs available")
        }

        return NitroAttestationVerifier.ExpectedPCRs(
            pcr0: pcrs.pcr0,
            pcr1: pcrs.pcr1,
            pcr2: pcrs.pcr2,
            validFrom: Date(),
            validUntil: nil
        )
    }

    // MARK: - Phase 4: PIN Setup

    /// Submit encrypted PIN to supervisor for DEK binding
    ///
    /// Flow:
    /// 1. Encrypt PIN with verified enclave public key (X25519)
    /// 2. Send encrypted PIN to supervisor via NATS
    /// 3. Wait for PIN setup complete response
    ///
    /// - Parameter pin: 6-digit PIN
    func submitPIN(_ pin: String) async throws {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        guard let enclaveKey = verifiedEnclavePublicKey else {
            throw EnrollmentNatsError.noEnclaveKey
        }

        // Step 16: Encrypt PIN to attested ephemeral pubkey
        let nonce = CryptoManager.randomBytes(count: 12)
        let encryptedPIN = try CryptoManager.encryptToPublicKey(
            plaintext: Data(pin.utf8),
            publicKey: enclaveKey,
            additionalData: nonce
        )

        // Build request
        let requestId = UUID().uuidString
        let request = NatsPINSetupRequest(
            id: requestId,
            encryptedPIN: (encryptedPIN.ciphertext + encryptedPIN.tag).base64EncodedString(),
            ephemeralPublicKey: encryptedPIN.ephemeralPublicKey.base64EncodedString(),
            nonce: encryptedPIN.nonce.base64EncodedString(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Send PIN to supervisor
        let requestTopic = "\(ownerSpace).forVault.pin.setup"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[EnrollmentNats] Sent encrypted PIN to supervisor")
        #endif

        // Subscribe to response
        let responseTopic = "\(ownerSpace).forApp.pin.setup.>"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Wait for response
        let timeout: TimeInterval = 30
        let response: NatsPINSetupResponse = try await withThrowingTaskGroup(of: NatsPINSetupResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(NatsPINSetupResponse.self, from: message.data) {
                        if response.requestId == nil || response.requestId == requestId {
                            return response
                        }
                    }
                }
                throw EnrollmentNatsError.pinSetupFailed("Response stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentNatsError.timeout("PIN setup timed out")
            }

            guard let result = try await group.next() else {
                throw EnrollmentNatsError.pinSetupFailed("No response received")
            }

            group.cancelAll()
            return result
        }

        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            throw EnrollmentNatsError.pinSetupFailed(response.message ?? "PIN setup failed")
        }

        #if DEBUG
        print("[EnrollmentNats] PIN setup complete")
        #endif
    }

    // MARK: - Phase 5: Wait for Vault Ready

    /// Wait for vault-manager to be initialized and return UTKs
    func waitForVaultReady() async throws -> VaultReadyResponse {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        let responseTopic = "\(ownerSpace).forApp.vault.ready"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        let timeout: TimeInterval = 60
        let response: VaultReadyResponse = try await withThrowingTaskGroup(of: VaultReadyResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(VaultReadyResponse.self, from: message.data) {
                        return response
                    }
                }
                throw EnrollmentNatsError.vaultNotReady("Stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentNatsError.timeout("Waiting for vault ready timed out")
            }

            guard let result = try await group.next() else {
                throw EnrollmentNatsError.vaultNotReady("No response")
            }

            group.cancelAll()
            return result
        }

        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            throw EnrollmentNatsError.vaultNotReady(response.message ?? "Vault initialization failed")
        }

        #if DEBUG
        print("[EnrollmentNats] Vault ready, received \(response.utks?.count ?? 0) UTKs")
        #endif

        return response
    }

    // MARK: - Phase 6: Credential Creation

    /// Submit password to vault-manager for credential creation
    ///
    /// Uses PHC string format ($argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>)
    /// for interoperability with enclave. The PHC string is encrypted using
    /// XChaCha20-Poly1305 (24-byte nonce) with domain-separated HKDF key derivation.
    ///
    /// - Parameters:
    ///   - password: User's credential password
    ///   - utkId: UTK ID being used for this operation
    ///   - utkPublicKey: UTK public key for encrypting password hash
    /// - Returns: Tuple of (credential response, PHC result for local storage)
    func submitPassword(_ password: String, utkId: String, utkPublicKey: String) async throws -> (CredentialCreationResponse, PHCHashResult) {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        // Hash password with Argon2id in PHC format
        let phcResult = try PasswordHasher.hashToPHC(password: password)

        // Encrypt PHC string (not just raw hash) with UTK using XChaCha20-Poly1305
        let encryptedPayload = try CryptoManager.encryptPasswordHash(
            passwordHash: phcResult.phcData,  // PHC string as Data
            utkPublicKeyBase64: utkPublicKey
        )

        // Build request with new format
        let requestId = UUID().uuidString
        let request = NatsCredentialCreateRequest(
            id: requestId,
            utkId: utkId,
            encryptedPayload: encryptedPayload.encryptedPasswordHash,
            ephemeralPublicKey: encryptedPayload.ephemeralPublicKey,
            nonce: encryptedPayload.nonce,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Send to vault-manager
        let requestTopic = "\(ownerSpace).forVault.credential.create"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[EnrollmentNats] Sent credential creation request")
        #endif

        // Subscribe to response
        let responseTopic = "\(ownerSpace).forApp.credential.created.>"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Wait for response
        let timeout: TimeInterval = 60
        let response: CredentialCreationResponse = try await withThrowingTaskGroup(of: CredentialCreationResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(CredentialCreationResponse.self, from: message.data) {
                        if response.requestId == nil || response.requestId == requestId {
                            return response
                        }
                    }
                }
                throw EnrollmentNatsError.credentialCreationFailed("Response stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentNatsError.timeout("Credential creation timed out")
            }

            guard let result = try await group.next() else {
                throw EnrollmentNatsError.credentialCreationFailed("No response received")
            }

            group.cancelAll()
            return result
        }

        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            throw EnrollmentNatsError.credentialCreationFailed(response.message ?? "Credential creation failed")
        }

        #if DEBUG
        print("[EnrollmentNats] Credential created successfully")
        #endif

        return (response, phcResult)
    }

    // MARK: - Phase 7: Verify Enrollment

    /// Send test operation to verify enrollment is complete
    func verifyEnrollment() async throws {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        let requestId = UUID().uuidString
        let request = NatsVerifyEnrollmentRequest(
            id: requestId,
            operation: "get_info",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        let requestTopic = "\(ownerSpace).forVault.enrollment.verify"
        try await natsConnectionManager.publish(request, to: requestTopic)

        // Subscribe to response
        let responseTopic = "\(ownerSpace).forApp.enrollment.verified.>"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        let timeout: TimeInterval = 30
        let response: NatsVerifyEnrollmentResponse = try await withThrowingTaskGroup(of: NatsVerifyEnrollmentResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    if let response = try? JSONDecoder().decode(NatsVerifyEnrollmentResponse.self, from: message.data) {
                        if response.requestId == nil || response.requestId == requestId {
                            return response
                        }
                    }
                }
                throw EnrollmentNatsError.verificationFailed("Stream ended")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentNatsError.timeout("Verification timed out")
            }

            guard let result = try await group.next() else {
                throw EnrollmentNatsError.verificationFailed("No response")
            }

            group.cancelAll()
            return result
        }

        await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.success else {
            throw EnrollmentNatsError.verificationFailed(response.message ?? "Verification failed")
        }

        #if DEBUG
        print("[EnrollmentNats] Enrollment verified successfully")
        #endif
    }

    // MARK: - Identity Mismatch Report

    /// Report an identity mismatch during enrollment
    /// Sends a notification to the supervisor that the user rejected the shown identity
    func reportIdentityMismatch() {
        guard let ownerSpace = ownerSpace else { return }

        let requestTopic = "\(ownerSpace).forVault.enrollment.identityMismatch"
        let request = NatsIdentityMismatchReport(
            id: UUID().uuidString,
            reason: "user_rejected",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        Task {
            try? await natsConnectionManager.publish(request, to: requestTopic)
            #if DEBUG
            print("[EnrollmentNats] Identity mismatch reported")
            #endif
        }
    }
}

// MARK: - NATS Request/Response Types

struct NatsIdentityMismatchReport: Encodable {
    let id: String
    let reason: String
    let timestamp: String
}

struct NatsAttestationRequest: Encodable {
    let id: String
    let type: String
    let payload: Payload
    let timestamp: String

    struct Payload: Encodable {
        /// Base64 encoded 32-byte nonce
        let nonce: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case payload
        case timestamp
    }
}

/// Attestation response from the enclave supervisor. Tolerant of the
/// two response shapes Android handles — fields can be at the top
/// level or wrapped under a `payload` object, and the correlation id
/// can be `request_id` / `event_id` / `id`.
///
/// Parsed via `JSONSerialization` rather than `Decodable` after two
/// earlier custom-decoder attempts crashed the process at the
/// `JSONDecoder` boundary (Swift runtime issue with our keyed
/// containers on a 6 KB response). Direct dictionary lookups don't
/// trip whatever Decodable was hitting.
struct NatsAttestationResponse {
    let success: Bool
    let message: String?
    let requestId: String?
    let attestationDocument: String  // Base64 CBOR
    let enclavePublicKey: String     // Base64 X25519 public key
    let expectedPcrs: ExpectedPCRSet?

    struct ExpectedPCRSet {
        let pcr0: String
        let pcr1: String
        let pcr2: String
    }

    static func parse(data: Data) throws -> NatsAttestationResponse {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = raw as? [String: Any] else {
            throw EnrollmentNatsError.attestationFailed("Response is not a JSON object")
        }
        let payload = (root["payload"] as? [String: Any]) ?? [:]

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = root[key] as? String, !v.isEmpty { return v }
                if let v = payload[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }

        let success = (root["success"] as? Bool) ?? (payload["success"] as? Bool) ?? true
        let message = string("message", "error")
        let requestId = string("request_id", "event_id", "id")

        guard let doc = string("attestation", "attestation_document") else {
            throw EnrollmentNatsError.attestationFailed("No attestation document in response")
        }
        guard let key = string("public_key", "enclave_public_key") else {
            throw EnrollmentNatsError.attestationFailed("No enclave public key in response")
        }

        let pcrDict = (root["expected_pcrs"] as? [String: Any])
            ?? (payload["expected_pcrs"] as? [String: Any])
        let expectedPcrs: ExpectedPCRSet?
        if let dict = pcrDict,
           let p0 = dict["PCR0"] as? String,
           let p1 = dict["PCR1"] as? String,
           let p2 = dict["PCR2"] as? String {
            expectedPcrs = ExpectedPCRSet(pcr0: p0, pcr1: p1, pcr2: p2)
        } else {
            expectedPcrs = nil
        }

        return NatsAttestationResponse(
            success: success,
            message: message,
            requestId: requestId,
            attestationDocument: doc,
            enclavePublicKey: key,
            expectedPcrs: expectedPcrs
        )
    }
}

struct NatsPINSetupRequest: Encodable {
    let id: String
    let encryptedPIN: String  // Base64: ciphertext + tag
    let ephemeralPublicKey: String  // Base64: X25519 public key
    let nonce: String  // Base64: 12-byte nonce
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case encryptedPIN = "encrypted_pin"
        case ephemeralPublicKey = "ephemeral_public_key"
        case nonce
        case timestamp
    }
}

struct NatsPINSetupResponse: Decodable {
    let success: Bool
    let message: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case requestId = "request_id"
    }
}

struct VaultReadyResponse: Decodable {
    let success: Bool
    let message: String?
    let utks: [UTKInfo]?  // User Transaction Keys

    struct UTKInfo: Decodable {
        let id: String
        let publicKey: String  // Base64 X25519 public key

        enum CodingKeys: String, CodingKey {
            case id
            case publicKey = "public_key"
        }
    }
}

struct NatsCredentialCreateRequest: Encodable {
    let id: String
    let utkId: String                  // UTK ID used for encryption
    let encryptedPayload: String       // Base64: XChaCha20-Poly1305 encrypted PHC string
    let ephemeralPublicKey: String     // Base64: 32-byte X25519 ephemeral public key
    let nonce: String                  // Base64: 24-byte XChaCha20 nonce
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case utkId = "utk_id"
        case encryptedPayload = "encrypted_payload"
        case ephemeralPublicKey = "ephemeral_public_key"
        case nonce
        case timestamp
    }
}

struct CredentialCreationResponse: Decodable {
    let success: Bool
    let message: String?
    let requestId: String?
    let encryptedCredential: String?  // Base64: encrypted Protean Credential blob
    let utks: [VaultReadyResponse.UTKInfo]?  // New UTKs

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case requestId = "request_id"
        case encryptedCredential = "encrypted_credential"
        case utks
    }
}

struct NatsVerifyEnrollmentRequest: Encodable {
    let id: String
    let operation: String
    let timestamp: String
}

struct NatsVerifyEnrollmentResponse: Decodable {
    let success: Bool
    let message: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case requestId = "request_id"
    }
}

// MARK: - Errors

enum EnrollmentNatsError: Error, LocalizedError {
    case notConnected
    case noEnclaveKey
    case timeout(String)
    case attestationFailed(String)
    case pinSetupFailed(String)
    case vaultNotReady(String)
    case credentialCreationFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to NATS. Please try again."
        case .noEnclaveKey:
            return "Enclave key not available. Please verify attestation first."
        case .timeout(let msg):
            return "Operation timed out: \(msg)"
        case .attestationFailed(let msg):
            return "Attestation verification failed: \(msg)"
        case .pinSetupFailed(let msg):
            return "PIN setup failed: \(msg)"
        case .vaultNotReady(let msg):
            return "Vault not ready: \(msg)"
        case .credentialCreationFailed(let msg):
            return "Credential creation failed: \(msg)"
        case .verificationFailed(let msg):
            return "Enrollment verification failed: \(msg)"
        }
    }
}
