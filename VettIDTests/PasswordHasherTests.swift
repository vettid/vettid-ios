import XCTest
@testable import VettID

final class PasswordHasherTests: XCTestCase {

    // MARK: - Basic Hashing Tests

    func testHashPassword() throws {
        let password = "SecurePassword123!"
        let result = try PasswordHasher.hash(password: password)

        XCTAssertEqual(result.hash.count, 32, "Hash should be 32 bytes")
        XCTAssertEqual(result.salt.count, 16, "Salt should be 16 bytes")
    }

    func testHashWithProvidedSalt() throws {
        let password = "TestPassword"
        let salt = Data(repeating: 0xAB, count: 16)

        let result = try PasswordHasher.hash(password: password, salt: salt)

        XCTAssertEqual(result.salt, salt, "Should use provided salt")
        XCTAssertEqual(result.hash.count, 32, "Hash should be 32 bytes")
    }

    func testHashIsDeterministicWithSameSalt() throws {
        let password = "DeterministicTest"
        let salt = Data(repeating: 0x42, count: 16)

        let result1 = try PasswordHasher.hash(password: password, salt: salt)
        let result2 = try PasswordHasher.hash(password: password, salt: salt)

        XCTAssertEqual(result1.hash, result2.hash, "Same password and salt should produce same hash")
    }

    func testDifferentPasswordsProduceDifferentHashes() throws {
        let salt = Data(repeating: 0x11, count: 16)

        let result1 = try PasswordHasher.hash(password: "Password1", salt: salt)
        let result2 = try PasswordHasher.hash(password: "Password2", salt: salt)

        XCTAssertNotEqual(result1.hash, result2.hash, "Different passwords should produce different hashes")
    }

    func testDifferentSaltsProduceDifferentHashes() throws {
        let password = "SamePassword"

        let result1 = try PasswordHasher.hash(password: password, salt: Data(repeating: 0xAA, count: 16))
        let result2 = try PasswordHasher.hash(password: password, salt: Data(repeating: 0xBB, count: 16))

        XCTAssertNotEqual(result1.hash, result2.hash, "Different salts should produce different hashes")
    }

    // MARK: - Verification Tests

    func testVerifyCorrectPassword() throws {
        let password = "CorrectPassword"
        let result = try PasswordHasher.hash(password: password)

        let isValid = try PasswordHasher.verify(password: password, hash: result.hash, salt: result.salt)

        XCTAssertTrue(isValid, "Correct password should verify successfully")
    }

    func testVerifyIncorrectPassword() throws {
        let password = "CorrectPassword"
        let result = try PasswordHasher.hash(password: password)

        let isValid = try PasswordHasher.verify(password: "WrongPassword", hash: result.hash, salt: result.salt)

        XCTAssertFalse(isValid, "Wrong password should not verify")
    }

    func testVerifyWithWrongSalt() throws {
        let password = "TestPassword"
        let result = try PasswordHasher.hash(password: password)
        let wrongSalt = Data(repeating: 0xFF, count: 16)

        let isValid = try PasswordHasher.verify(password: password, hash: result.hash, salt: wrongSalt)

        XCTAssertFalse(isValid, "Wrong salt should cause verification to fail")
    }

    // MARK: - String Hash Tests

    func testHashToString() throws {
        let password = "StringHashTest"

        let hashString = try PasswordHasher.hashToString(password: password)

        // Check for appropriate prefix based on implementation
        if PasswordHasher.isUsingArgon2id {
            XCTAssertTrue(hashString.hasPrefix("$argon2id$"), "Hash string should be in Argon2id PHC format")
        } else {
            XCTAssertTrue(hashString.hasPrefix("$pbkdf2-sha256$"), "Hash string should be in PBKDF2 format")
        }
        XCTAssertFalse(hashString.isEmpty, "Hash string should not be empty")
    }

    func testVerifyString() throws {
        let password = "StringVerifyTest"

        let hashString = try PasswordHasher.hashToString(password: password)
        let isValid = PasswordHasher.verifyString(password: password, hashString: hashString)

        XCTAssertTrue(isValid, "Correct password should verify against hash string")
    }

    func testVerifyStringWithWrongPassword() throws {
        let password = "CorrectPassword"

        let hashString = try PasswordHasher.hashToString(password: password)
        let isValid = PasswordHasher.verifyString(password: "WrongPassword", hashString: hashString)

        XCTAssertFalse(isValid, "Wrong password should not verify")
    }

    // MARK: - Error Handling Tests

    func testInvalidSaltLength() {
        let invalidSalt = Data(repeating: 0x00, count: 8)  // Should be 16 bytes

        XCTAssertThrowsError(try PasswordHasher.hash(password: "Test", salt: invalidSalt)) { error in
            XCTAssertEqual(error as? PasswordHashError, PasswordHashError.invalidSalt)
        }
    }

    // MARK: - Result Helper Tests

    func testPasswordHashResultCombined() throws {
        let result = try PasswordHasher.hash(password: "Test")

        XCTAssertEqual(result.combined.count, 48, "Combined should be salt (16) + hash (32) = 48 bytes")
        XCTAssertEqual(result.combined.prefix(16), result.salt)
        XCTAssertEqual(result.combined.suffix(32), result.hash)
    }

    func testPasswordHashResultBase64() throws {
        let result = try PasswordHasher.hash(password: "Test")

        // Verify base64 encoding is valid
        XCTAssertNotNil(Data(base64Encoded: result.hashBase64))
        XCTAssertNotNil(Data(base64Encoded: result.saltBase64))

        // Verify decoded values match originals
        XCTAssertEqual(Data(base64Encoded: result.hashBase64), result.hash)
        XCTAssertEqual(Data(base64Encoded: result.saltBase64), result.salt)
    }

    // MARK: - Security Tests

    func testHashingIsNotInstant() throws {
        // Argon2id should take measurable time due to memory-hard computation
        let password = "PerformanceTest"

        let startTime = Date()
        _ = try PasswordHasher.hash(password: password)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should take at least a few milliseconds (adjust based on expected parameters)
        XCTAssertGreaterThan(elapsed, 0.01, "Argon2id should take measurable time")
    }

    func testUnicodePassword() throws {
        let password = "密码🔐パスワード"

        let result = try PasswordHasher.hash(password: password)
        let isValid = try PasswordHasher.verify(password: password, hash: result.hash, salt: result.salt)

        XCTAssertTrue(isValid, "Unicode passwords should work correctly")
    }

    func testEmptyPassword() throws {
        let password = ""

        let result = try PasswordHasher.hash(password: password)
        let isValid = try PasswordHasher.verify(password: password, hash: result.hash, salt: result.salt)

        XCTAssertTrue(isValid, "Empty passwords should hash and verify")
    }

    func testVeryLongPassword() throws {
        let password = String(repeating: "A", count: 10000)

        let result = try PasswordHasher.hash(password: password)
        let isValid = try PasswordHasher.verify(password: password, hash: result.hash, salt: result.salt)

        XCTAssertTrue(isValid, "Long passwords should work correctly")
    }
}
