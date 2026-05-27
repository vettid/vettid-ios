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

    // MARK: - State

    private var ownerSpace: String?
    private var attestationNonce: Data?
    private var verifiedEnclavePublicKey: Data?

    // MARK: - Initialization

    init(natsConnectionManager: NatsConnectionManager) {
        self.natsConnectionManager = natsConnectionManager
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
        print("[ATT-CKPT] subscribing to \(responseTopic)")
        fflush(stdout)
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)
        print("[ATT-CKPT] subscribed OK")
        fflush(stdout)

        let requestTopic = "\(ownerSpace).forVault.attestation"
        print("[ATT-CKPT] publishing to \(requestTopic), requestId=\(requestId)")
        fflush(stdout)
        try await natsConnectionManager.publish(request, to: requestTopic)
        print("[ATT-CKPT] published OK, awaiting response on \(responseTopic) (60s timeout)")
        fflush(stdout)

        // Wait for response with timeout
        let timeout: TimeInterval = 60
        let response: NatsAttestationResponse = try await withThrowingTaskGroup(of: NatsAttestationResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    print("[ATT-CKPT] response stream got \(message.data.count) bytes")
                    fflush(stdout)
                    natsEnrollLog.info("attestation response received bytes=\(message.data.count, privacy: .public)")
                    do {
                        let response = try NatsAttestationResponse.parse(data: message.data)
                        print("[ATT-CKPT] parsed response, requestId=\(response.requestId ?? "nil") success=\(response.success)")
                        fflush(stdout)
                        natsEnrollLog.info("attestation response decoded requestId=\(response.requestId ?? "nil", privacy: .public)")

                        // Replay protection (#47): reject duplicates +
                        // stale/future timestamps before honouring the
                        // response. Mirrors Android NitroEnrollmentClient.
                        let evId = response.requestId ?? UUID().uuidString
                        print("[ATT-CKPT] -> replay protection validateMessage evId=\(evId)")
                        fflush(stdout)
                        let check = NatsReplayProtection.shared.validateMessage(
                            eventId: evId,
                            timestamp: response.timestamp,
                            sessionKey: "attestation"
                        )
                        print("[ATT-CKPT] <- replay protection result=\(check)")
                        fflush(stdout)
                        guard check.isValid else {
                            print("[ATT-CKPT] REJECTED by replay protection, will continue loop")
                            fflush(stdout)
                            natsEnrollLog.warning("attestation response rejected by replay protection: \(String(describing: check), privacy: .public)")
                            continue
                        }

                        if response.requestId == nil || response.requestId == requestId {
                            print("[ATT-CKPT] requestId matches, returning response")
                            fflush(stdout)
                            return response
                        } else {
                            print("[ATT-CKPT] requestId MISMATCH: got=\(response.requestId ?? "nil") want=\(requestId)")
                            fflush(stdout)
                            natsEnrollLog.info("attestation response requestId mismatch got=\(response.requestId ?? "nil", privacy: .public) want=\(requestId, privacy: .public)")
                        }
                    } catch {
                        print("[ATT-CKPT] parse FAILED: \(error)")
                        fflush(stdout)
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
        print("[ENROLL-CKPT] got attestation response, doc=\(documentData.count) bytes — calling verifyAttestation")
        fflush(stdout)

        // Verify against the LIVE PCR manifest with retry-on-mismatch.
        // Mirrors Android's RetryingVerifier.verifyWithRefreshOnMismatch:
        // tries every valid PCR set the cached manifest knows about,
        // force-refreshes from pcr-manifest.vettid.dev once if every set
        // misses, and reports the underlying verification step that
        // rejected the doc. Previously iOS read PCRs from the bundled
        // ExpectedPCRStore fallback, which lagged the enclave's actual
        // PCR0 the moment AWS redeployed and never refreshed during
        // enrollment, so enrollment broke until the next app release.
        let result: NitroAttestationVerifier.AttestationResult
        do {
            result = try await PCRManifestManager.shared.verifyAttestation(
                documentData,
                nonce: nonce  // Critical: must match the nonce we sent
            )
            natsEnrollLog.info("nitro verify OK enclaveKeyLen=\(result.enclavePublicKey.count, privacy: .public)")
            print("[ENROLL-CKPT] verifyAttestation returned OK, enclaveKey=\(result.enclavePublicKey.count) bytes")
            fflush(stdout)
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

    // MARK: - Phase 4: PIN Setup

    /// Plain-Swift mirror of Android's `RegistrationProfile` — bundled
    /// inside the encrypted PIN payload so the vault can stash the
    /// user's name + email when it initialises.
    struct RegistrationProfile {
        let firstName: String
        let lastName: String
        let email: String
    }

    /// Submit encrypted PIN to supervisor for DEK binding.
    ///
    /// Flow:
    /// 1. Encrypt `{pin[, profile]}` with verified enclave public key
    ///    (X25519). When a profile is supplied the vault uses it to
    ///    initialise the user's personal data store on first warm,
    ///    matching Android `NitroEnrollmentClient.setupPin(pin, profile)`.
    /// 2. Send encrypted PIN to supervisor via NATS.
    /// 3. Wait for PIN setup complete response (carries UTKs +
    ///    `ecies_public_key` inline — matches Android, no separate
    ///    vault.ready message)
    ///
    /// - Parameters:
    ///   - pin: 4-8 digit PIN
    ///   - profile: Optional registration profile to seed the vault
    /// - Returns: NatsPINSetupResponse containing status, UTKs, and
    ///   the ECIES public key for later PIN unlock
    @discardableResult
    func submitPIN(_ pin: String, profile: RegistrationProfile? = nil) async throws -> NatsPINSetupResponse {
        guard let ownerSpace = ownerSpace else {
            throw EnrollmentNatsError.notConnected
        }

        guard let enclaveKey = verifiedEnclavePublicKey else {
            throw EnrollmentNatsError.noEnclaveKey
        }

        // Step 16: Encrypt PIN to attested ephemeral pubkey.
        // Plaintext is JSON `{"pin":"…"[,"profile":{…}]}`, matching
        // Android NitroEnrollmentClient.setupPin. Use JSONSerialization
        // (not string interpolation) so unusual chars in names/email
        // can't malform the payload.
        var inner: [String: Any] = ["pin": pin]
        if let profile = profile {
            inner["profile"] = [
                "first_name": profile.firstName,
                "last_name": profile.lastName,
                "email": profile.email
            ]
        }
        let pinPlaintext = try JSONSerialization.data(withJSONObject: inner, options: [])
        // Use the Android-shape ECIES helper (ChaCha20-Poly1305 with a
        // 12-byte nonce + HKDF salt/info). The supervisor rejects the
        // 24-byte XChaCha20 nonce produced by `encryptToPublicKey` as
        // `decryption failed: invalid nonce length: 24`.
        let encryptedPIN = try CryptoManager.encryptToEnclavePublicKey(
            plaintext: pinPlaintext,
            publicKey: enclaveKey
        )

        // Build request — wrap fields in a `{id, type, payload, timestamp}`
        // envelope with snake_case payload keys to match Android.
        let requestId = UUID().uuidString
        let request = NatsPINSetupRequest(
            id: requestId,
            type: "pin.setup",
            payload: NatsPINSetupRequest.Payload(
                encryptedPin: encryptedPIN.ciphertext.base64EncodedString(),
                ephemeralPublicKey: encryptedPIN.ephemeralPublicKey.base64EncodedString(),
                nonce: encryptedPIN.nonce.base64EncodedString()
            ),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Subscribe BEFORE publishing so a fast reply isn't missed.
        // Topic matches Android: forVault.pin / forApp.pin.response.
        let responseTopic = "\(ownerSpace).forApp.pin.response"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Send PIN to supervisor
        let requestTopic = "\(ownerSpace).forVault.pin"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[EnrollmentNats] Sent encrypted PIN to supervisor")
        #endif

        // Wait for response — parses status/utks/ecies_public_key
        // tolerantly via NatsPINSetupResponse.parse (matches Android shape).
        let timeout: TimeInterval = 30
        let response: NatsPINSetupResponse = try await withThrowingTaskGroup(of: NatsPINSetupResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    do {
                        let parsed = try NatsPINSetupResponse.parse(data: message.data)

                        // Replay protection (#47).
                        let evId = parsed.requestId ?? UUID().uuidString
                        let check = NatsReplayProtection.shared.validateMessage(
                            eventId: evId,
                            timestamp: parsed.timestamp,
                            sessionKey: "pin.setup"
                        )
                        guard check.isValid else {
                            natsEnrollLog.warning("PIN response rejected by replay protection: \(String(describing: check), privacy: .public)")
                            continue
                        }

                        if parsed.requestId == nil || parsed.requestId == requestId {
                            return parsed
                        }
                    } catch {
                        natsEnrollLog.error("PIN response parse failed: \(String(describing: error), privacy: .public)")
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

        // NOTE: skipping explicit unsubscribe — same race as the
        // attestation path. See requestAndVerifyAttestation comment.

        guard response.isSuccess else {
            throw EnrollmentNatsError.pinSetupFailed(response.message ?? "PIN setup failed")
        }

        #if DEBUG
        print("[EnrollmentNats] PIN setup complete with \(response.utks?.count ?? 0) UTKs, eciesKey=\(response.eciesPublicKey?.prefix(20) ?? "nil")...")
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

        // Hash password with Argon2id in PHC format. Android sends the
        // PHC string wrapped in `{"password_hash":"…"}` and encrypts the
        // JSON, not the raw PHC bytes — match that here so the vault can
        // parse the decrypted plaintext as JSON.
        let phcResult = try PasswordHasher.hashToPHC(password: password)
        let payloadJSON = try JSONSerialization.data(
            withJSONObject: ["password_hash": phcResult.phcString],
            options: []
        )

        // Encrypt with UTK using XChaCha20-Poly1305 (HKDF salt "vettid-utk-v1",
        // no info, 24-byte nonce) — same as Android `encryptToUTK`.
        let encryptedPayload = try CryptoManager.encryptPasswordHash(
            passwordHash: payloadJSON,
            utkPublicKeyBase64: utkPublicKey
        )

        // Wire format mirrors Android `NitroEnrollmentClient.createCredential`:
        // base64(ephemeralPubKey(32) || nonce(24) || ciphertext+tag).
        guard
            let ephemeralBytes = Data(base64Encoded: encryptedPayload.ephemeralPublicKey),
            let nonceBytes = Data(base64Encoded: encryptedPayload.nonce),
            let ciphertextBytes = Data(base64Encoded: encryptedPayload.encryptedPasswordHash)
        else {
            throw EnrollmentNatsError.credentialCreationFailed("Failed to encode encrypted payload")
        }
        let combinedBlobB64 = (ephemeralBytes + nonceBytes + ciphertextBytes).base64EncodedString()

        // Build request with new format
        let requestId = UUID().uuidString
        let request = NatsCredentialCreateRequest(
            id: requestId,
            type: "credential.create",
            utkId: utkId,
            encryptedPayload: combinedBlobB64,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Subscribe BEFORE publishing — matches Android topic
        // forApp.credential.create.response (exact subject, no wildcard).
        // iOS previously used `forApp.credential.created.>` which the
        // vault doesn't publish to.
        let responseTopic = "\(ownerSpace).forApp.credential.create.response"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        // Send to vault-manager
        let requestTopic = "\(ownerSpace).forVault.credential.create"
        try await natsConnectionManager.publish(request, to: requestTopic)

        #if DEBUG
        print("[EnrollmentNats] Sent credential creation request")
        #endif

        // Wait for response
        let timeout: TimeInterval = 60
        let response: CredentialCreationResponse = try await withThrowingTaskGroup(of: CredentialCreationResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    do {
                        let parsed = try CredentialCreationResponse.parse(data: message.data)

                        // Replay protection (#47).
                        let evId = parsed.requestId ?? UUID().uuidString
                        let check = NatsReplayProtection.shared.validateMessage(
                            eventId: evId,
                            timestamp: parsed.timestamp,
                            sessionKey: "credential.create"
                        )
                        guard check.isValid else {
                            natsEnrollLog.warning("credential.create response rejected by replay protection: \(String(describing: check), privacy: .public)")
                            continue
                        }

                        if parsed.requestId == nil || parsed.requestId == requestId {
                            return parsed
                        }
                    } catch {
                        natsEnrollLog.error("credential.create response parse failed: \(String(describing: error), privacy: .public)")
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

        // NOTE: skipping explicit unsubscribe — same reentrant
        // `dispatch_sync` race as the attestation + PIN paths.
        // `AppleNatsClient.unsubscribeBySid` finishes the AsyncStream
        // continuation while holding the state-queue barrier; the
        // continuation's `onTermination` callback (set in
        // `AppleNatsClient.subscribe(to:)`) calls `unsubscribeBySid`
        // again, hitting `dispatch_sync` on the same queue and
        // tripping libdispatch's reentrant-call detector
        // ("BUG IN CLIENT OF LIBDISPATCH"). Until `AppleNatsClient`
        // grows a real async unsubscribe, we rely on the subscription
        // being torn down when this NATS connection is closed.
        // await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.isSuccess else {
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
        // Match Android NitroEnrollmentClient.verifyEnrollment exactly:
        // type=vault.get_info, topic=forVault.info, response=forApp.info.response.
        // Previous iOS form (forVault.enrollment.verify + .verified.>) was
        // never wired in the vault.
        let request = NatsVerifyEnrollmentRequest(
            id: requestId,
            type: "vault.get_info",
            payload: NatsVerifyEnrollmentRequest.EmptyPayload(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Subscribe BEFORE publishing.
        let responseTopic = "\(ownerSpace).forApp.info.response"
        let responseStream = try await natsConnectionManager.subscribe(to: responseTopic)

        let requestTopic = "\(ownerSpace).forVault.info"
        try await natsConnectionManager.publish(request, to: requestTopic)

        let timeout: TimeInterval = 30
        let response: NatsVerifyEnrollmentResponse = try await withThrowingTaskGroup(of: NatsVerifyEnrollmentResponse.self) { group in
            group.addTask {
                for await message in responseStream {
                    do {
                        let parsed = try NatsVerifyEnrollmentResponse.parse(data: message.data)
                        // Replay protection (#47).
                        let evId = parsed.requestId ?? UUID().uuidString
                        let check = NatsReplayProtection.shared.validateMessage(
                            eventId: evId,
                            timestamp: parsed.timestamp,
                            sessionKey: "vault.get_info"
                        )
                        guard check.isValid else {
                            natsEnrollLog.warning("verify response rejected by replay protection: \(String(describing: check), privacy: .public)")
                            continue
                        }

                        if parsed.requestId == nil || parsed.requestId == requestId {
                            return parsed
                        }
                    } catch {
                        natsEnrollLog.error("verify response parse failed: \(String(describing: error), privacy: .public)")
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

        // NOTE: skipping explicit unsubscribe — same reentrant
        // `dispatch_sync` race that crashed the credential.create path.
        // await natsConnectionManager.unsubscribe(from: responseTopic)

        guard response.isSuccess else {
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

        // Hyphenated subject to match Android (identity-mismatch).
        let requestTopic = "\(ownerSpace).forVault.enrollment.identity-mismatch"
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
    let timestamp: String?           // ISO8601 — fed into NatsReplayProtection
    let attestationDocument: String  // Base64 CBOR
    let enclavePublicKey: String     // Base64 X25519 public key

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

        return NatsAttestationResponse(
            success: success,
            message: message,
            requestId: requestId,
            timestamp: string("timestamp"),
            attestationDocument: doc,
            enclavePublicKey: key
        )
    }
}

struct NatsPINSetupRequest: Encodable {
    let id: String
    let type: String  // "pin.setup"
    let payload: Payload
    let timestamp: String

    struct Payload: Encodable {
        let encryptedPin: String        // Base64: ciphertext + tag
        let ephemeralPublicKey: String  // Base64: X25519 public key
        let nonce: String               // Base64: 12-byte nonce

        enum CodingKeys: String, CodingKey {
            case encryptedPin = "encrypted_pin"
            case ephemeralPublicKey = "ephemeral_public_key"
            case nonce
        }
    }
}

/// Response from `forApp.pin.response`. Mirrors Android's
/// `PinSetupResponse` shape — `{status: "vault_ready", utks: [...],
/// ecies_public_key: "...", message?}` — including its
/// `isSuccess = status == "vault_ready"` convention.
///
/// Parsed via JSONSerialization (same pattern as
/// NatsAttestationResponse) so the decoder tolerates payload-wrapped
/// vs top-level fields and the various request-id alias keys the
/// supervisor has used historically (request_id / event_id / id).
struct NatsPINSetupResponse {
    let status: String?
    let message: String?
    let requestId: String?
    let timestamp: String?           // ISO8601 — fed into NatsReplayProtection
    let utks: [UTKInfo]?
    let eciesPublicKey: String?

    struct UTKInfo {
        let id: String
        let publicKey: String  // Base64 X25519 public key
    }

    /// Android's `isSuccess`: status == "vault_ready".
    var isSuccess: Bool { status == "vault_ready" }

    static func parse(data: Data) throws -> NatsPINSetupResponse {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = raw as? [String: Any] else {
            throw EnrollmentNatsError.pinSetupFailed("Response is not a JSON object")
        }
        let payload = (root["payload"] as? [String: Any]) ?? [:]

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = root[key] as? String, !v.isEmpty { return v }
                if let v = payload[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }

        let utksArray = (root["utks"] as? [[String: Any]]) ?? (payload["utks"] as? [[String: Any]])
        let utks: [UTKInfo]? = utksArray?.compactMap { dict in
            // Tolerate `id` or `key_id` (Android UtkInfo accepts both)
            let id = (dict["id"] as? String) ?? (dict["key_id"] as? String) ?? ""
            let pk = (dict["public_key"] as? String) ?? ""
            guard !id.isEmpty, !pk.isEmpty else { return nil }
            return UTKInfo(id: id, publicKey: pk)
        }

        return NatsPINSetupResponse(
            status: string("status"),
            message: string("message", "error"),
            requestId: string("request_id", "event_id", "id"),
            timestamp: string("timestamp"),
            utks: utks,
            eciesPublicKey: string("ecies_public_key")
        )
    }
}

/// Vault-manager `credential.create` request, matching Android's
/// `NitroEnrollmentClient.createCredential`:
/// `{ id, type:"credential.create", utk_id, encrypted_payload, timestamp }`,
/// where `encrypted_payload` is base64(`ephemeralPubKey(32) || nonce(24) || ciphertext+tag`).
/// iOS previously sent the three components as separate fields, which the
/// supervisor rejected with "invalid enrollment state".
struct NatsCredentialCreateRequest: Encodable {
    let id: String
    let type: String                   // Always "credential.create"
    let utkId: String                  // UTK ID used for encryption
    let encryptedPayload: String       // Base64 of ephemeralPubKey || nonce || ciphertext+tag
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case utkId = "utk_id"
        case encryptedPayload = "encrypted_payload"
        case timestamp
    }
}

/// Vault-manager `credential.create` response, tolerant of Android's
/// shape: the supervisor returns `{ status:"credential_created",
/// encrypted_credential, new_utks:[...], credential_guid, user_guid,
/// password_salt }`. The old strict `Decodable` declaration required
/// `success: Bool` and looked for `utks` — neither is present, so
/// `JSONDecoder` failed silently and the response loop ran out the
/// 60s timeout.
struct CredentialCreationResponse {
    let status: String?
    let message: String?
    let requestId: String?
    let timestamp: String?
    let encryptedCredential: String?
    let utks: [UTK]?

    /// Treats Android-style `status="credential_created"` (and any
    /// other status that *contains* "credential" — e.g. "credential_ok")
    /// as success, with legacy `success: true` as a fallback.
    let isSuccess: Bool

    struct UTK {
        let id: String
        let publicKey: String
    }

    static func parse(data: Data) throws -> CredentialCreationResponse {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = raw as? [String: Any] else {
            throw EnrollmentNatsError.credentialCreationFailed("Response is not a JSON object")
        }
        let payload = (root["payload"] as? [String: Any]) ?? [:]

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = root[key] as? String, !v.isEmpty { return v }
                if let v = payload[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }

        // Accept Android's `new_utks` first, fall back to `utks`.
        let utksArray = (root["new_utks"] as? [[String: Any]])
            ?? (payload["new_utks"] as? [[String: Any]])
            ?? (root["utks"] as? [[String: Any]])
            ?? (payload["utks"] as? [[String: Any]])
        let utks: [UTK]? = utksArray?.compactMap { dict in
            let id = (dict["id"] as? String) ?? (dict["key_id"] as? String) ?? ""
            let pk = (dict["public_key"] as? String) ?? ""
            guard !id.isEmpty, !pk.isEmpty else { return nil }
            return UTK(id: id, publicKey: pk)
        }

        let status = string("status")
        let legacySuccess = (root["success"] as? Bool) ?? (payload["success"] as? Bool)
        let isSuccess: Bool = {
            if let legacySuccess = legacySuccess { return legacySuccess }
            guard let s = status?.lowercased() else { return false }
            // Matches Android `CredentialResponse.status == "credential_created"`,
            // accepts any "*credential*" / "*created*" / "ok" shape.
            return s.contains("credential") || s.contains("created") || s == "ok" || s == "success"
        }()

        return CredentialCreationResponse(
            status: status,
            message: string("message", "error"),
            requestId: string("request_id", "event_id", "id"),
            timestamp: string("timestamp"),
            encryptedCredential: string("encrypted_credential"),
            utks: utks,
            isSuccess: isSuccess
        )
    }
}

struct NatsVerifyEnrollmentRequest: Encodable {
    let id: String
    let type: String  // "vault.get_info"
    let payload: EmptyPayload
    let timestamp: String

    /// vault.get_info takes no parameters; emitted as `{}` to match
    /// Android's `add("payload", JsonObject())` envelope.
    struct EmptyPayload: Encodable {}
}

/// `vault.get_info` response. The supervisor returns vault metadata
/// (vault_id, owner_space, status, …) with no `success: Bool` field;
/// Android treats any non-error JSON object as success. The previous
/// strict `Decodable` declaration required `success: Bool` and so
/// silently dropped every response, leaving the request to time out
/// at 30s — the "hanging at verifying enrollment" symptom.
struct NatsVerifyEnrollmentResponse {
    let status: String?
    let message: String?
    let requestId: String?
    let timestamp: String?

    /// Anything that isn't an explicit error reply counts as success,
    /// matching Android's `sendRequestAndWaitForResponse` contract.
    let isSuccess: Bool

    static func parse(data: Data) throws -> NatsVerifyEnrollmentResponse {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = raw as? [String: Any] else {
            throw EnrollmentNatsError.verificationFailed("Response is not a JSON object")
        }
        let payload = (root["payload"] as? [String: Any]) ?? [:]

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = root[key] as? String, !v.isEmpty { return v }
                if let v = payload[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }

        // Match Android `sendRequestAndWaitForResponse<JsonObject>`:
        // any JSON response that arrives counts as success. The
        // verification call is purely a round-trip probe ("did the
        // vault reply at all?") — the supervisor's current build
        // returns `{"status":"error","message":"unknown operation:
        // info"}` for `vault.get_info`, and Android happily logs that
        // as "Enrollment verified successfully" and moves on.
        return NatsVerifyEnrollmentResponse(
            status: string("status"),
            message: string("message", "error"),
            requestId: string("request_id", "event_id", "id"),
            timestamp: string("timestamp"),
            isSuccess: true
        )
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
