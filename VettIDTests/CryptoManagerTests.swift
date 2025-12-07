import XCTest
import CryptoKit
@testable import VettID

final class CryptoManagerTests: XCTestCase {

    // MARK: - X25519 Key Generation Tests

    func testGenerateX25519KeyPair() {
        let (privateKey, publicKey) = CryptoManager.generateX25519KeyPair()

        // Verify key sizes
        XCTAssertEqual(privateKey.rawRepresentation.count, 32, "X25519 private key should be 32 bytes")
        XCTAssertEqual(publicKey.rawRepresentation.count, 32, "X25519 public key should be 32 bytes")

        // Verify public key is derived from private key
        XCTAssertEqual(privateKey.publicKey.rawRepresentation, publicKey.rawRepresentation)
    }

    func testX25519KeyPairsAreUnique() {
        let (_, publicKey1) = CryptoManager.generateX25519KeyPair()
        let (_, publicKey2) = CryptoManager.generateX25519KeyPair()

        XCTAssertNotEqual(
            publicKey1.rawRepresentation,
            publicKey2.rawRepresentation,
            "Generated key pairs should be unique"
        )
    }

    // MARK: - Ed25519 Signing Tests

    func testGenerateEd25519KeyPair() {
        let (privateKey, publicKey) = CryptoManager.generateEd25519KeyPair()

        XCTAssertEqual(privateKey.rawRepresentation.count, 32, "Ed25519 private key should be 32 bytes")
        XCTAssertEqual(publicKey.rawRepresentation.count, 32, "Ed25519 public key should be 32 bytes")
    }

    func testSignAndVerify() throws {
        let (privateKey, publicKey) = CryptoManager.generateEd25519KeyPair()
        let message = "Hello, VettID!".data(using: .utf8)!

        let signature = try CryptoManager.sign(data: message, privateKey: privateKey)

        XCTAssertEqual(signature.count, 64, "Ed25519 signature should be 64 bytes")
        XCTAssertTrue(
            CryptoManager.verify(signature: signature, for: message, publicKey: publicKey),
            "Valid signature should verify"
        )
    }

    func testSignatureVerificationFailsForTamperedMessage() throws {
        let (privateKey, publicKey) = CryptoManager.generateEd25519KeyPair()
        let message = "Hello, VettID!".data(using: .utf8)!
        let tamperedMessage = "Hello, Hacker!".data(using: .utf8)!

        let signature = try CryptoManager.sign(data: message, privateKey: privateKey)

        XCTAssertFalse(
            CryptoManager.verify(signature: signature, for: tamperedMessage, publicKey: publicKey),
            "Signature should not verify for tampered message"
        )
    }

    func testSignatureVerificationFailsForWrongKey() throws {
        let (privateKey, _) = CryptoManager.generateEd25519KeyPair()
        let (_, wrongPublicKey) = CryptoManager.generateEd25519KeyPair()
        let message = "Hello, VettID!".data(using: .utf8)!

        let signature = try CryptoManager.sign(data: message, privateKey: privateKey)

        XCTAssertFalse(
            CryptoManager.verify(signature: signature, for: message, publicKey: wrongPublicKey),
            "Signature should not verify with wrong public key"
        )
    }

    // MARK: - Hybrid Encryption Tests (X25519 + ChaCha20-Poly1305)

    func testEncryptAndDecrypt() throws {
        let (recipientPrivateKey, recipientPublicKey) = CryptoManager.generateX25519KeyPair()
        let plaintext = "Secret credential data".data(using: .utf8)!

        let encrypted = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)
        let decrypted = try CryptoManager.decrypt(payload: encrypted, privateKey: recipientPrivateKey)

        XCTAssertEqual(decrypted, plaintext, "Decrypted data should match original plaintext")
    }

    func testEncryptedPayloadComponents() throws {
        let (_, recipientPublicKey) = CryptoManager.generateX25519KeyPair()
        let plaintext = "Test data".data(using: .utf8)!

        let encrypted = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)

        XCTAssertEqual(encrypted.ephemeralPublicKey.count, 32, "Ephemeral public key should be 32 bytes")
        XCTAssertEqual(encrypted.nonce.count, 12, "ChaCha20-Poly1305 nonce should be 12 bytes")
        XCTAssertEqual(encrypted.tag.count, 16, "Poly1305 tag should be 16 bytes")
        XCTAssertEqual(encrypted.ciphertext.count, plaintext.count, "Ciphertext length should match plaintext")
    }

    func testDecryptionFailsWithWrongKey() throws {
        let (_, recipientPublicKey) = CryptoManager.generateX25519KeyPair()
        let (wrongPrivateKey, _) = CryptoManager.generateX25519KeyPair()
        let plaintext = "Secret data".data(using: .utf8)!

        let encrypted = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)

        XCTAssertThrowsError(try CryptoManager.decrypt(payload: encrypted, privateKey: wrongPrivateKey)) { error in
            // Should throw a CryptoKit error for authentication failure
            XCTAssertNotNil(error)
        }
    }

    func testEncryptionProducesDifferentCiphertexts() throws {
        let (_, recipientPublicKey) = CryptoManager.generateX25519KeyPair()
        let plaintext = "Same message".data(using: .utf8)!

        let encrypted1 = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)
        let encrypted2 = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)

        // Due to random ephemeral keys and nonces, ciphertexts should differ
        XCTAssertNotEqual(encrypted1.ciphertext, encrypted2.ciphertext)
        XCTAssertNotEqual(encrypted1.ephemeralPublicKey, encrypted2.ephemeralPublicKey)
        XCTAssertNotEqual(encrypted1.nonce, encrypted2.nonce)
    }

    // MARK: - Password Encryption Tests

    func testEncryptPasswordHash() throws {
        let (_, utkPublicKey) = CryptoManager.generateX25519KeyPair()
        let passwordHash = CryptoManager.randomBytes(count: 32)  // Simulated Argon2id hash

        let encrypted = try CryptoManager.encryptPasswordHash(
            passwordHash: passwordHash,
            utkPublicKeyBase64: utkPublicKey.rawRepresentation.base64EncodedString()
        )

        XCTAssertFalse(encrypted.encryptedPasswordHash.isEmpty, "Encrypted hash should not be empty")
        XCTAssertFalse(encrypted.ephemeralPublicKey.isEmpty, "Ephemeral public key should not be empty")
        XCTAssertFalse(encrypted.nonce.isEmpty, "Nonce should not be empty")

        // Verify base64 encoding
        XCTAssertNotNil(Data(base64Encoded: encrypted.encryptedPasswordHash))
        XCTAssertNotNil(Data(base64Encoded: encrypted.ephemeralPublicKey))
        XCTAssertNotNil(Data(base64Encoded: encrypted.nonce))
    }

    func testEncryptPasswordHashWithInvalidPublicKey() {
        let passwordHash = CryptoManager.randomBytes(count: 32)
        let invalidPublicKey = "not-valid-base64-!@#$"

        XCTAssertThrowsError(try CryptoManager.encryptPasswordHash(
            passwordHash: passwordHash,
            utkPublicKeyBase64: invalidPublicKey
        )) { error in
            XCTAssertEqual(error as? CryptoError, CryptoError.invalidPublicKey)
        }
    }

    // MARK: - Random Generation Tests

    func testRandomBytesLength() {
        let lengths = [16, 32, 64, 128]
        for length in lengths {
            let bytes = CryptoManager.randomBytes(count: length)
            XCTAssertEqual(bytes.count, length, "Random bytes should have requested length")
        }
    }

    func testRandomBytesAreUnique() {
        let random1 = CryptoManager.randomBytes(count: 32)
        let random2 = CryptoManager.randomBytes(count: 32)

        XCTAssertNotEqual(random1, random2, "Random bytes should be unique")
    }

    func testGenerateToken() {
        let token = CryptoManager.generateToken()
        XCTAssertEqual(token.count, 32, "Token should be 32 bytes (256 bits)")
    }

    func testGenerateSalt() {
        let salt = CryptoManager.generateSalt()
        XCTAssertEqual(salt.count, 16, "Salt should be 16 bytes")
    }

    // MARK: - Combined Payload Tests

    func testEncryptedPayloadCombined() throws {
        let (_, recipientPublicKey) = CryptoManager.generateX25519KeyPair()
        let plaintext = "Test".data(using: .utf8)!

        let encrypted = try CryptoManager.encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey)

        let expectedLength = 32 + 12 + plaintext.count + 16  // ephemeral + nonce + ciphertext + tag
        XCTAssertEqual(encrypted.combined.count, expectedLength)
    }
}
