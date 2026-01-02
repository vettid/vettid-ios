import XCTest
import CryptoKit
@testable import VettID

/// Tests for SessionKeyManager
final class SessionKeyManagerTests: XCTestCase {

    var manager: SessionKeyManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = SessionKeyManager()
        // Clear any existing session
        await manager.clearSession()
    }

    override func tearDown() async throws {
        await manager.clearSession()
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialStateHasNoActiveSession() async {
        // When
        let hasSession = await manager.hasActiveSession

        // Then
        XCTAssertFalse(hasSession)
    }

    func testInitialSessionIdIsNil() async {
        // When
        let sessionId = await manager.currentSessionId

        // Then
        XCTAssertNil(sessionId)
    }

    // MARK: - Bootstrap Tests

    func testInitiateBootstrap() async throws {
        // When
        let request = try await manager.initiateBootstrap()

        // Then
        XCTAssertFalse(request.requestId.isEmpty)
        XCTAssertFalse(request.appPublicKey.isEmpty)
        XCTAssertFalse(request.deviceId.isEmpty)
        XCTAssertFalse(request.timestamp.isEmpty)

        // Verify public key is valid base64
        XCTAssertNotNil(Data(base64Encoded: request.appPublicKey))
    }

    func testInitiateBootstrapTwiceThrows() async throws {
        // Given - first bootstrap
        _ = try await manager.initiateBootstrap()

        // When/Then - second bootstrap should throw
        do {
            _ = try await manager.initiateBootstrap()
            XCTFail("Should throw bootstrapInProgress")
        } catch SessionKeyManager.SessionError.bootstrapInProgress {
            // Expected
        }
    }

    func testCancelBootstrap() async throws {
        // Given
        _ = try await manager.initiateBootstrap()

        // When
        await manager.cancelBootstrap()

        // Then - can initiate new bootstrap
        let request = try await manager.initiateBootstrap()
        XCTAssertFalse(request.requestId.isEmpty)
    }

    func testCompleteBootstrapWithoutPendingThrows() async {
        // Given - no pending bootstrap
        let response = makeBootstrapResponse(
            requestId: "test-id",
            vaultPublicKey: "invalid",
            sessionId: "session-1"
        )

        // When/Then
        do {
            try await manager.completeBootstrap(response: response)
            XCTFail("Should throw bootstrapFailed")
        } catch SessionKeyManager.SessionError.bootstrapFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteBootstrapWithMismatchedRequestId() async throws {
        // Given
        _ = try await manager.initiateBootstrap()

        let response = makeBootstrapResponse(
            requestId: "different-id",  // Doesn't match
            vaultPublicKey: "some-key",
            sessionId: "session-1"
        )

        // When/Then
        do {
            try await manager.completeBootstrap(response: response)
            XCTFail("Should throw bootstrapFailed")
        } catch SessionKeyManager.SessionError.bootstrapFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteBootstrapWithInvalidPublicKey() async throws {
        // Given
        let request = try await manager.initiateBootstrap()

        let response = makeBootstrapResponse(
            requestId: request.requestId,
            vaultPublicKey: "not-valid-base64!!!",
            sessionId: "session-1"
        )

        // When/Then
        do {
            try await manager.completeBootstrap(response: response)
            XCTFail("Should throw invalidPublicKey")
        } catch SessionKeyManager.SessionError.invalidPublicKey {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSuccessfulBootstrap() async throws {
        // Given
        let request = try await manager.initiateBootstrap()

        // Generate a valid vault keypair
        let vaultPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let vaultPublicKey = vaultPrivateKey.publicKey

        let response = makeBootstrapResponse(
            requestId: request.requestId,
            vaultPublicKey: vaultPublicKey.rawRepresentation.base64EncodedString(),
            sessionId: "session-123"
        )

        // When
        try await manager.completeBootstrap(response: response)

        // Then
        let hasSession = await manager.hasActiveSession
        let sessionId = await manager.currentSessionId

        XCTAssertTrue(hasSession)
        XCTAssertEqual(sessionId, "session-123")
    }

    // MARK: - Encryption/Decryption Tests

    func testEncryptWithoutSessionThrows() async {
        // Given - no session
        let message = "Hello, Vault!".data(using: .utf8)!

        // When/Then
        do {
            _ = try await manager.encrypt(message: message)
            XCTFail("Should throw noActiveSession")
        } catch SessionKeyManager.SessionError.noActiveSession {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecryptWithoutSessionThrows() async {
        // Given - no session
        let envelope = EncryptedEnvelope(
            sessionId: "test",
            ciphertext: "abc",
            nonce: "def"
        )

        // When/Then
        do {
            _ = try await manager.decrypt(envelope: envelope)
            XCTFail("Should throw noActiveSession")
        } catch SessionKeyManager.SessionError.noActiveSession {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEncryptDecryptRoundTrip() async throws {
        // Given - establish session
        try await establishSession()

        let originalMessage = "Secret message for the vault".data(using: .utf8)!

        // When
        let envelope = try await manager.encrypt(message: originalMessage)
        let decrypted = try await manager.decrypt(envelope: envelope)

        // Then
        XCTAssertEqual(decrypted, originalMessage)
    }

    func testDecryptWithWrongSessionIdThrows() async throws {
        // Given - establish session
        try await establishSession()

        let envelope = EncryptedEnvelope(
            sessionId: "wrong-session",
            ciphertext: "abc",
            nonce: "def"
        )

        // When/Then
        do {
            _ = try await manager.decrypt(envelope: envelope)
            XCTFail("Should throw decryptionFailed")
        } catch SessionKeyManager.SessionError.decryptionFailed {
            // Expected
        }
    }

    func testEncryptedEnvelopeHasValidFormat() async throws {
        // Given
        try await establishSession()
        let message = "Test".data(using: .utf8)!

        // When
        let envelope = try await manager.encrypt(message: message)

        // Then
        XCTAssertFalse(envelope.sessionId.isEmpty)
        XCTAssertFalse(envelope.ciphertext.isEmpty)
        XCTAssertFalse(envelope.nonce.isEmpty)

        // Verify base64 encoding
        XCTAssertNotNil(Data(base64Encoded: envelope.ciphertext))
        XCTAssertNotNil(Data(base64Encoded: envelope.nonce))

        // Nonce should be 12 bytes
        XCTAssertEqual(Data(base64Encoded: envelope.nonce)?.count, 12)
    }

    // MARK: - Key Rotation Tests

    func testShouldRotateKeyWhenNoSession() async {
        // When
        let shouldRotate = await manager.shouldRotateKey()

        // Then
        XCTAssertFalse(shouldRotate)
    }

    func testShouldRotateKeyInitially() async throws {
        // Given - fresh session
        try await establishSession()

        // When
        let shouldRotate = await manager.shouldRotateKey()

        // Then - fresh session should not need rotation
        XCTAssertFalse(shouldRotate)
    }

    func testInitiateKeyRotationWithoutSessionThrows() async {
        // When/Then
        do {
            _ = try await manager.initiateKeyRotation()
            XCTFail("Should throw noActiveSession")
        } catch SessionKeyManager.SessionError.noActiveSession {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInitiateKeyRotation() async throws {
        // Given
        try await establishSession()

        // When
        let (request, privateKey) = try await manager.initiateKeyRotation()

        // Then
        XCTAssertFalse(request.sessionId.isEmpty)
        XCTAssertFalse(request.newPublicKey.isEmpty)
        XCTAssertFalse(request.timestamp.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: request.newPublicKey))
    }

    // MARK: - Session Management Tests

    func testClearSession() async throws {
        // Given
        try await establishSession()
        var hasSession = await manager.hasActiveSession
        XCTAssertTrue(hasSession)

        // When
        await manager.clearSession()

        // Then
        hasSession = await manager.hasActiveSession
        XCTAssertFalse(hasSession)
    }

    // MARK: - Error Description Tests

    func testSessionErrorDescriptions() {
        let errors: [SessionKeyManager.SessionError] = [
            .noActiveSession,
            .bootstrapInProgress,
            .bootstrapFailed("test reason"),
            .encryptionFailed("test reason"),
            .decryptionFailed("test reason"),
            .invalidPublicKey,
            .keyRotationRequired,
            .sessionExpired
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - Helper Methods

    private func establishSession() async throws {
        let request = try await manager.initiateBootstrap()

        let vaultPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let vaultPublicKey = vaultPrivateKey.publicKey

        let response = makeBootstrapResponse(
            requestId: request.requestId,
            vaultPublicKey: vaultPublicKey.rawRepresentation.base64EncodedString(),
            sessionId: "test-session-\(UUID().uuidString)"
        )

        try await manager.completeBootstrap(response: response)
    }

    private func makeBootstrapResponse(
        requestId: String,
        vaultPublicKey: String,
        sessionId: String
    ) -> BootstrapResponse {
        // Use JSON decoding to create BootstrapResponse with optional fields
        let json: [String: Any] = [
            "request_id": requestId,
            "vault_public_key": vaultPublicKey,
            "session_id": sessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(BootstrapResponse.self, from: data)
    }
}

// MARK: - EncryptedEnvelope Tests

extension SessionKeyManagerTests {

    func testEncryptedEnvelopeCodable() throws {
        // Given
        let original = EncryptedEnvelope(
            sessionId: "session-123",
            ciphertext: "Y2lwaGVydGV4dA==",
            nonce: "bm9uY2U="
        )

        // When
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EncryptedEnvelope.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.sessionId, original.sessionId)
        XCTAssertEqual(decoded.ciphertext, original.ciphertext)
        XCTAssertEqual(decoded.nonce, original.nonce)
    }

    func testEncryptedEnvelopeWithEphemeralKey() throws {
        // Given
        let envelope = EncryptedEnvelope(
            sessionId: "session-123",
            ciphertext: "Y2lwaGVydGV4dA==",
            nonce: "bm9uY2U=",
            ephemeralPublicKey: "ZXBoZW1lcmFs"
        )

        // When
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(EncryptedEnvelope.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.ephemeralPublicKey, "ZXBoZW1lcmFs")
    }
}

// MARK: - Bootstrap/Rotation Request Tests

extension SessionKeyManagerTests {

    func testBootstrapRequestCodable() throws {
        // Given
        let request = BootstrapRequest(
            requestId: "req-123",
            appPublicKey: "cHVibGljS2V5",
            deviceId: "device-456",
            timestamp: "2024-01-01T12:00:00Z"
        )

        // When
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BootstrapRequest.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.requestId, request.requestId)
        XCTAssertEqual(decoded.appPublicKey, request.appPublicKey)
        XCTAssertEqual(decoded.deviceId, request.deviceId)
        XCTAssertEqual(decoded.timestamp, request.timestamp)
    }

    func testBootstrapResponseCodable() throws {
        // Given
        let json: [String: Any] = [
            "request_id": "req-123",
            "vault_public_key": "dmF1bHRLZXk=",
            "session_id": "session-789",
            "credentials": "Y3JlZHM=",
            "credentials_ttl": 7200
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try JSONDecoder().decode(BootstrapResponse.self, from: data)

        // When
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BootstrapResponse.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.requestId, response.requestId)
        XCTAssertEqual(decoded.sessionId, response.sessionId)
        XCTAssertEqual(decoded.credentialsTtl, 7200)
    }

    func testKeyRotationRequestCodable() throws {
        // Given
        let request = KeyRotationRequest(
            sessionId: "session-123",
            newPublicKey: "bmV3S2V5",
            timestamp: "2024-01-01T12:00:00Z"
        )

        // When
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(KeyRotationRequest.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.sessionId, request.sessionId)
        XCTAssertEqual(decoded.newPublicKey, request.newPublicKey)
    }
}
