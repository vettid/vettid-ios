import XCTest
@testable import VettID

/// Tests for ProteanCredentialStore
final class ProteanCredentialStoreTests: XCTestCase {

    var store: ProteanCredentialStore!

    override func setUp() {
        super.setUp()
        store = ProteanCredentialStore()
        // Clean up any existing data
        try? store.delete()
    }

    override func tearDown() {
        // Clean up after tests
        try? store.delete()
        store = nil
        super.tearDown()
    }

    // MARK: - Storage Tests

    func testStoreAndRetrieveBlob() throws {
        // Given
        let testBlob = "Test Protean Credential Data".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: testBlob.count,
            userGuid: "test-user-guid"
        )

        // When
        try store.store(blob: testBlob, metadata: metadata)
        let retrievedBlob = try store.retrieveBlob()

        // Then
        XCTAssertNotNil(retrievedBlob)
        XCTAssertEqual(retrievedBlob, testBlob)
    }

    func testStoreAndRetrieveMetadata() throws {
        // Given
        let testBlob = "Test Data".data(using: .utf8)!
        let testDate = Date()
        let metadata = ProteanCredentialMetadata(
            version: 5,
            createdAt: testDate,
            updatedAt: nil,
            backedUpAt: nil,
            sizeBytes: testBlob.count,
            userGuid: "user-123"
        )

        // When
        try store.store(blob: testBlob, metadata: metadata)
        let retrievedMetadata = try store.retrieveMetadata()

        // Then
        XCTAssertNotNil(retrievedMetadata)
        XCTAssertEqual(retrievedMetadata?.version, 5)
        XCTAssertEqual(retrievedMetadata?.userGuid, "user-123")
        XCTAssertEqual(retrievedMetadata?.sizeBytes, testBlob.count)
    }

    func testHasCredential() throws {
        // Given - no credential stored
        XCTAssertFalse(store.hasCredential())

        // When - store a credential
        let testBlob = "Test".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: testBlob.count,
            userGuid: "test"
        )
        try store.store(blob: testBlob, metadata: metadata)

        // Then
        XCTAssertTrue(store.hasCredential())
    }

    func testRetrieveBlobWhenEmpty() throws {
        // When
        let blob = try store.retrieveBlob()

        // Then
        XCTAssertNil(blob)
    }

    func testRetrieveMetadataWhenEmpty() throws {
        // When
        let metadata = try store.retrieveMetadata()

        // Then
        XCTAssertNil(metadata)
    }

    // MARK: - Update Tests

    func testUpdateCredential() throws {
        // Given - store initial credential
        let initialBlob = "Initial".data(using: .utf8)!
        let initialMetadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: initialBlob.count,
            userGuid: "user-1"
        )
        try store.store(blob: initialBlob, metadata: initialMetadata)

        // When - update with new blob and version
        let updatedBlob = "Updated Credential".data(using: .utf8)!
        try store.updateCredential(blob: updatedBlob, newVersion: 2)

        // Then
        let retrievedBlob = try store.retrieveBlob()
        let retrievedMetadata = try store.retrieveMetadata()

        XCTAssertEqual(retrievedBlob, updatedBlob)
        XCTAssertEqual(retrievedMetadata?.version, 2)
        XCTAssertNotNil(retrievedMetadata?.updatedAt)
        XCTAssertNil(retrievedMetadata?.backedUpAt) // Should be cleared after update
    }

    func testUpdateCredentialWithNoCredentialStored() {
        // Given - no credential stored
        let newBlob = "New".data(using: .utf8)!

        // When/Then
        XCTAssertThrowsError(try store.updateCredential(blob: newBlob, newVersion: 2)) { error in
            XCTAssertTrue(error is ProteanCredentialStoreError)
        }
    }

    // MARK: - Backup Status Tests

    func testMarkAsBackedUp() throws {
        // Given - store a credential
        let blob = "Test".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: blob.count,
            userGuid: "user"
        )
        try store.store(blob: blob, metadata: metadata)

        // When
        try store.markAsBackedUp(backupId: "backup-123")

        // Then
        let retrievedMetadata = try store.retrieveMetadata()
        XCTAssertNotNil(retrievedMetadata?.backedUpAt)
        XCTAssertEqual(retrievedMetadata?.backupId, "backup-123")
    }

    func testNeedsBackupWhenNotBackedUp() throws {
        // Given - store a credential without backup
        let blob = "Test".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: blob.count,
            userGuid: "user"
        )
        try store.store(blob: blob, metadata: metadata)

        // Then
        XCTAssertTrue(store.needsBackup())
    }

    func testNeedsBackupWhenBackedUp() throws {
        // Given - store and backup a credential
        let blob = "Test".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: blob.count,
            userGuid: "user"
        )
        try store.store(blob: blob, metadata: metadata)
        try store.markAsBackedUp(backupId: "backup-123")

        // Then
        XCTAssertFalse(store.needsBackup())
    }

    func testNeedsBackupWhenNoCredential() {
        // Given - no credential
        // Then
        XCTAssertFalse(store.needsBackup())
    }

    // MARK: - Delete Tests

    func testDelete() throws {
        // Given - store a credential
        let blob = "Test".data(using: .utf8)!
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: blob.count,
            userGuid: "user"
        )
        try store.store(blob: blob, metadata: metadata)
        XCTAssertTrue(store.hasCredential())

        // When
        try store.delete()

        // Then
        XCTAssertFalse(store.hasCredential())
        XCTAssertNil(try store.retrieveBlob())
        XCTAssertNil(try store.retrieveMetadata())
    }

    func testDeleteWhenEmpty() throws {
        // Given - no credential
        XCTAssertFalse(store.hasCredential())

        // When/Then - should not throw
        XCTAssertNoThrow(try store.delete())
    }

    // MARK: - Overwrite Tests

    func testOverwriteExistingCredential() throws {
        // Given - store initial credential
        let blob1 = "First".data(using: .utf8)!
        let metadata1 = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: blob1.count,
            userGuid: "user-1"
        )
        try store.store(blob: blob1, metadata: metadata1)

        // When - store new credential
        let blob2 = "Second".data(using: .utf8)!
        let metadata2 = ProteanCredentialMetadata(
            version: 2,
            createdAt: Date(),
            sizeBytes: blob2.count,
            userGuid: "user-2"
        )
        try store.store(blob: blob2, metadata: metadata2)

        // Then - new credential should replace old one
        let retrievedBlob = try store.retrieveBlob()
        let retrievedMetadata = try store.retrieveMetadata()

        XCTAssertEqual(retrievedBlob, blob2)
        XCTAssertEqual(retrievedMetadata?.version, 2)
        XCTAssertEqual(retrievedMetadata?.userGuid, "user-2")
    }

    // MARK: - Large Data Tests

    func testStoreLargeBlob() throws {
        // Given - large blob (1MB)
        let largeBlob = Data(repeating: 0xAB, count: 1024 * 1024)
        let metadata = ProteanCredentialMetadata(
            version: 1,
            createdAt: Date(),
            sizeBytes: largeBlob.count,
            userGuid: "user"
        )

        // When
        try store.store(blob: largeBlob, metadata: metadata)
        let retrievedBlob = try store.retrieveBlob()

        // Then
        XCTAssertEqual(retrievedBlob, largeBlob)
        XCTAssertEqual(retrievedBlob?.count, 1024 * 1024)
    }
}

// MARK: - Metadata Tests

extension ProteanCredentialStoreTests {

    func testMetadataCodable() throws {
        // Given
        let original = ProteanCredentialMetadata(
            version: 3,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            updatedAt: Date(timeIntervalSince1970: 1700001000),
            backedUpAt: Date(timeIntervalSince1970: 1700002000),
            backupId: "backup-abc",
            sizeBytes: 12345,
            userGuid: "user-guid-123"
        )

        // When
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProteanCredentialMetadata.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.sizeBytes, original.sizeBytes)
        XCTAssertEqual(decoded.userGuid, original.userGuid)
        XCTAssertEqual(decoded.backupId, original.backupId)
    }
}
