import XCTest
@testable import VettID

/// Tests for ExpectedPCRStore
final class ExpectedPCRStoreTests: XCTestCase {

    var store: ExpectedPCRStore!

    override func setUp() {
        super.setUp()
        store = ExpectedPCRStore()
        // Clear any stored PCR sets
        store.clearStoredPCRSets()
    }

    override func tearDown() {
        store.clearStoredPCRSets()
        store = nil
        super.tearDown()
    }

    // MARK: - PCRSet Tests

    func testPCRSetIsValid() {
        // Given - valid PCR set
        let validSet = ExpectedPCRStore.PCRSet(
            id: "test-1",
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: Date().addingTimeInterval(3600),
            isCurrent: true
        )

        // Then
        XCTAssertTrue(validSet.isValid)
    }

    func testPCRSetNotYetValid() {
        // Given - future PCR set
        let futureSet = ExpectedPCRStore.PCRSet(
            id: "test-1",
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(3600),
            validUntil: nil,
            isCurrent: false
        )

        // Then
        XCTAssertFalse(futureSet.isValid)
    }

    func testPCRSetExpired() {
        // Given - expired PCR set
        let expiredSet = ExpectedPCRStore.PCRSet(
            id: "test-1",
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-7200),
            validUntil: Date().addingTimeInterval(-3600),
            isCurrent: false
        )

        // Then
        XCTAssertFalse(expiredSet.isValid)
    }

    func testPCRSetNoExpiration() {
        // Given - PCR set with no expiration
        let noExpirationSet = ExpectedPCRStore.PCRSet(
            id: "test-1",
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil,
            isCurrent: true
        )

        // Then
        XCTAssertTrue(noExpirationSet.isValid)
    }

    func testPCRSetToExpectedPCRs() {
        // Given
        let pcrSet = ExpectedPCRStore.PCRSet(
            id: "test-1",
            pcr0: "pcr0-value",
            pcr1: "pcr1-value",
            pcr2: "pcr2-value",
            validFrom: Date(),
            validUntil: nil,
            isCurrent: true
        )

        // When
        let expectedPCRs = pcrSet.toExpectedPCRs()

        // Then
        XCTAssertEqual(expectedPCRs.pcr0, "pcr0-value")
        XCTAssertEqual(expectedPCRs.pcr1, "pcr1-value")
        XCTAssertEqual(expectedPCRs.pcr2, "pcr2-value")
    }

    func testPCRSetCodable() throws {
        // Given
        let original = ExpectedPCRStore.PCRSet(
            id: "test-id",
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date(timeIntervalSince1970: 1700000000),
            validUntil: Date(timeIntervalSince1970: 1700086400),
            isCurrent: true
        )

        // When
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExpectedPCRStore.PCRSet.self, from: data)

        // Then
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.pcr0, original.pcr0)
        XCTAssertEqual(decoded.pcr1, original.pcr1)
        XCTAssertEqual(decoded.pcr2, original.pcr2)
        XCTAssertEqual(decoded.isCurrent, original.isCurrent)
    }

    // MARK: - Store Functionality Tests

    func testGetValidPCRSetsReturnsBundled() {
        // Given - fresh store with no updates
        store.clearStoredPCRSets()

        // When
        let validSets = store.getValidPCRSets()

        // Then - should return bundled/placeholder sets
        XCTAssertFalse(validSets.isEmpty, "Should have at least bundled PCR sets")
    }

    func testGetCurrentPCRSet() {
        // When
        let currentSet = store.getCurrentPCRSet()

        // Then - should have a current set (bundled or stored)
        XCTAssertNotNil(currentSet)
    }

    func testHasMatchingPCRSet() {
        // Given - get current PCR set
        guard let current = store.getCurrentPCRSet() else {
            XCTFail("No current PCR set available")
            return
        }

        // When/Then
        XCTAssertTrue(store.hasMatchingPCRSet(
            pcr0: current.pcr0,
            pcr1: current.pcr1,
            pcr2: current.pcr2
        ))

        // Non-matching
        XCTAssertFalse(store.hasMatchingPCRSet(
            pcr0: "nonexistent",
            pcr1: "nonexistent",
            pcr2: "nonexistent"
        ))
    }

    func testFindMatchingPCRSet() {
        // Given
        guard let current = store.getCurrentPCRSet() else {
            XCTFail("No current PCR set available")
            return
        }

        // When
        let found = store.findMatchingPCRSet(
            pcr0: current.pcr0,
            pcr1: current.pcr1,
            pcr2: current.pcr2
        )

        // Then
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, current.id)
    }

    func testFindMatchingPCRSetNotFound() {
        // When
        let found = store.findMatchingPCRSet(
            pcr0: "nonexistent",
            pcr1: "nonexistent",
            pcr2: "nonexistent"
        )

        // Then
        XCTAssertNil(found)
    }

    func testClearStoredPCRSets() {
        // Given
        let initialSets = store.getValidPCRSets()

        // When
        store.clearStoredPCRSets()

        // Then - should still have bundled sets
        let clearedSets = store.getValidPCRSets()
        XCTAssertFalse(clearedSets.isEmpty)
    }

    func testGetLastUpdateTimestamp() {
        // Given - fresh store
        store.clearStoredPCRSets()

        // When
        let timestamp = store.getLastUpdateTimestamp()

        // Then - should be nil since no updates stored
        XCTAssertNil(timestamp)
    }

    // MARK: - Bundled Defaults Tests

    func testIsUsingBundledDefaultsAfterClear() {
        // Given - clear stored PCR sets
        store.clearStoredPCRSets()

        // When/Then - should be using bundled defaults
        XCTAssertTrue(store.isUsingBundledDefaults())
    }

    func testIsUsingDevelopmentPlaceholder() {
        // Given - clear stored PCR sets to fall back to bundled
        store.clearStoredPCRSets()

        // When
        let isPlaceholder = store.isUsingDevelopmentPlaceholder

        // Then - development placeholder should be detected
        // (This will be true in tests since there's no expected_pcrs.json bundled)
        // The actual behavior depends on whether bundled PCRs exist
        if let currentSet = store.getCurrentPCRSet() {
            if currentSet.id == "development-placeholder" {
                XCTAssertTrue(isPlaceholder)
            } else {
                XCTAssertFalse(isPlaceholder)
            }
        }
    }

    // MARK: - Case Insensitivity Tests

    func testHasMatchingPCRSetCaseInsensitive() {
        // Given
        guard let current = store.getCurrentPCRSet() else {
            XCTFail("No current PCR set available")
            return
        }

        // When/Then - uppercase should match
        XCTAssertTrue(store.hasMatchingPCRSet(
            pcr0: current.pcr0.uppercased(),
            pcr1: current.pcr1.uppercased(),
            pcr2: current.pcr2.uppercased()
        ))

        // Mixed case should match
        let mixedCase0 = current.pcr0.enumerated().map { $0.offset % 2 == 0 ? $0.element.uppercased() : $0.element.lowercased() }.joined()
        let mixedCase1 = current.pcr1.enumerated().map { $0.offset % 2 == 0 ? $0.element.uppercased() : $0.element.lowercased() }.joined()
        let mixedCase2 = current.pcr2.enumerated().map { $0.offset % 2 == 0 ? $0.element.uppercased() : $0.element.lowercased() }.joined()

        XCTAssertTrue(store.hasMatchingPCRSet(
            pcr0: mixedCase0,
            pcr1: mixedCase1,
            pcr2: mixedCase2
        ))
    }

    // MARK: - PCR Store Error Tests

    func testPCRStoreErrorDescriptions() {
        let errors: [PCRStoreError] = [
            .signingKeyNotAvailable,
            .invalidSignature,
            .signatureVerificationFailed,
            .downgradeAttempt,
            .storageFailed(-25299),
            .noPCRSetsAvailable
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testStorageFailedErrorContainsStatus() {
        let error = PCRStoreError.storageFailed(-25299)
        XCTAssertTrue(error.errorDescription!.contains("-25299"))
    }
}

// MARK: - PCRUpdateResponse Tests

extension ExpectedPCRStoreTests {

    func testPCRUpdateResponseCodable() throws {
        // Given
        let pcrSets = [
            ExpectedPCRStore.PCRSet(
                id: "test-1",
                pcr0: String(repeating: "a", count: 96),
                pcr1: String(repeating: "b", count: 96),
                pcr2: String(repeating: "c", count: 96),
                validFrom: Date(timeIntervalSince1970: 1700000000),
                validUntil: nil,
                isCurrent: true
            )
        ]

        let response = ExpectedPCRStore.PCRUpdateResponse(
            pcrSets: pcrSets,
            signature: "base64signature==",
            signedAt: Date(timeIntervalSince1970: 1700000000),
            signedPayload: nil
        )

        // When
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExpectedPCRStore.PCRUpdateResponse.self, from: data)

        // Then
        XCTAssertEqual(decoded.pcrSets.count, 1)
        XCTAssertEqual(decoded.signature, "base64signature==")
        XCTAssertEqual(decoded.pcrSets[0].id, "test-1")
    }
}
