import XCTest
@testable import VettID

/// Unit tests for SecretsHandler
final class SecretsHandlerTests: XCTestCase {

    // MARK: - SecretMetadata Tests

    func testSecretMetadata_initialization() {
        let metadata = SecretMetadata(
            key: "test-key",
            label: "Test Secret",
            category: "passwords",
            tags: ["personal", "important"],
            createdAt: Date(),
            updatedAt: Date()
        )

        XCTAssertEqual(metadata.key, "test-key")
        XCTAssertEqual(metadata.label, "Test Secret")
        XCTAssertEqual(metadata.category, "passwords")
        XCTAssertEqual(metadata.tags, ["personal", "important"])
        XCTAssertNotNil(metadata.createdAt)
        XCTAssertNotNil(metadata.updatedAt)
    }

    func testSecretMetadata_initializationWithDefaults() {
        let metadata = SecretMetadata()

        XCTAssertNil(metadata.key)
        XCTAssertNil(metadata.label)
        XCTAssertNil(metadata.category)
        XCTAssertNil(metadata.tags)
        XCTAssertNil(metadata.createdAt)
        XCTAssertNil(metadata.updatedAt)
    }

    func testSecretMetadata_equatable() {
        let metadata1 = SecretMetadata(key: "key1", label: "Label", category: "cat")
        let metadata2 = SecretMetadata(key: "key1", label: "Label", category: "cat")
        let metadata3 = SecretMetadata(key: "key2", label: "Label", category: "cat")

        XCTAssertEqual(metadata1, metadata2)
        XCTAssertNotEqual(metadata1, metadata3)
    }

    func testSecretMetadata_codable() throws {
        let metadata = SecretMetadata(
            key: "test-key",
            label: "Test",
            category: "general",
            tags: ["tag1", "tag2"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SecretMetadata.self, from: data)

        XCTAssertEqual(decoded.key, metadata.key)
        XCTAssertEqual(decoded.label, metadata.label)
        XCTAssertEqual(decoded.category, metadata.category)
        XCTAssertEqual(decoded.tags, metadata.tags)
    }

    // MARK: - SecretData Tests

    func testSecretData_initialization() {
        let value = "secret-value".data(using: .utf8)!
        let metadata = SecretMetadata(label: "Test")
        let secretData = SecretData(key: "my-key", value: value, metadata: metadata)

        XCTAssertEqual(secretData.key, "my-key")
        XCTAssertEqual(secretData.value, value)
        XCTAssertEqual(secretData.metadata.label, "Test")
    }

    func testSecretData_equatable() {
        let value = "secret".data(using: .utf8)!
        let metadata = SecretMetadata(label: "Test")

        let secret1 = SecretData(key: "key1", value: value, metadata: metadata)
        let secret2 = SecretData(key: "key1", value: value, metadata: metadata)
        let secret3 = SecretData(key: "key2", value: value, metadata: metadata)

        XCTAssertEqual(secret1, secret2)
        XCTAssertNotEqual(secret1, secret3)
    }

    // MARK: - SecretFilter Tests

    func testSecretFilter_initializationEmpty() {
        let filter = SecretFilter()

        XCTAssertNil(filter.category)
        XCTAssertNil(filter.tags)
        XCTAssertNil(filter.limit)
        XCTAssertNil(filter.offset)
    }

    func testSecretFilter_initializationWithValues() {
        let filter = SecretFilter(
            category: "passwords",
            tags: ["work", "important"],
            limit: 10,
            offset: 5
        )

        XCTAssertEqual(filter.category, "passwords")
        XCTAssertEqual(filter.tags, ["work", "important"])
        XCTAssertEqual(filter.limit, 10)
        XCTAssertEqual(filter.offset, 5)
    }

    func testSecretFilter_categoryOnly() {
        let filter = SecretFilter(category: "api-keys")

        XCTAssertEqual(filter.category, "api-keys")
        XCTAssertNil(filter.tags)
        XCTAssertNil(filter.limit)
        XCTAssertNil(filter.offset)
    }

    func testSecretFilter_paginationOnly() {
        let filter = SecretFilter(limit: 20, offset: 40)

        XCTAssertNil(filter.category)
        XCTAssertNil(filter.tags)
        XCTAssertEqual(filter.limit, 20)
        XCTAssertEqual(filter.offset, 40)
    }

    // MARK: - SecretsHandlerError Tests

    func testSecretsHandlerError_retrievalFailedDescription() {
        let error = SecretsHandlerError.retrievalFailed("Network timeout")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("retrieve"))
        XCTAssertTrue(error.errorDescription!.contains("Network timeout"))
    }

    func testSecretsHandlerError_listFailedDescription() {
        let error = SecretsHandlerError.listFailed("Permission denied")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("list"))
        XCTAssertTrue(error.errorDescription!.contains("Permission denied"))
    }

    func testSecretsHandlerError_invalidResponseDescription() {
        let error = SecretsHandlerError.invalidResponse

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testSecretsHandlerError_secretNotFoundDescription() {
        let error = SecretsHandlerError.secretNotFound

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not found"))
    }

    // MARK: - Error Equality via Switch

    func testSecretsHandlerError_switchCoverage() {
        let errors: [SecretsHandlerError] = [
            .retrievalFailed("test"),
            .listFailed("test"),
            .invalidResponse,
            .secretNotFound
        ]

        for error in errors {
            switch error {
            case .retrievalFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .listFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .invalidResponse:
                XCTAssertTrue(true)
            case .secretNotFound:
                XCTAssertTrue(true)
            }
        }
    }

    // MARK: - Base64 Encoding Tests

    func testSecretValue_base64Encoding() {
        let originalValue = "my-super-secret-password-123!@#"
        let data = originalValue.data(using: .utf8)!
        let base64 = data.base64EncodedString()

        XCTAssertFalse(base64.contains(originalValue))

        let decodedData = Data(base64Encoded: base64)
        XCTAssertNotNil(decodedData)

        let decodedString = String(data: decodedData!, encoding: .utf8)
        XCTAssertEqual(decodedString, originalValue)
    }

    func testSecretValue_binaryData() {
        // Test with binary data (not just strings)
        var bytes: [UInt8] = [0x00, 0x01, 0xFF, 0xFE, 0x7F, 0x80]
        let binaryData = Data(bytes)
        let base64 = binaryData.base64EncodedString()

        let decoded = Data(base64Encoded: base64)
        XCTAssertEqual(decoded, binaryData)
    }
}
