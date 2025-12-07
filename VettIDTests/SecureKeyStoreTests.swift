import XCTest
import CryptoKit
@testable import VettID

final class SecureKeyStoreTests: XCTestCase {

    var keyStore: SecureKeyStore!
    let testKeyId = "test-key-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        keyStore = SecureKeyStore()
    }

    override func tearDown() {
        // Clean up test keys
        try? keyStore.deleteKey(keyId: testKeyId)
        super.tearDown()
    }

    // MARK: - X25519 Key Tests

    func testGenerateAndRetrieveX25519Key() throws {
        let (privateKey, publicKey) = try keyStore.generateProtectedX25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false  // Don't require biometric for tests
        )

        // Verify keys were generated
        XCTAssertEqual(privateKey.rawRepresentation.count, 32)
        XCTAssertEqual(publicKey.rawRepresentation.count, 32)

        // Retrieve and verify
        let retrievedKey = try keyStore.retrieveX25519PrivateKey(keyId: testKeyId)
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.rawRepresentation, privateKey.rawRepresentation)
    }

    func testRetrieveNonexistentKey() throws {
        let result = try keyStore.retrievePrivateKey(keyId: "nonexistent-key-12345")
        XCTAssertNil(result, "Should return nil for nonexistent key")
    }

    // MARK: - Ed25519 Key Tests

    func testGenerateAndRetrieveEd25519Key() throws {
        let (privateKey, publicKey) = try keyStore.generateProtectedEd25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        XCTAssertEqual(privateKey.rawRepresentation.count, 32)
        XCTAssertEqual(publicKey.rawRepresentation.count, 32)

        let retrievedKey = try keyStore.retrieveEd25519PrivateKey(keyId: testKeyId)
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.rawRepresentation, privateKey.rawRepresentation)
    }

    // MARK: - Key Deletion Tests

    func testDeleteKey() throws {
        // Generate a key
        _ = try keyStore.generateProtectedX25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        // Verify it exists
        let beforeDelete = try keyStore.retrievePrivateKey(keyId: testKeyId)
        XCTAssertNotNil(beforeDelete)

        // Delete it
        try keyStore.deleteKey(keyId: testKeyId)

        // Verify it's gone
        let afterDelete = try keyStore.retrievePrivateKey(keyId: testKeyId)
        XCTAssertNil(afterDelete)
    }

    func testDeleteNonexistentKeyDoesNotThrow() throws {
        // Should not throw when deleting a key that doesn't exist
        XCTAssertNoThrow(try keyStore.deleteKey(keyId: "nonexistent-key-delete-test"))
    }

    // MARK: - Key Replacement Tests

    func testOverwriteExistingKey() throws {
        // Generate first key
        let (firstKey, _) = try keyStore.generateProtectedX25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        // Generate second key with same ID (should replace)
        let (secondKey, _) = try keyStore.generateProtectedX25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        // Keys should be different
        XCTAssertNotEqual(firstKey.rawRepresentation, secondKey.rawRepresentation)

        // Retrieved key should be the second one
        let retrievedKey = try keyStore.retrieveX25519PrivateKey(keyId: testKeyId)
        XCTAssertEqual(retrievedKey?.rawRepresentation, secondKey.rawRepresentation)
    }

    // MARK: - Secure Enclave Tests

    func testSecureEnclaveAvailability() {
        // This test just verifies the check doesn't crash
        let isAvailable = SecureKeyStore.isSecureEnclaveAvailable
        // On simulator, this will likely be true (for access control creation)
        // On device, depends on hardware
        print("Secure Enclave available: \(isAvailable)")
    }

    // MARK: - Multiple Keys Tests

    func testMultipleKeysIndependent() throws {
        let keyId1 = "test-key-1-\(UUID().uuidString)"
        let keyId2 = "test-key-2-\(UUID().uuidString)"

        defer {
            try? keyStore.deleteKey(keyId: keyId1)
            try? keyStore.deleteKey(keyId: keyId2)
        }

        let (key1, _) = try keyStore.generateProtectedX25519KeyPair(keyId: keyId1, requireBiometric: false)
        let (key2, _) = try keyStore.generateProtectedX25519KeyPair(keyId: keyId2, requireBiometric: false)

        // Keys should be different
        XCTAssertNotEqual(key1.rawRepresentation, key2.rawRepresentation)

        // Each should retrieve correctly
        let retrieved1 = try keyStore.retrieveX25519PrivateKey(keyId: keyId1)
        let retrieved2 = try keyStore.retrieveX25519PrivateKey(keyId: keyId2)

        XCTAssertEqual(retrieved1?.rawRepresentation, key1.rawRepresentation)
        XCTAssertEqual(retrieved2?.rawRepresentation, key2.rawRepresentation)

        // Deleting one shouldn't affect the other
        try keyStore.deleteKey(keyId: keyId1)
        XCTAssertNil(try keyStore.retrievePrivateKey(keyId: keyId1))
        XCTAssertNotNil(try keyStore.retrievePrivateKey(keyId: keyId2))
    }

    // MARK: - Key Usage Tests

    func testStoredKeyCanPerformKeyAgreement() throws {
        // Generate and store a key
        let (storedKey, storedPublicKey) = try keyStore.generateProtectedX25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        // Generate a peer key
        let peerKey = Curve25519.KeyAgreement.PrivateKey()

        // Perform key agreement with stored key
        let sharedSecret1 = try storedKey.sharedSecretFromKeyAgreement(with: peerKey.publicKey)

        // Retrieve stored key and perform again
        let retrievedKey = try keyStore.retrieveX25519PrivateKey(keyId: testKeyId)!
        let sharedSecret2 = try retrievedKey.sharedSecretFromKeyAgreement(with: peerKey.publicKey)

        // Shared secrets should match
        XCTAssertEqual(
            sharedSecret1.withUnsafeBytes { Data($0) },
            sharedSecret2.withUnsafeBytes { Data($0) }
        )

        // Peer should get same shared secret
        let peerSharedSecret = try peerKey.sharedSecretFromKeyAgreement(with: storedPublicKey)
        XCTAssertEqual(
            sharedSecret1.withUnsafeBytes { Data($0) },
            peerSharedSecret.withUnsafeBytes { Data($0) }
        )
    }

    func testStoredKeyCanSign() throws {
        let (storedKey, storedPublicKey) = try keyStore.generateProtectedEd25519KeyPair(
            keyId: testKeyId,
            requireBiometric: false
        )

        let message = "Test message".data(using: .utf8)!

        // Sign with stored key
        let signature = try storedKey.signature(for: message)

        // Verify signature
        XCTAssertTrue(storedPublicKey.isValidSignature(signature, for: message))

        // Retrieve and sign again
        let retrievedKey = try keyStore.retrieveEd25519PrivateKey(keyId: testKeyId)!
        let signature2 = try retrievedKey.signature(for: message)

        // Both signatures should verify
        XCTAssertTrue(storedPublicKey.isValidSignature(signature2, for: message))
    }
}
