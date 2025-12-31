import XCTest
@testable import VettID

/// Unit tests for CredentialsHandler
final class CredentialsHandlerTests: XCTestCase {

    // MARK: - TransactionKeyInfo Tests

    func testTransactionKeyInfo_initialization() {
        let keyInfo = TransactionKeyInfo(
            keyId: "utk-12345",
            publicKey: "base64EncodedPublicKey==",
            algorithm: "X25519"
        )

        XCTAssertEqual(keyInfo.keyId, "utk-12345")
        XCTAssertEqual(keyInfo.publicKey, "base64EncodedPublicKey==")
        XCTAssertEqual(keyInfo.algorithm, "X25519")
    }

    func testTransactionKeyInfo_codable() throws {
        let keyInfo = TransactionKeyInfo(
            keyId: "key-abc",
            publicKey: "publicKeyData",
            algorithm: "Ed25519"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(keyInfo)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TransactionKeyInfo.self, from: data)

        XCTAssertEqual(decoded.keyId, keyInfo.keyId)
        XCTAssertEqual(decoded.publicKey, keyInfo.publicKey)
        XCTAssertEqual(decoded.algorithm, keyInfo.algorithm)
    }

    func testTransactionKeyInfo_jsonDecoding() throws {
        let json = """
        {
            "keyId": "utk-test-123",
            "publicKey": "SGVsbG9Xb3JsZA==",
            "algorithm": "X25519"
        }
        """

        let decoder = JSONDecoder()
        let keyInfo = try decoder.decode(TransactionKeyInfo.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(keyInfo.keyId, "utk-test-123")
        XCTAssertEqual(keyInfo.publicKey, "SGVsbG9Xb3JsZA==")
        XCTAssertEqual(keyInfo.algorithm, "X25519")
    }

    // MARK: - CredentialRefreshResult Tests

    func testCredentialRefreshResult_fullInitialization() {
        let utks = [
            TransactionKeyInfo(keyId: "k1", publicKey: "pk1", algorithm: "X25519"),
            TransactionKeyInfo(keyId: "k2", publicKey: "pk2", algorithm: "X25519")
        ]

        let result = CredentialRefreshResult(
            encryptedBlob: "encrypted-data",
            cekVersion: 5,
            latToken: "lat-token-abc",
            latVersion: 3,
            latId: "lat-id-123",
            transactionKeys: utks
        )

        XCTAssertEqual(result.encryptedBlob, "encrypted-data")
        XCTAssertEqual(result.cekVersion, 5)
        XCTAssertEqual(result.latToken, "lat-token-abc")
        XCTAssertEqual(result.latVersion, 3)
        XCTAssertEqual(result.latId, "lat-id-123")
        XCTAssertEqual(result.transactionKeys?.count, 2)
    }

    func testCredentialRefreshResult_minimalInitialization() {
        let result = CredentialRefreshResult(
            encryptedBlob: "blob",
            cekVersion: 1,
            latToken: nil,
            latVersion: nil,
            latId: nil,
            transactionKeys: nil
        )

        XCTAssertEqual(result.encryptedBlob, "blob")
        XCTAssertEqual(result.cekVersion, 1)
        XCTAssertNil(result.latToken)
        XCTAssertNil(result.latVersion)
        XCTAssertNil(result.latId)
        XCTAssertNil(result.transactionKeys)
    }

    // MARK: - CredentialStatusInfo Tests

    func testCredentialStatusInfo_validCredentials() {
        let expiryDate = Date().addingTimeInterval(86400) // 1 day from now
        let status = CredentialStatusInfo(
            isValid: true,
            latVersion: 5,
            cekVersion: 3,
            utkCount: 10,
            expiresAt: expiryDate,
            needsRotation: false
        )

        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.latVersion, 5)
        XCTAssertEqual(status.cekVersion, 3)
        XCTAssertEqual(status.utkCount, 10)
        XCTAssertNotNil(status.expiresAt)
        XCTAssertFalse(status.needsRotation)
    }

    func testCredentialStatusInfo_needsRotation() {
        let status = CredentialStatusInfo(
            isValid: true,
            latVersion: 1,
            cekVersion: 1,
            utkCount: 2,
            expiresAt: nil,
            needsRotation: true
        )

        XCTAssertTrue(status.isValid)
        XCTAssertTrue(status.needsRotation)
        XCTAssertEqual(status.utkCount, 2) // Low UTK count
    }

    func testCredentialStatusInfo_invalidCredentials() {
        let status = CredentialStatusInfo(
            isValid: false,
            latVersion: nil,
            cekVersion: nil,
            utkCount: 0,
            expiresAt: nil,
            needsRotation: true
        )

        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.latVersion)
        XCTAssertNil(status.cekVersion)
        XCTAssertEqual(status.utkCount, 0)
        XCTAssertTrue(status.needsRotation)
    }

    // MARK: - CredentialStoreRequest Tests

    func testCredentialStoreRequest_initialization() {
        let request = CredentialStoreRequest(
            encryptedBlob: "encrypted-blob-data",
            cekVersion: 7,
            latToken: "new-lat-token",
            latVersion: 4
        )

        XCTAssertEqual(request.encryptedBlob, "encrypted-blob-data")
        XCTAssertEqual(request.cekVersion, 7)
        XCTAssertEqual(request.latToken, "new-lat-token")
        XCTAssertEqual(request.latVersion, 4)
    }

    // MARK: - CredentialSyncResult Tests

    func testCredentialSyncResult_inSync() {
        let result = CredentialSyncResult(
            inSync: true,
            updatedCredentials: nil,
            newUtks: nil
        )

        XCTAssertTrue(result.inSync)
        XCTAssertNil(result.updatedCredentials)
        XCTAssertNil(result.newUtks)
    }

    func testCredentialSyncResult_outOfSyncWithUpdates() {
        let creds = CredentialRefreshResult(
            encryptedBlob: "new-blob",
            cekVersion: 8,
            latToken: "new-lat",
            latVersion: 5,
            latId: "new-lat-id",
            transactionKeys: nil
        )

        let utks = [
            TransactionKeyInfo(keyId: "new-utk-1", publicKey: "pk", algorithm: "X25519")
        ]

        let result = CredentialSyncResult(
            inSync: false,
            updatedCredentials: creds,
            newUtks: utks
        )

        XCTAssertFalse(result.inSync)
        XCTAssertNotNil(result.updatedCredentials)
        XCTAssertEqual(result.updatedCredentials?.cekVersion, 8)
        XCTAssertNotNil(result.newUtks)
        XCTAssertEqual(result.newUtks?.count, 1)
    }

    // MARK: - CredentialsHandlerError Tests

    func testCredentialsHandlerError_refreshFailedDescription() {
        let error = CredentialsHandlerError.refreshFailed("Session expired")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("refresh"))
        XCTAssertTrue(error.errorDescription!.contains("Session expired"))
    }

    func testCredentialsHandlerError_statusCheckFailedDescription() {
        let error = CredentialsHandlerError.statusCheckFailed("Vault unavailable")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("status"))
        XCTAssertTrue(error.errorDescription!.contains("Vault unavailable"))
    }

    func testCredentialsHandlerError_syncFailedDescription() {
        let error = CredentialsHandlerError.syncFailed("Conflict detected")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("sync"))
        XCTAssertTrue(error.errorDescription!.contains("Conflict detected"))
    }

    func testCredentialsHandlerError_utkRequestFailedDescription() {
        let error = CredentialsHandlerError.utkRequestFailed("Rate limited")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("utk"))
        XCTAssertTrue(error.errorDescription!.contains("Rate limited"))
    }

    func testCredentialsHandlerError_invalidResponseDescription() {
        let error = CredentialsHandlerError.invalidResponse

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testCredentialsHandlerError_switchCoverage() {
        let errors: [CredentialsHandlerError] = [
            .refreshFailed("test"),
            .statusCheckFailed("test"),
            .syncFailed("test"),
            .utkRequestFailed("test"),
            .invalidResponse
        ]

        for error in errors {
            switch error {
            case .refreshFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .statusCheckFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .syncFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .utkRequestFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .invalidResponse:
                XCTAssertTrue(true)
            }
        }
    }

    // MARK: - UTK Pool Management Tests

    func testUtkPoolCount_threshold() {
        // Test the typical UTK threshold of 5
        let lowUtkThreshold = 5

        let lowCount = CredentialStatusInfo(
            isValid: true,
            latVersion: 1,
            cekVersion: 1,
            utkCount: 3,
            expiresAt: nil,
            needsRotation: false
        )

        let healthyCount = CredentialStatusInfo(
            isValid: true,
            latVersion: 1,
            cekVersion: 1,
            utkCount: 10,
            expiresAt: nil,
            needsRotation: false
        )

        XCTAssertTrue(lowCount.utkCount < lowUtkThreshold)
        XCTAssertFalse(healthyCount.utkCount < lowUtkThreshold)
    }

    // MARK: - Version Tracking Tests

    func testVersionTracking_incrementing() {
        var latVersion = 1
        var cekVersion = 1

        // Simulate version increments
        latVersion += 1
        XCTAssertEqual(latVersion, 2)

        cekVersion += 1
        XCTAssertEqual(cekVersion, 2)
    }
}
