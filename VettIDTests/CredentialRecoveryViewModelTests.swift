import XCTest
@testable import VettID

/// Tests for CredentialRecoveryViewModel
@MainActor
final class CredentialRecoveryViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        if case .entering = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected entering state, got \(viewModel.state)")
        }
        XCTAssertEqual(viewModel.enteredWords.count, 24)
        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
        XCTAssertEqual(viewModel.wordValidation.count, 24)
        XCTAssertTrue(viewModel.wordValidation.allSatisfy { $0 == true })
        XCTAssertTrue(viewModel.currentSuggestions.isEmpty)
        XCTAssertEqual(viewModel.focusedIndex, 0)
    }

    // MARK: - State Equatable Tests

    func testCredentialRecoveryState_equatable() {
        XCTAssertEqual(CredentialRecoveryState.entering, CredentialRecoveryState.entering)
        XCTAssertEqual(CredentialRecoveryState.validating, CredentialRecoveryState.validating)
        XCTAssertEqual(CredentialRecoveryState.recovering, CredentialRecoveryState.recovering)
        XCTAssertEqual(CredentialRecoveryState.complete, CredentialRecoveryState.complete)
        XCTAssertEqual(CredentialRecoveryState.error("test"), CredentialRecoveryState.error("test"))
        XCTAssertNotEqual(CredentialRecoveryState.error("a"), CredentialRecoveryState.error("b"))
        XCTAssertNotEqual(CredentialRecoveryState.entering, CredentialRecoveryState.validating)
    }

    // MARK: - Word Entry Tests

    func testSetWord_validWord() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "abandon")

        XCTAssertEqual(viewModel.enteredWords[0], "abandon")
        XCTAssertTrue(viewModel.wordValidation[0])
    }

    func testSetWord_invalidWord() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "notaword")

        XCTAssertEqual(viewModel.enteredWords[0], "notaword")
        XCTAssertFalse(viewModel.wordValidation[0])
    }

    func testSetWord_emptyWord() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "abandon")
        viewModel.setWord(0, "")

        XCTAssertEqual(viewModel.enteredWords[0], "")
        XCTAssertTrue(viewModel.wordValidation[0]) // Empty is considered valid (not entered yet)
    }

    func testSetWord_trimAndLowercase() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "  ABANDON  ")

        XCTAssertEqual(viewModel.enteredWords[0], "abandon")
        XCTAssertTrue(viewModel.wordValidation[0])
    }

    func testSetWord_outOfBounds() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        // Should not crash
        viewModel.setWord(-1, "abandon")
        viewModel.setWord(24, "abandon")

        // All words should remain empty
        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
    }

    // MARK: - Focus Tests

    func testSetFocusedIndex() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setFocusedIndex(5)

        XCTAssertEqual(viewModel.focusedIndex, 5)
    }

    func testSetFocusedIndex_nil() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setFocusedIndex(nil)

        XCTAssertNil(viewModel.focusedIndex)
        XCTAssertTrue(viewModel.currentSuggestions.isEmpty)
    }

    // MARK: - Suggestion Tests

    func testApplySuggestion() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setFocusedIndex(0)
        viewModel.applySuggestion("abandon")

        XCTAssertEqual(viewModel.enteredWords[0], "abandon")
        XCTAssertEqual(viewModel.focusedIndex, 1) // Moves to next field
    }

    func testApplySuggestion_lastField() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setFocusedIndex(23)
        viewModel.applySuggestion("zoo")

        XCTAssertEqual(viewModel.enteredWords[23], "zoo")
        XCTAssertEqual(viewModel.focusedIndex, 23) // Stays at last field
    }

    func testApplySuggestion_noFocus() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setFocusedIndex(nil)
        viewModel.applySuggestion("abandon")

        // Should have no effect
        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
    }

    // MARK: - Phrase Complete Tests

    func testIsPhraseComplete_allEmpty() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        XCTAssertFalse(viewModel.isPhraseComplete)
    }

    func testIsPhraseComplete_partiallyFilled() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "abandon")
        viewModel.setWord(1, "ability")

        XCTAssertFalse(viewModel.isPhraseComplete)
    }

    func testIsPhraseComplete_allFilledButInvalid() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        for i in 0..<24 {
            viewModel.setWord(i, "invalid\(i)")
        }

        XCTAssertFalse(viewModel.isPhraseComplete)
    }

    // MARK: - Clear and Reset Tests

    func testClearAll() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "abandon")
        viewModel.setWord(1, "ability")
        viewModel.setFocusedIndex(5)

        viewModel.clearAll()

        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
        XCTAssertTrue(viewModel.wordValidation.allSatisfy { $0 == true })
        XCTAssertEqual(viewModel.focusedIndex, 0)
    }

    func testReset() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.setWord(0, "abandon")

        viewModel.reset()

        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
        XCTAssertTrue(viewModel.wordValidation.allSatisfy { $0 == true })
        XCTAssertTrue(viewModel.currentSuggestions.isEmpty)
        XCTAssertEqual(viewModel.focusedIndex, 0)
        if case .entering = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected entering state after reset")
        }
    }

    // MARK: - Paste Tests

    func testPastePhrase_valid24Words() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual"
        viewModel.pastePhrase(phrase)

        XCTAssertEqual(viewModel.enteredWords[0], "abandon")
        XCTAssertEqual(viewModel.enteredWords[23], "actual")
        XCTAssertEqual(viewModel.enteredWords.filter { !$0.isEmpty }.count, 24)
    }

    func testPastePhrase_lessThan24Words() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        viewModel.pastePhrase("abandon ability able")

        // Should not apply partial phrase
        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
    }

    func testPastePhrase_moreThan24Words() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual extra"
        viewModel.pastePhrase(phrase)

        // Should not apply phrase with wrong word count
        XCTAssertTrue(viewModel.enteredWords.allSatisfy { $0.isEmpty })
    }

    func testPastePhrase_withNewlines() {
        let viewModel = CredentialRecoveryViewModel(authTokenProvider: { "test-token" })

        let phrase = """
        abandon ability able about above absent absorb abstract
        absurd abuse access accident account accuse achieve acid
        acoustic acquire across act action actor actress actual
        """
        viewModel.pastePhrase(phrase)

        XCTAssertEqual(viewModel.enteredWords[0], "abandon")
        XCTAssertEqual(viewModel.enteredWords[23], "actual")
    }
}
