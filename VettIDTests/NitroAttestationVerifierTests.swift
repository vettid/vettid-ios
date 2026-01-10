import XCTest
@testable import VettID

/// Tests for NitroAttestationVerifier
final class NitroAttestationVerifierTests: XCTestCase {

    var verifier: NitroAttestationVerifier!

    override func setUp() {
        super.setUp()
        verifier = NitroAttestationVerifier()
    }

    override func tearDown() {
        verifier = nil
        super.tearDown()
    }

    // MARK: - ExpectedPCRs Tests

    func testExpectedPCRsValidity() {
        // Given - valid PCR set (current time is between validFrom and validUntil)
        let validPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),  // 1 hour ago
            validUntil: Date().addingTimeInterval(3600)   // 1 hour from now
        )

        // Then
        XCTAssertTrue(validPCRs.isValid)
    }

    func testExpectedPCRsNotYetValid() {
        // Given - PCR set not yet valid
        let futurePCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(3600),  // 1 hour from now
            validUntil: nil
        )

        // Then
        XCTAssertFalse(futurePCRs.isValid)
    }

    func testExpectedPCRsExpired() {
        // Given - expired PCR set
        let expiredPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-7200),  // 2 hours ago
            validUntil: Date().addingTimeInterval(-3600)  // 1 hour ago
        )

        // Then
        XCTAssertFalse(expiredPCRs.isValid)
    }

    func testExpectedPCRsNoExpiration() {
        // Given - PCR set with no expiration
        let noExpirationPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),  // 1 hour ago
            validUntil: nil
        )

        // Then
        XCTAssertTrue(noExpirationPCRs.isValid)
    }

    // MARK: - PCR Verification Tests

    func testVerifyPCRsSuccess() throws {
        // Given
        let pcr0 = String(repeating: "a", count: 96)
        let pcr1 = String(repeating: "b", count: 96)
        let pcr2 = String(repeating: "c", count: 96)

        let expected = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: pcr0,
            pcr1: pcr1,
            pcr2: pcr2,
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        let actual: [Int: Data] = [
            0: Data(hexString: pcr0)!,
            1: Data(hexString: pcr1)!,
            2: Data(hexString: pcr2)!
        ]

        // When/Then - should not throw
        XCTAssertNoThrow(try verifier.verifyPCRs(actual, expected: expected))
    }

    func testVerifyPCRsMismatch() {
        // Given
        let expected = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        let actual: [Int: Data] = [
            0: Data(hexString: String(repeating: "a", count: 96))!,
            1: Data(hexString: String(repeating: "b", count: 96))!,
            2: Data(hexString: String(repeating: "d", count: 96))!  // Different!
        ]

        // When/Then
        XCTAssertThrowsError(try verifier.verifyPCRs(actual, expected: expected)) { error in
            guard case NitroAttestationError.pcrMismatch(let pcr, _, _) = error else {
                XCTFail("Expected pcrMismatch error")
                return
            }
            XCTAssertEqual(pcr, 2)
        }
    }

    func testVerifyPCRsMissingValues() {
        // Given
        let expected = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        let actual: [Int: Data] = [
            0: Data(hexString: String(repeating: "a", count: 96))!,
            // Missing PCR1 and PCR2
        ]

        // When/Then
        XCTAssertThrowsError(try verifier.verifyPCRs(actual, expected: expected)) { error in
            guard case NitroAttestationError.missingPCRValues = error else {
                XCTFail("Expected missingPCRValues error")
                return
            }
        }
    }

    func testVerifyPCRsExpiredSet() {
        // Given - expired PCR set
        let expired = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "a", count: 96),
            pcr1: String(repeating: "b", count: 96),
            pcr2: String(repeating: "c", count: 96),
            validFrom: Date().addingTimeInterval(-7200),
            validUntil: Date().addingTimeInterval(-3600)
        )

        let actual: [Int: Data] = [
            0: Data(hexString: String(repeating: "a", count: 96))!,
            1: Data(hexString: String(repeating: "b", count: 96))!,
            2: Data(hexString: String(repeating: "c", count: 96))!
        ]

        // When/Then
        XCTAssertThrowsError(try verifier.verifyPCRs(actual, expected: expired)) { error in
            guard case NitroAttestationError.pcrSetExpired = error else {
                XCTFail("Expected pcrSetExpired error")
                return
            }
        }
    }

    func testVerifyPCRsCaseInsensitive() throws {
        // Given - uppercase vs lowercase hex
        let expected = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "A", count: 96).lowercased(),
            pcr1: String(repeating: "B", count: 96).lowercased(),
            pcr2: String(repeating: "C", count: 96).lowercased(),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        let actual: [Int: Data] = [
            0: Data(hexString: String(repeating: "a", count: 96))!,
            1: Data(hexString: String(repeating: "b", count: 96))!,
            2: Data(hexString: String(repeating: "c", count: 96))!
        ]

        // When/Then - should match despite case differences
        XCTAssertNoThrow(try verifier.verifyPCRs(actual, expected: expected))
    }

    // MARK: - Error Description Tests

    func testNitroAttestationErrorDescriptions() {
        let errors: [NitroAttestationError] = [
            .invalidCBOR("test detail"),
            .invalidCOSESignature("test detail"),
            .certificateChainInvalid("test detail"),
            .certificateExpired,
            .pcrMismatch(pcr: 0, expected: "abc", actual: "def"),
            .pcrSetExpired,
            .invalidExpectedPCRFormat,
            .missingPCRValues,
            .missingPublicKey,
            .documentExpired(age: 600),
            .nonceMismatch
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testPCRMismatchErrorContainsDetails() {
        let error = NitroAttestationError.pcrMismatch(
            pcr: 2,
            expected: "abcdef1234567890",
            actual: "1234567890abcdef"
        )

        let description = error.errorDescription!
        XCTAssertTrue(description.contains("PCR2"))
        XCTAssertTrue(description.contains("abcdef"))
        XCTAssertTrue(description.contains("123456"))
    }

    func testDocumentExpiredErrorContainsAge() {
        let error = NitroAttestationError.documentExpired(age: 600)
        let description = error.errorDescription!
        XCTAssertTrue(description.contains("600"))
    }
}

// MARK: - PCR Validation Tests

extension NitroAttestationVerifierTests {

    func testValidateApiPCRsMatchesCurrent() {
        // Given - API PCRs that match the current cached set
        guard let currentSet = verifier.pcrStore.getCurrentPCRSet() else {
            // Skip test if no PCR sets available
            return
        }

        let apiPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: currentSet.pcr0,
            pcr1: currentSet.pcr1,
            pcr2: currentSet.pcr2,
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        // When
        let result = verifier.validateApiPCRs(apiPCRs)

        // Then
        XCTAssertTrue(result.isValid)
        XCTAssertNotNil(result.matchedVersion)
    }

    func testValidateApiPCRsNoMatch() {
        // Given - API PCRs that don't match any cached set
        let apiPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: String(repeating: "f", count: 96),  // Non-matching
            pcr1: String(repeating: "e", count: 96),
            pcr2: String(repeating: "d", count: 96),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        // When
        let result = verifier.validateApiPCRs(apiPCRs)

        // Then
        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.matchedVersion)
        XCTAssertFalse(result.reason.isEmpty)
    }

    func testValidateApiPCRsCaseInsensitive() {
        // Given - API PCRs with different case
        guard let currentSet = verifier.pcrStore.getCurrentPCRSet() else {
            return
        }

        let apiPCRs = NitroAttestationVerifier.ExpectedPCRs(
            pcr0: currentSet.pcr0.uppercased(),
            pcr1: currentSet.pcr1.uppercased(),
            pcr2: currentSet.pcr2.uppercased(),
            validFrom: Date().addingTimeInterval(-3600),
            validUntil: nil
        )

        // When
        let result = verifier.validateApiPCRs(apiPCRs)

        // Then - should still match due to case-insensitive comparison
        XCTAssertTrue(result.isValid)
    }

    func testPCRValidationResultProperties() {
        // Test valid result
        let validResult = NitroAttestationVerifier.PCRValidationResult(
            isValid: true,
            matchedVersion: "v1.0.0",
            reason: "Matches current PCR version"
        )
        XCTAssertTrue(validResult.isValid)
        XCTAssertEqual(validResult.matchedVersion, "v1.0.0")
        XCTAssertTrue(validResult.reason.contains("current"))

        // Test invalid result
        let invalidResult = NitroAttestationVerifier.PCRValidationResult(
            isValid: false,
            matchedVersion: nil,
            reason: "No matching PCR set found"
        )
        XCTAssertFalse(invalidResult.isValid)
        XCTAssertNil(invalidResult.matchedVersion)
    }
}

// MARK: - Data Extension Tests

extension NitroAttestationVerifierTests {

    func testDataFromHexString() {
        // Valid hex
        let data1 = Data(hexString: "48656c6c6f")
        XCTAssertNotNil(data1)
        XCTAssertEqual(String(data: data1!, encoding: .utf8), "Hello")

        // Empty hex
        let data2 = Data(hexString: "")
        XCTAssertNotNil(data2)
        XCTAssertEqual(data2?.count, 0)

        // Uppercase hex
        let data3 = Data(hexString: "ABCDEF")
        XCTAssertNotNil(data3)
        XCTAssertEqual(data3?.count, 3)

        // Invalid hex (odd length)
        let data4 = Data(hexString: "ABC")
        XCTAssertNil(data4)

        // Invalid hex (non-hex characters)
        let data5 = Data(hexString: "GHIJ")
        XCTAssertNil(data5)
    }

    func testDataToHexString() {
        let data = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f])
        let hex = data.hexEncodedString()
        XCTAssertEqual(hex, "48656c6c6f")
    }

    func testHexRoundTrip() {
        let original = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let hex = original.hexEncodedString()
        let restored = Data(hexString: hex)

        XCTAssertEqual(restored, original)
    }
}
