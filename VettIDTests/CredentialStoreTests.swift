import XCTest
@testable import VettID

final class CredentialStoreTests: XCTestCase {

    var credentialStore: CredentialStore!
    let testUserGuid = "test-user-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        credentialStore = CredentialStore()
    }

    override func tearDown() {
        // Clean up test credentials
        try? credentialStore.delete(userGuid: testUserGuid)
        super.tearDown()
    }

    // MARK: - Helper Methods

    func createTestCredential(userGuid: String? = nil) -> StoredCredential {
        return StoredCredential(
            userGuid: userGuid ?? testUserGuid,
            encryptedBlob: "dGVzdC1lbmNyeXB0ZWQtYmxvYg==",  // Base64 test data
            cekVersion: 1,
            ledgerAuthToken: StoredLAT(
                latId: "lat-123",
                token: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                version: 1
            ),
            transactionKeys: [
                StoredUTK(keyId: "utk-1", publicKey: "dGVzdC1wdWJsaWMta2V5LTE=", algorithm: "X25519", isUsed: false),
                StoredUTK(keyId: "utk-2", publicKey: "dGVzdC1wdWJsaWMta2V5LTI=", algorithm: "X25519", isUsed: false),
                StoredUTK(keyId: "utk-3", publicKey: "dGVzdC1wdWJsaWMta2V5LTM=", algorithm: "X25519", isUsed: true)
            ],
            createdAt: Date(),
            lastUsedAt: Date(),
            vaultStatus: "running"
        )
    }

    // MARK: - Store and Retrieve Tests

    func testStoreAndRetrieveCredential() throws {
        let credential = createTestCredential()

        try credentialStore.store(credential: credential)
        let retrieved = try credentialStore.retrieve(userGuid: testUserGuid)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.userGuid, credential.userGuid)
        XCTAssertEqual(retrieved?.encryptedBlob, credential.encryptedBlob)
        XCTAssertEqual(retrieved?.cekVersion, credential.cekVersion)
        XCTAssertEqual(retrieved?.vaultStatus, credential.vaultStatus)
    }

    func testRetrieveNonexistentCredential() throws {
        let result = try credentialStore.retrieve(userGuid: "nonexistent-user-12345")
        XCTAssertNil(result, "Should return nil for nonexistent credential")
    }

    func testRetrieveFirst() throws {
        let credential = createTestCredential()
        try credentialStore.store(credential: credential)

        let retrieved = try credentialStore.retrieveFirst()

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.userGuid, credential.userGuid)
    }

    // MARK: - Update Tests

    func testUpdateCredential() throws {
        let credential = createTestCredential()
        try credentialStore.store(credential: credential)

        // Create updated credential
        let updated = StoredCredential(
            userGuid: testUserGuid,
            encryptedBlob: "dXBkYXRlZC1ibG9i",
            cekVersion: 2,
            ledgerAuthToken: credential.ledgerAuthToken,
            transactionKeys: credential.transactionKeys,
            createdAt: credential.createdAt,
            lastUsedAt: Date(),
            vaultStatus: "stopped"
        )

        try credentialStore.update(credential: updated)

        let retrieved = try credentialStore.retrieve(userGuid: testUserGuid)
        XCTAssertEqual(retrieved?.encryptedBlob, "dXBkYXRlZC1ibG9i")
        XCTAssertEqual(retrieved?.cekVersion, 2)
        XCTAssertEqual(retrieved?.vaultStatus, "stopped")
    }

    func testUpdateCreatesIfNotExists() throws {
        let credential = createTestCredential()

        // Update should create if doesn't exist
        try credentialStore.update(credential: credential)

        let retrieved = try credentialStore.retrieve(userGuid: testUserGuid)
        XCTAssertNotNil(retrieved)
    }

    // MARK: - Delete Tests

    func testDeleteCredential() throws {
        let credential = createTestCredential()
        try credentialStore.store(credential: credential)

        // Verify it exists
        XCTAssertNotNil(try credentialStore.retrieve(userGuid: testUserGuid))

        // Delete it
        try credentialStore.delete(userGuid: testUserGuid)

        // Verify it's gone
        XCTAssertNil(try credentialStore.retrieve(userGuid: testUserGuid))
    }

    func testDeleteNonexistentCredentialDoesNotThrow() throws {
        XCTAssertNoThrow(try credentialStore.delete(userGuid: "nonexistent-12345"))
    }

    // MARK: - Has Stored Credential Tests

    func testHasStoredCredential() throws {
        XCTAssertFalse(credentialStore.hasStoredCredential(), "Should be false when empty")

        let credential = createTestCredential()
        try credentialStore.store(credential: credential)

        XCTAssertTrue(credentialStore.hasStoredCredential(), "Should be true after storing")

        try credentialStore.delete(userGuid: testUserGuid)
        XCTAssertFalse(credentialStore.hasStoredCredential(), "Should be false after deleting")
    }

    // MARK: - List User GUIDs Tests

    func testListUserGuids() throws {
        let guid1 = "test-user-1-\(UUID().uuidString)"
        let guid2 = "test-user-2-\(UUID().uuidString)"

        defer {
            try? credentialStore.delete(userGuid: guid1)
            try? credentialStore.delete(userGuid: guid2)
        }

        try credentialStore.store(credential: createTestCredential(userGuid: guid1))
        try credentialStore.store(credential: createTestCredential(userGuid: guid2))

        let guids = try credentialStore.listUserGuids()

        XCTAssertTrue(guids.contains(guid1))
        XCTAssertTrue(guids.contains(guid2))
    }

    // MARK: - Transaction Key Tests

    func testGetUnusedKey() {
        let credential = createTestCredential()

        let unusedKey = credential.getUnusedKey()

        XCTAssertNotNil(unusedKey)
        XCTAssertFalse(unusedKey!.isUsed)
        XCTAssertTrue(["utk-1", "utk-2"].contains(unusedKey!.keyId))
    }

    func testGetKeyById() {
        let credential = createTestCredential()

        let key = credential.getKey(byId: "utk-2")

        XCTAssertNotNil(key)
        XCTAssertEqual(key?.keyId, "utk-2")
    }

    func testGetKeyByIdNotFound() {
        let credential = createTestCredential()

        let key = credential.getKey(byId: "nonexistent")

        XCTAssertNil(key)
    }

    func testUnusedKeyCount() {
        let credential = createTestCredential()

        XCTAssertEqual(credential.unusedKeyCount, 2)  // utk-1 and utk-2 are unused
    }

    func testMarkingKeyUsed() {
        let credential = createTestCredential()

        let updated = credential.markingKeyUsed(keyId: "utk-1")

        XCTAssertEqual(updated.unusedKeyCount, 1)
        XCTAssertTrue(updated.getKey(byId: "utk-1")!.isUsed)
        XCTAssertFalse(updated.getKey(byId: "utk-2")!.isUsed)
    }

    // MARK: - LAT Tests

    func testLATMatches() {
        let storedLAT = StoredLAT(
            latId: "lat-123",
            token: "abcdef",
            version: 1
        )

        let matchingServerLAT = LedgerAuthToken(
            latId: "lat-123",
            token: "abcdef",
            version: 1
        )

        let differentServerLAT = LedgerAuthToken(
            latId: "lat-123",
            token: "different",
            version: 1
        )

        XCTAssertTrue(storedLAT.matches(matchingServerLAT))
        XCTAssertFalse(storedLAT.matches(differentServerLAT))
    }

    // MARK: - Update With Package Tests

    func testUpdatedWithPackage() {
        let credential = createTestCredential()

        let package = CredentialPackage(
            userGuid: testUserGuid,
            encryptedBlob: "bmV3LWJsb2I=",
            cekVersion: 2,
            ledgerAuthToken: LedgerAuthToken(latId: "lat-new", token: "newtoken", version: 2),
            transactionKeys: nil,
            newTransactionKeys: [
                TransactionKeyInfo(keyId: "utk-new", publicKey: "bmV3LWtleQ==", algorithm: "X25519")
            ]
        )

        let updated = credential.updatedWith(package: package, usedKeyId: "utk-1")

        XCTAssertEqual(updated.encryptedBlob, "bmV3LWJsb2I=")
        XCTAssertEqual(updated.cekVersion, 2)
        XCTAssertEqual(updated.ledgerAuthToken.latId, "lat-new")
        XCTAssertTrue(updated.getKey(byId: "utk-1")!.isUsed)
        XCTAssertNotNil(updated.getKey(byId: "utk-new"))
    }

    // MARK: - UTK Public Key Data Tests

    func testUTKPublicKeyData() {
        let utk = StoredUTK(
            keyId: "test",
            publicKey: "dGVzdC1rZXk=",  // "test-key" in base64
            algorithm: "X25519",
            isUsed: false
        )

        let keyData = utk.publicKeyData()

        XCTAssertNotNil(keyData)
        XCTAssertEqual(String(data: keyData!, encoding: .utf8), "test-key")
    }

    func testUTKPublicKeyDataInvalidBase64() {
        let utk = StoredUTK(
            keyId: "test",
            publicKey: "not-valid-base64-!!!",
            algorithm: "X25519",
            isUsed: false
        )

        let keyData = utk.publicKeyData()

        XCTAssertNil(keyData)
    }
}
