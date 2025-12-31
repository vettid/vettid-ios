import XCTest
@testable import VettID

/// Tests for RecoveryPhraseManager
final class RecoveryPhraseManagerTests: XCTestCase {

    var manager: RecoveryPhraseManager!

    override func setUp() {
        super.setUp()
        manager = RecoveryPhraseManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Phrase Generation Tests

    func testGenerateRecoveryPhrase_returns24Words() {
        let phrase = manager.generateRecoveryPhrase()

        XCTAssertEqual(phrase.count, 24)
    }

    func testGenerateRecoveryPhrase_allWordsAreValid() {
        let phrase = manager.generateRecoveryPhrase()

        for word in phrase {
            XCTAssertTrue(manager.isValidWord(word), "Word '\(word)' should be valid")
        }
    }

    func testGenerateRecoveryPhrase_uniqueEachTime() {
        let phrase1 = manager.generateRecoveryPhrase()
        let phrase2 = manager.generateRecoveryPhrase()

        // Phrases should be different (extremely unlikely to be the same)
        XCTAssertNotEqual(phrase1, phrase2)
    }

    // MARK: - Word Validation Tests

    func testIsValidWord_validWords() {
        XCTAssertTrue(manager.isValidWord("abandon"))
        XCTAssertTrue(manager.isValidWord("ability"))
        XCTAssertTrue(manager.isValidWord("zoo"))
        XCTAssertTrue(manager.isValidWord("zero"))
    }

    func testIsValidWord_invalidWords() {
        XCTAssertFalse(manager.isValidWord(""))
        XCTAssertFalse(manager.isValidWord("notaword"))
        XCTAssertFalse(manager.isValidWord("invalidword"))
        XCTAssertFalse(manager.isValidWord("123"))
    }

    func testIsValidWord_caseInsensitive() {
        // BIP-39 validation is case-insensitive for user convenience
        XCTAssertTrue(manager.isValidWord("abandon"))
        XCTAssertTrue(manager.isValidWord("ABANDON"))
        XCTAssertTrue(manager.isValidWord("Abandon"))
        XCTAssertTrue(manager.isValidWord("ZOO"))
    }

    // MARK: - Phrase Validation Tests

    func testValidatePhrase_validPhrase() {
        let phrase = manager.generateRecoveryPhrase()

        XCTAssertTrue(manager.validatePhrase(phrase))
    }

    func testValidatePhrase_wrongWordCount() {
        XCTAssertFalse(manager.validatePhrase([]))
        XCTAssertFalse(manager.validatePhrase(["abandon"]))
        XCTAssertFalse(manager.validatePhrase(Array(repeating: "abandon", count: 12)))
        XCTAssertFalse(manager.validatePhrase(Array(repeating: "abandon", count: 25)))
    }

    func testValidatePhrase_invalidWords() {
        var phrase = Array(repeating: "abandon", count: 24)
        phrase[0] = "notaword"

        XCTAssertFalse(manager.validatePhrase(phrase))
    }

    // MARK: - Suggestion Tests

    func testGetSuggestions_matchingPrefix() {
        let suggestions = manager.getSuggestions(for: "ab")

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("ab") })
        XCTAssertTrue(suggestions.contains("abandon"))
        XCTAssertTrue(suggestions.contains("ability"))
        XCTAssertTrue(suggestions.contains("able"))
    }

    func testGetSuggestions_noMatch() {
        let suggestions = manager.getSuggestions(for: "xyz")

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testGetSuggestions_twoLetterPrefix() {
        // Suggestions require minimum 2 characters
        let suggestions = manager.getSuggestions(for: "zo")

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("zo") })
        XCTAssertTrue(suggestions.contains("zone"))
        XCTAssertTrue(suggestions.contains("zoo"))
    }

    func testGetSuggestions_singleLetterReturnsEmpty() {
        // Single letter should return empty (requires 2+ chars for suggestions)
        let suggestions = manager.getSuggestions(for: "z")
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testGetSuggestions_limitedResults() {
        // Use "ab" prefix which has many matches
        let suggestions = manager.getSuggestions(for: "ab")

        // Should be limited (default limit is 5)
        XCTAssertLessThanOrEqual(suggestions.count, 5)
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("ab") })
    }

    // MARK: - BIP39 Word List Tests

    func testBIP39WordList_count() {
        XCTAssertEqual(BIP39WordList.words.count, 2048)
    }

    func testBIP39WordList_isValidWord() {
        XCTAssertTrue(BIP39WordList.isValidWord("abandon"))
        XCTAssertTrue(BIP39WordList.isValidWord("zoo"))
        XCTAssertFalse(BIP39WordList.isValidWord("invalid"))
    }

    func testBIP39WordList_getSuggestions() {
        let suggestions = BIP39WordList.getSuggestions(for: "ab", limit: 5)

        XCTAssertLessThanOrEqual(suggestions.count, 5)
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("ab") })
    }

    func testBIP39WordList_index() {
        // First word should be at index 0
        XCTAssertEqual(BIP39WordList.index(of: "abandon"), 0)

        // Last word should be at index 2047
        XCTAssertEqual(BIP39WordList.index(of: "zoo"), 2047)

        // Invalid word returns nil
        XCTAssertNil(BIP39WordList.index(of: "invalid"))
    }

    // MARK: - Key Derivation Tests

    func testDeriveKeyFromPhrase_consistentOutput() throws {
        let phrase = ["abandon", "ability", "able", "about", "above", "absent",
                      "absorb", "abstract", "absurd", "abuse", "access", "accident",
                      "account", "accuse", "achieve", "acid", "acoustic", "acquire",
                      "across", "act", "action", "actor", "actress", "actual"]
        let salt = Data([0x01, 0x02, 0x03, 0x04])

        let key1 = try manager.deriveKeyFromPhrase(phrase, salt: salt)
        let key2 = try manager.deriveKeyFromPhrase(phrase, salt: salt)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.count, 32) // 256 bits
    }

    func testDeriveKeyFromPhrase_differentSaltProducesDifferentKey() throws {
        let phrase = ["abandon", "ability", "able", "about", "above", "absent",
                      "absorb", "abstract", "absurd", "abuse", "access", "accident",
                      "account", "accuse", "achieve", "acid", "acoustic", "acquire",
                      "across", "act", "action", "actor", "actress", "actual"]
        let salt1 = Data([0x01, 0x02, 0x03, 0x04])
        let salt2 = Data([0x05, 0x06, 0x07, 0x08])

        let key1 = try manager.deriveKeyFromPhrase(phrase, salt: salt1)
        let key2 = try manager.deriveKeyFromPhrase(phrase, salt: salt2)

        XCTAssertNotEqual(key1, key2)
    }

    func testDeriveKeyFromPhrase_differentPhraseProducesDifferentKey() throws {
        let phrase1 = ["abandon", "ability", "able", "about", "above", "absent",
                       "absorb", "abstract", "absurd", "abuse", "access", "accident",
                       "account", "accuse", "achieve", "acid", "acoustic", "acquire",
                       "across", "act", "action", "actor", "actress", "actual"]
        let phrase2 = ["zoo", "ability", "able", "about", "above", "absent",
                       "absorb", "abstract", "absurd", "abuse", "access", "accident",
                       "account", "accuse", "achieve", "acid", "acoustic", "acquire",
                       "across", "act", "action", "actor", "actress", "actual"]
        let salt = Data([0x01, 0x02, 0x03, 0x04])

        let key1 = try manager.deriveKeyFromPhrase(phrase1, salt: salt)
        let key2 = try manager.deriveKeyFromPhrase(phrase2, salt: salt)

        XCTAssertNotEqual(key1, key2)
    }

    // MARK: - Encryption/Decryption Tests

    func testEncryptDecrypt_roundTrip() throws {
        let phrase = manager.generateRecoveryPhrase()
        let originalData = "Test credential data".data(using: .utf8)!

        let encrypted = try manager.encryptCredentialBackup(originalData, phrase: phrase)
        let decrypted = try manager.decryptCredentialBackup(encrypted, phrase: phrase)

        XCTAssertEqual(decrypted, originalData)
    }

    func testEncrypt_producesNonDeterministicOutput() throws {
        let phrase = manager.generateRecoveryPhrase()
        let data = "Test data".data(using: .utf8)!

        let encrypted1 = try manager.encryptCredentialBackup(data, phrase: phrase)
        let encrypted2 = try manager.encryptCredentialBackup(data, phrase: phrase)

        // Salt and nonce should be different
        XCTAssertNotEqual(encrypted1.salt, encrypted2.salt)
        XCTAssertNotEqual(encrypted1.nonce, encrypted2.nonce)
        // Ciphertext should be different due to different nonce
        XCTAssertNotEqual(encrypted1.ciphertext, encrypted2.ciphertext)
    }

    func testDecrypt_wrongPhraseFails() throws {
        let phrase1 = manager.generateRecoveryPhrase()
        let phrase2 = manager.generateRecoveryPhrase()
        let data = "Test data".data(using: .utf8)!

        let encrypted = try manager.encryptCredentialBackup(data, phrase: phrase1)

        XCTAssertThrowsError(try manager.decryptCredentialBackup(encrypted, phrase: phrase2)) { error in
            guard case RecoveryPhraseManager.RecoveryPhraseError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed error")
                return
            }
        }
    }

    func testEncryptedBackup_structure() throws {
        let phrase = manager.generateRecoveryPhrase()
        let data = "Test data".data(using: .utf8)!

        let encrypted = try manager.encryptCredentialBackup(data, phrase: phrase)

        XCTAssertFalse(encrypted.ciphertext.isEmpty)
        XCTAssertEqual(encrypted.salt.count, 32) // Salt should be 32 bytes
        XCTAssertEqual(encrypted.nonce.count, 12) // ChaCha20-Poly1305 nonce is 12 bytes
    }
}
