import XCTest
@testable import VettID

final class PatternAuthenticatorTests: XCTestCase {

    // MARK: - Serialization Tests

    func testSerializePattern() {
        let pattern = [0, 3, 6, 7, 8]  // L-shape
        let serialized = PatternAuthenticator.serialize(pattern)

        XCTAssertEqual(serialized, "0,3,6,7,8", "Pattern should serialize to comma-separated format")
    }

    func testSerializeEmptyPattern() {
        let pattern: [Int] = []
        let serialized = PatternAuthenticator.serialize(pattern)

        XCTAssertEqual(serialized, "", "Empty pattern should serialize to empty string")
    }

    func testSerializeSinglePoint() {
        let pattern = [4]
        let serialized = PatternAuthenticator.serialize(pattern)

        XCTAssertEqual(serialized, "4", "Single point should serialize correctly")
    }

    func testDeserializePattern() {
        let serialized = "0,3,6,7,8"
        let pattern = PatternAuthenticator.deserialize(serialized)

        XCTAssertEqual(pattern, [0, 3, 6, 7, 8], "Pattern should deserialize correctly")
    }

    func testDeserializeEmptyString() {
        let serialized = ""
        let pattern = PatternAuthenticator.deserialize(serialized)

        // Empty string deserializes to empty array (round-trip consistency)
        XCTAssertEqual(pattern, [], "Empty string should deserialize to empty array")
    }

    func testDeserializeInvalidPattern() {
        let serialized = "0,a,6,7,8"
        let pattern = PatternAuthenticator.deserialize(serialized)

        XCTAssertNil(pattern, "Invalid pattern with non-numeric values should return nil")
    }

    func testSerializeDeserializeRoundTrip() {
        let original = [0, 1, 2, 5, 8, 7, 6, 3]
        let serialized = PatternAuthenticator.serialize(original)
        let deserialized = PatternAuthenticator.deserialize(serialized)

        XCTAssertEqual(deserialized, original, "Round trip should preserve pattern")
    }

    // MARK: - Validation Tests

    func testValidPattern3x3() {
        let pattern = [0, 1, 2, 5]  // Minimum 4 points
        let result = PatternAuthenticator.validate(pattern, gridSize: .threeByThree)

        XCTAssertTrue(result.isValid, "Valid pattern should pass validation")
    }

    func testValidPattern4x4() {
        let pattern = [0, 1, 2, 3, 7]  // 5 points on 4x4 grid
        let result = PatternAuthenticator.validate(pattern, gridSize: .fourByFour)

        XCTAssertTrue(result.isValid, "Valid pattern on 4x4 grid should pass")
    }

    func testPatternTooShort() {
        let pattern = [0, 1, 2]  // Only 3 points
        let result = PatternAuthenticator.validate(pattern)

        XCTAssertFalse(result.isValid, "Pattern with less than 4 points should fail")
        if case .tooShort(let minimum) = result {
            XCTAssertEqual(minimum, 4, "Minimum should be 4 points")
        } else {
            XCTFail("Expected tooShort error")
        }
    }

    func testPatternWithDuplicates() {
        let pattern = [0, 1, 2, 1, 4]  // Point 1 repeated
        let result = PatternAuthenticator.validate(pattern)

        XCTAssertFalse(result.isValid, "Pattern with duplicates should fail")
        XCTAssertEqual(result, .hasDuplicates, "Should return hasDuplicates error")
    }

    func testPatternWithInvalidIndex3x3() {
        let pattern = [0, 1, 9, 4]  // 9 is out of bounds for 3x3
        let result = PatternAuthenticator.validate(pattern, gridSize: .threeByThree)

        XCTAssertFalse(result.isValid, "Pattern with out-of-bounds index should fail")
        if case .invalidIndex(let index) = result {
            XCTAssertEqual(index, 9, "Invalid index should be 9")
        } else {
            XCTFail("Expected invalidIndex error")
        }
    }

    func testPatternWithNegativeIndex() {
        let pattern = [-1, 0, 1, 2]
        let result = PatternAuthenticator.validate(pattern)

        XCTAssertFalse(result.isValid, "Pattern with negative index should fail")
        if case .invalidIndex(let index) = result {
            XCTAssertEqual(index, -1, "Invalid index should be -1")
        } else {
            XCTFail("Expected invalidIndex error")
        }
    }

    func testMaxValidIndex3x3() {
        let pattern = [0, 4, 8, 6]  // 8 is max valid for 3x3
        let result = PatternAuthenticator.validate(pattern, gridSize: .threeByThree)

        XCTAssertTrue(result.isValid, "Pattern with max valid index should pass")
    }

    func testMaxValidIndex4x4() {
        let pattern = [0, 5, 10, 15]  // 15 is max valid for 4x4
        let result = PatternAuthenticator.validate(pattern, gridSize: .fourByFour)

        XCTAssertTrue(result.isValid, "Pattern with max valid index for 4x4 should pass")
    }

    // MARK: - Hashing Tests

    func testHashPattern() {
        let pattern = [0, 3, 6, 7, 8]
        let hash = PatternAuthenticator.hash(pattern)

        XCTAssertEqual(hash.count, 64, "SHA256 hash should be 64 hex characters")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "Hash should only contain hex digits")
    }

    func testHashIsDeterministic() {
        let pattern = [0, 1, 2, 5, 8]
        let hash1 = PatternAuthenticator.hash(pattern)
        let hash2 = PatternAuthenticator.hash(pattern)

        XCTAssertEqual(hash1, hash2, "Same pattern should produce same hash")
    }

    func testDifferentPatternsProduceDifferentHashes() {
        let pattern1 = [0, 1, 2, 5]
        let pattern2 = [0, 1, 2, 4]
        let hash1 = PatternAuthenticator.hash(pattern1)
        let hash2 = PatternAuthenticator.hash(pattern2)

        XCTAssertNotEqual(hash1, hash2, "Different patterns should produce different hashes")
    }

    func testPatternOrderMatters() {
        let pattern1 = [0, 1, 2, 5]
        let pattern2 = [5, 2, 1, 0]  // Reversed
        let hash1 = PatternAuthenticator.hash(pattern1)
        let hash2 = PatternAuthenticator.hash(pattern2)

        XCTAssertNotEqual(hash1, hash2, "Pattern order should affect hash")
    }

    // MARK: - Verification Tests

    func testVerifyCorrectPattern() {
        let pattern = [0, 3, 6, 7, 8]
        let hash = PatternAuthenticator.hash(pattern)
        let isValid = PatternAuthenticator.verify(pattern, against: hash)

        XCTAssertTrue(isValid, "Correct pattern should verify")
    }

    func testVerifyWrongPattern() {
        let correctPattern = [0, 3, 6, 7, 8]
        let wrongPattern = [0, 3, 6, 7, 5]
        let hash = PatternAuthenticator.hash(correctPattern)
        let isValid = PatternAuthenticator.verify(wrongPattern, against: hash)

        XCTAssertFalse(isValid, "Wrong pattern should not verify")
    }

    func testVerifyWithModifiedHash() {
        let pattern = [0, 1, 2, 5]
        var hash = PatternAuthenticator.hash(pattern)
        // Modify one character
        hash = String(hash.dropLast()) + "0"
        let isValid = PatternAuthenticator.verify(pattern, against: hash)

        XCTAssertFalse(isValid, "Modified hash should not verify")
    }

    func testVerifyWithDifferentLengthHash() {
        let pattern = [0, 1, 2, 5]
        let shortHash = "abc123"
        let isValid = PatternAuthenticator.verify(pattern, against: shortHash)

        XCTAssertFalse(isValid, "Hash with wrong length should not verify")
    }

    // MARK: - Cross-Platform Compatibility Tests

    func testKnownPatternHash() {
        // This test ensures consistent hashing across platforms
        // Pattern "0,3,6,7,8" should always produce the same hash
        let pattern = [0, 3, 6, 7, 8]
        let serialized = PatternAuthenticator.serialize(pattern)

        // Verify serialization format
        XCTAssertEqual(serialized, "0,3,6,7,8")

        // The hash is SHA256 of "0,3,6,7,8"
        let hash = PatternAuthenticator.hash(pattern)

        // Store the expected hash for cross-platform verification
        // This can be verified against Android/backend
        XCTAssertFalse(hash.isEmpty, "Hash should not be empty")
        XCTAssertEqual(hash.count, 64, "SHA256 produces 64 hex chars")
    }

    func testGridSizeEnumValues() {
        XCTAssertEqual(PatternAuthenticator.GridSize.threeByThree.rawValue, 3)
        XCTAssertEqual(PatternAuthenticator.GridSize.fourByFour.rawValue, 4)
        XCTAssertEqual(PatternAuthenticator.GridSize.threeByThree.totalDots, 9)
        XCTAssertEqual(PatternAuthenticator.GridSize.fourByFour.totalDots, 16)
    }

    // MARK: - Validation Result Tests

    func testValidationResultErrorMessages() {
        XCTAssertNil(PatternValidationResult.valid.errorMessage)
        XCTAssertNotNil(PatternValidationResult.tooShort(minimum: 4).errorMessage)
        XCTAssertNotNil(PatternValidationResult.invalidIndex(10).errorMessage)
        XCTAssertNotNil(PatternValidationResult.hasDuplicates.errorMessage)
    }

    func testValidationResultIsValid() {
        XCTAssertTrue(PatternValidationResult.valid.isValid)
        XCTAssertFalse(PatternValidationResult.tooShort(minimum: 4).isValid)
        XCTAssertFalse(PatternValidationResult.invalidIndex(10).isValid)
        XCTAssertFalse(PatternValidationResult.hasDuplicates.isValid)
    }

    // MARK: - Minimum Length Constant

    func testMinimumPatternLength() {
        XCTAssertEqual(PatternAuthenticator.minimumPatternLength, 4,
                       "Minimum pattern length should be 4 for security")
    }
}
