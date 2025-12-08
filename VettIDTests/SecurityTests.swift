import XCTest
@testable import VettID

/// Security tests for VettID app
/// Tests runtime protection, secure memory, and cryptographic operations
final class SecurityTests: XCTestCase {

    // MARK: - RuntimeProtection Tests

    func testRuntimeProtectionSecurityStatus() {
        let status = RuntimeProtection.shared.checkSecurityStatus()

        // In test environment (simulator), we expect:
        XCTAssertTrue(status.isSimulator, "Tests should run in simulator")

        // These should typically be false in a normal test environment
        // Note: Some may be true if running on a jailbroken device or with debugging
        #if DEBUG
        // Debug builds may have debugger attached
        #else
        XCTAssertFalse(status.isDebuggerAttached, "No debugger should be attached in release")
        #endif
    }

    func testJailbreakDetectionPaths() {
        // Test that known jailbreak paths are checked
        // In simulator, these should not exist
        let status = RuntimeProtection.shared.checkSecurityStatus()

        #if targetEnvironment(simulator)
        XCTAssertFalse(status.isJailbroken, "Simulator should not appear jailbroken")
        #endif
    }

    func testSecurityStatusThreatReporting() {
        let status = RuntimeProtection.shared.checkSecurityStatus()

        // Verify threats are reported correctly
        if status.isSimulator {
            XCTAssertTrue(status.threats.contains("Running in simulator"))
        }
    }

    func testPerformSecurityCheck() {
        var threatDetected = false

        let isSecure = RuntimeProtection.shared.performSecurityCheck(
            allowSimulator: true,
            allowDebugger: true
        ) { _ in
            threatDetected = true
        }

        // With simulator and debugger allowed, should be secure (unless jailbroken/tampered)
        // In a normal test environment, expect secure
        XCTAssertTrue(isSecure || threatDetected, "Security check should complete")
    }

    // MARK: - SecureMemory Tests

    func testSecureBytesCreation() {
        let secureBytes = SecureMemory.SecureBytes(count: 32)
        XCTAssertEqual(secureBytes.count, 32)
        XCTAssertFalse(secureBytes.isCleared)
    }

    func testSecureBytesFromData() {
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let secureBytes = SecureMemory.SecureBytes(data: testData)

        secureBytes.withBytes { bytes in
            XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04])
        }
    }

    func testSecureBytesClearing() {
        let secureBytes = SecureMemory.SecureBytes(count: 32)
        XCTAssertFalse(secureBytes.isCleared)

        secureBytes.clear()

        XCTAssertTrue(secureBytes.isCleared)
        XCTAssertEqual(secureBytes.count, 0)
    }

    func testSecureBytesConstantTimeComparison() {
        let bytes1 = SecureMemory.SecureBytes(data: Data([0x01, 0x02, 0x03]))
        let bytes2 = SecureMemory.SecureBytes(data: Data([0x01, 0x02, 0x03]))
        let bytes3 = SecureMemory.SecureBytes(data: Data([0x01, 0x02, 0x04]))

        XCTAssertTrue(bytes1.constantTimeEquals(bytes2))
        XCTAssertFalse(bytes1.constantTimeEquals(bytes3))
    }

    func testSecureStringCreation() {
        let secureString = SecureMemory.SecureString(string: "password123")

        secureString.withString { string in
            XCTAssertEqual(string, "password123")
        }
    }

    func testSecureStringClearing() {
        let secureString = SecureMemory.SecureString(string: "sensitive")
        XCTAssertFalse(secureString.isCleared)

        secureString.clear()

        XCTAssertTrue(secureString.isCleared)
    }

    func testConstantTimeCompareData() {
        let data1 = Data([0x01, 0x02, 0x03, 0x04])
        let data2 = Data([0x01, 0x02, 0x03, 0x04])
        let data3 = Data([0x01, 0x02, 0x03, 0x05])
        let data4 = Data([0x01, 0x02, 0x03])

        XCTAssertTrue(SecureMemory.constantTimeCompare(data1, data2))
        XCTAssertFalse(SecureMemory.constantTimeCompare(data1, data3))
        XCTAssertFalse(SecureMemory.constantTimeCompare(data1, data4)) // Different lengths
    }

    func testSecureZeroData() {
        var data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        SecureMemory.secureZero(&data)
        XCTAssertTrue(data.isEmpty)
    }

    func testRandomBytesGeneration() {
        let random1 = SecureMemory.randomBytes(count: 32)
        let random2 = SecureMemory.randomBytes(count: 32)

        XCTAssertEqual(random1.count, 32)
        XCTAssertEqual(random2.count, 32)

        // Two random generations should be different (extremely unlikely to be the same)
        random1.withBytes { bytes1 in
            random2.withBytes { bytes2 in
                XCTAssertNotEqual(bytes1, bytes2)
            }
        }
    }

    // MARK: - CryptoManager Tests

    func testX25519KeyPairGeneration() {
        let keyPair = CryptoManager.generateX25519KeyPair()

        XCTAssertEqual(keyPair.publicKey.rawRepresentation.count, 32)
        XCTAssertEqual(keyPair.privateKey.rawRepresentation.count, 32)
    }

    func testEd25519KeyPairGeneration() {
        let keyPair = CryptoManager.generateEd25519KeyPair()

        XCTAssertEqual(keyPair.publicKey.rawRepresentation.count, 32)
        XCTAssertEqual(keyPair.privateKey.rawRepresentation.count, 32)
    }

    func testEd25519SignAndVerify() throws {
        let keyPair = CryptoManager.generateEd25519KeyPair()
        let message = Data("Test message".utf8)

        let signature = try CryptoManager.sign(data: message, privateKey: keyPair.privateKey)

        XCTAssertTrue(CryptoManager.verify(signature: signature, for: message, publicKey: keyPair.publicKey))

        // Verify fails with wrong message
        let wrongMessage = Data("Wrong message".utf8)
        XCTAssertFalse(CryptoManager.verify(signature: signature, for: wrongMessage, publicKey: keyPair.publicKey))
    }

    func testEncryptDecryptRoundTrip() throws {
        let recipientKeyPair = CryptoManager.generateX25519KeyPair()
        let plaintext = Data("Secret message".utf8)

        let encrypted = try CryptoManager.encrypt(
            plaintext: plaintext,
            recipientPublicKey: recipientKeyPair.publicKey
        )

        let decrypted = try CryptoManager.decrypt(
            payload: encrypted,
            privateKey: recipientKeyPair.privateKey
        )

        XCTAssertEqual(decrypted, plaintext)
    }

    func testRandomBytesAreRandom() {
        let random1 = CryptoManager.randomBytes(count: 32)
        let random2 = CryptoManager.randomBytes(count: 32)

        XCTAssertNotEqual(random1, random2)
    }

    func testGenerateToken() {
        let token = CryptoManager.generateToken()
        XCTAssertEqual(token.count, 32)
    }

    func testGenerateSalt() {
        let salt = CryptoManager.generateSalt()
        XCTAssertEqual(salt.count, 16)
    }

    // MARK: - RequestSigning Tests

    func testRequestSignerTimestampValidation() {
        let signer = RequestSigner(deviceId: "test-device")

        // Valid timestamp (current time)
        let validTimestamp = String(Int(Date().timeIntervalSince1970))
        XCTAssertTrue(signer.isTimestampValid(validTimestamp))

        // Invalid timestamp (too old)
        let oldTimestamp = String(Int(Date().timeIntervalSince1970 - 600)) // 10 minutes ago
        XCTAssertFalse(signer.isTimestampValid(oldTimestamp))

        // Invalid format
        XCTAssertFalse(signer.isTimestampValid("invalid"))
    }

    // MARK: - SecurePasteboard Tests

    func testSecurePasteboardRestrictedTypes() {
        XCTAssertTrue(SecurePasteboard.isRestricted(contentType: "private-key"))
        XCTAssertTrue(SecurePasteboard.isRestricted(contentType: "password"))
        XCTAssertTrue(SecurePasteboard.isRestricted(contentType: "seed-phrase"))
        XCTAssertTrue(SecurePasteboard.isRestricted(contentType: "recovery-key"))
        XCTAssertFalse(SecurePasteboard.isRestricted(contentType: "text"))
    }

    // MARK: - BiometricAuthService Tests

    func testBiometricTypeDisplayNames() {
        XCTAssertEqual(BiometricAuthService.BiometricType.none.displayName, "Passcode")
        XCTAssertEqual(BiometricAuthService.BiometricType.faceID.displayName, "Face ID")
        XCTAssertEqual(BiometricAuthService.BiometricType.touchID.displayName, "Touch ID")
        XCTAssertEqual(BiometricAuthService.BiometricType.opticID.displayName, "Optic ID")
    }

    func testBiometricTypeSystemImages() {
        XCTAssertEqual(BiometricAuthService.BiometricType.none.systemImage, "key.fill")
        XCTAssertEqual(BiometricAuthService.BiometricType.faceID.systemImage, "faceid")
        XCTAssertEqual(BiometricAuthService.BiometricType.touchID.systemImage, "touchid")
        XCTAssertEqual(BiometricAuthService.BiometricType.opticID.systemImage, "opticid")
    }

    func testBiometricErrorDescriptions() {
        XCTAssertNotNil(BiometricError.notAvailable.errorDescription)
        XCTAssertNotNil(BiometricError.notEnrolled.errorDescription)
        XCTAssertNotNil(BiometricError.lockout.errorDescription)
        XCTAssertNotNil(BiometricError.cancelled.errorDescription)
        XCTAssertNotNil(BiometricError.passcodeNotSet.errorDescription)
        XCTAssertNotNil(BiometricError.enrollmentChanged.errorDescription)
    }

    func testBiometricErrorRequiresPasscode() {
        XCTAssertTrue(BiometricError.lockout.requiresPasscode)
        XCTAssertTrue(BiometricError.notEnrolled.requiresPasscode)
        XCTAssertFalse(BiometricError.cancelled.requiresPasscode)
    }

    func testBiometricErrorRequiresReEnrollment() {
        XCTAssertTrue(BiometricError.enrollmentChanged.requiresReEnrollment)
        XCTAssertFalse(BiometricError.cancelled.requiresReEnrollment)
    }

    // MARK: - SecureKeyStore Tests

    func testSecureEnclaveAvailability() {
        // In simulator, Secure Enclave is typically not available
        #if targetEnvironment(simulator)
        // Secure Enclave check - may or may not be available depending on simulator
        _ = SecureKeyStore.isSecureEnclaveAvailable
        #else
        // On real devices, should be available on modern hardware
        XCTAssertTrue(SecureKeyStore.isSecureEnclaveAvailable)
        #endif
    }

    func testSecurityLevelEnum() {
        // Verify security level enum exists and has expected cases
        let standard = SecureKeyStore.SecurityLevel.standard
        let biometric = SecureKeyStore.SecurityLevel.biometric
        let biometricStrict = SecureKeyStore.SecurityLevel.biometricStrict

        XCTAssertNotNil(standard)
        XCTAssertNotNil(biometric)
        XCTAssertNotNil(biometricStrict)
    }
}

// MARK: - Performance Tests

extension SecurityTests {

    func testSecureBytesPerformance() {
        measure {
            for _ in 0..<1000 {
                let bytes = SecureMemory.SecureBytes(count: 32)
                bytes.clear()
            }
        }
    }

    func testConstantTimeComparePerformance() {
        let data1 = Data(repeating: 0xFF, count: 1024)
        let data2 = Data(repeating: 0xFF, count: 1024)

        measure {
            for _ in 0..<10000 {
                _ = SecureMemory.constantTimeCompare(data1, data2)
            }
        }
    }

    func testX25519KeyGenerationPerformance() {
        measure {
            for _ in 0..<100 {
                _ = CryptoManager.generateX25519KeyPair()
            }
        }
    }

    func testEncryptionPerformance() throws {
        let keyPair = CryptoManager.generateX25519KeyPair()
        let plaintext = Data(repeating: 0x42, count: 1024)

        measure {
            for _ in 0..<100 {
                _ = try? CryptoManager.encrypt(
                    plaintext: plaintext,
                    recipientPublicKey: keyPair.publicKey
                )
            }
        }
    }
}
