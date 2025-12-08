import XCTest
@testable import VettID

/// Tests for CredentialBackupViewModel
@MainActor
final class CredentialBackupViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let viewModel = CredentialBackupViewModel(authTokenProvider: { "test-token" })

        if case .initial = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected initial state, got \(viewModel.state)")
        }
    }

    // MARK: - State Equatable Tests

    func testCredentialBackupState_equatable() {
        // Test initial state
        XCTAssertEqual(CredentialBackupState.initial, CredentialBackupState.initial)

        // Test generating state
        XCTAssertEqual(CredentialBackupState.generating, CredentialBackupState.generating)

        // Test uploading state
        XCTAssertEqual(CredentialBackupState.uploading, CredentialBackupState.uploading)

        // Test complete state
        XCTAssertEqual(CredentialBackupState.complete, CredentialBackupState.complete)

        // Test error state
        XCTAssertEqual(CredentialBackupState.error("test"), CredentialBackupState.error("test"))
        XCTAssertNotEqual(CredentialBackupState.error("a"), CredentialBackupState.error("b"))

        // Test showingPhrase state
        let words = ["word1", "word2"]
        XCTAssertEqual(
            CredentialBackupState.showingPhrase(words),
            CredentialBackupState.showingPhrase(words)
        )

        // Test verifying state
        let indices = [1, 5, 10]
        XCTAssertEqual(
            CredentialBackupState.verifying(words, indices),
            CredentialBackupState.verifying(words, indices)
        )

        // Different states are not equal
        XCTAssertNotEqual(CredentialBackupState.initial, CredentialBackupState.generating)
        XCTAssertNotEqual(CredentialBackupState.uploading, CredentialBackupState.complete)
    }

    // MARK: - Encrypted Backup Tests

    func testEncryptedCredentialBackup_structure() {
        let ciphertext = Data([0x01, 0x02, 0x03])
        let salt = Data([0x04, 0x05, 0x06])
        let nonce = Data([0x07, 0x08, 0x09])

        let backup = EncryptedCredentialBackup(
            ciphertext: ciphertext,
            salt: salt,
            nonce: nonce
        )

        XCTAssertEqual(backup.ciphertext, ciphertext)
        XCTAssertEqual(backup.salt, salt)
        XCTAssertEqual(backup.nonce, nonce)
    }
}
