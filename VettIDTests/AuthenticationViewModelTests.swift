import XCTest
@testable import VettID

/// Tests for AuthenticationViewModel state machine and flow
@MainActor
final class AuthenticationViewModelTests: XCTestCase {

    var viewModel: AuthenticationViewModel!

    override func setUp() {
        super.setUp()
        viewModel = AuthenticationViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertEqual(viewModel.state, .initial)
        XCTAssertTrue(viewModel.password.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showError)
        XCTAssertTrue(viewModel.serverLatId.isEmpty)
        XCTAssertFalse(viewModel.latVerified)
    }

    // MARK: - State Title Tests

    func testStateTitles() {
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.initial.title, "Authenticate")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.requestingToken.title, "Connecting...")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.verifyingLAT.title, "Verify Server")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.awaitingPassword.title, "Enter Password")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.authenticating.title, "Authenticating...")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.success.title, "Success")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.credentialRotated(newCekVersion: 1, newLatVersion: 1).title, "Success")
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.error(message: "test", retryable: true).title, "Error")
    }

    // MARK: - State Can Go Back Tests

    func testStateCanGoBack() {
        XCTAssertTrue(AuthenticationViewModel.AuthenticationState.initial.canGoBack)
        XCTAssertTrue(AuthenticationViewModel.AuthenticationState.verifyingLAT.canGoBack)
        XCTAssertTrue(AuthenticationViewModel.AuthenticationState.awaitingPassword.canGoBack)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.requestingToken.canGoBack)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.authenticating.canGoBack)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.success.canGoBack)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.credentialRotated(newCekVersion: 1, newLatVersion: 1).canGoBack)
    }

    // MARK: - State Is Processing Tests

    func testStateIsProcessing() {
        XCTAssertTrue(AuthenticationViewModel.AuthenticationState.requestingToken.isProcessing)
        XCTAssertTrue(AuthenticationViewModel.AuthenticationState.authenticating.isProcessing)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.initial.isProcessing)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.verifyingLAT.isProcessing)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.awaitingPassword.isProcessing)
        XCTAssertFalse(AuthenticationViewModel.AuthenticationState.success.isProcessing)
    }

    // MARK: - Reset Tests

    func testReset() {
        // Simulate some state
        viewModel.password = "TestPassword123"
        viewModel.showError = true
        viewModel.errorMessage = "Test error"
        viewModel.serverLatId = "test-lat-id"
        viewModel.latVerified = true

        // Reset
        viewModel.reset()

        // Verify reset
        XCTAssertEqual(viewModel.state, .initial)
        XCTAssertTrue(viewModel.password.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showError)
        XCTAssertTrue(viewModel.serverLatId.isEmpty)
        XCTAssertFalse(viewModel.latVerified)
    }

    // MARK: - Authentication Error Tests

    func testAuthenticationErrorDescriptions() {
        XCTAssertNotNil(AuthenticationError.noCredential.errorDescription)
        XCTAssertTrue(AuthenticationError.noCredential.errorDescription!.contains("enroll"))

        XCTAssertNotNil(AuthenticationError.latMismatch.errorDescription)
        XCTAssertTrue(AuthenticationError.latMismatch.errorDescription!.contains("phishing"))

        XCTAssertNotNil(AuthenticationError.authenticationFailed.errorDescription)
        XCTAssertTrue(AuthenticationError.authenticationFailed.errorDescription!.contains("password"))

        XCTAssertNotNil(AuthenticationError.tokenExpired.errorDescription)
        XCTAssertTrue(AuthenticationError.tokenExpired.errorDescription!.contains("expired"))

        XCTAssertNotNil(AuthenticationError.emptyPassword.errorDescription)
        XCTAssertTrue(AuthenticationError.emptyPassword.errorDescription!.contains("password"))
    }

    // MARK: - Authentication Error Retryable Tests

    func testAuthenticationErrorRetryable() {
        // Not retryable errors
        XCTAssertFalse(AuthenticationError.noCredential.isRetryable)
        XCTAssertFalse(AuthenticationError.latMismatch.isRetryable)
        XCTAssertFalse(AuthenticationError.keyNotFound.isRetryable)
        XCTAssertFalse(AuthenticationError.keyAlreadyUsed.isRetryable)
        XCTAssertFalse(AuthenticationError.invalidState.isRetryable)

        // Retryable errors
        XCTAssertTrue(AuthenticationError.authenticationFailed.isRetryable)
        XCTAssertTrue(AuthenticationError.tokenExpired.isRetryable)
        XCTAssertTrue(AuthenticationError.emptyPassword.isRetryable)
    }

    // MARK: - LAT Verification Tests

    func testVerifyLATWithoutStoredCredential() {
        // When no credential is stored, LAT verification should fail
        let result = viewModel.verifyLAT()
        XCTAssertFalse(result)
        XCTAssertFalse(viewModel.latVerified)
    }

    func testConfirmLATVerificationWithoutMatch() {
        // When LAT doesn't match, confirmLATVerification should set error state
        viewModel.confirmLATVerification()

        if case .error(let message, let retryable) = viewModel.state {
            XCTAssertTrue(message.contains("phishing") || message.contains("verification"))
            XCTAssertFalse(retryable)
        } else {
            XCTFail("Expected error state for LAT mismatch")
        }
    }

    func testReportLATMismatch() {
        viewModel.reportLATMismatch()

        if case .error(let message, let retryable) = viewModel.state {
            XCTAssertTrue(message.contains("phishing") || message.contains("verification"))
            XCTAssertFalse(retryable)
        } else {
            XCTFail("Expected error state after reporting LAT mismatch")
        }
    }

    // MARK: - State Equality Tests

    func testStateEquality() {
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.initial, .initial)
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.requestingToken, .requestingToken)
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.verifyingLAT, .verifyingLAT)
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.awaitingPassword, .awaitingPassword)
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.authenticating, .authenticating)
        XCTAssertEqual(AuthenticationViewModel.AuthenticationState.success, .success)

        XCTAssertNotEqual(AuthenticationViewModel.AuthenticationState.initial, .requestingToken)
        XCTAssertNotEqual(AuthenticationViewModel.AuthenticationState.success, .authenticating)
    }

    func testStateEqualityWithAssociatedValues() {
        let rotated1 = AuthenticationViewModel.AuthenticationState.credentialRotated(newCekVersion: 1, newLatVersion: 1)
        let rotated2 = AuthenticationViewModel.AuthenticationState.credentialRotated(newCekVersion: 1, newLatVersion: 1)
        let rotated3 = AuthenticationViewModel.AuthenticationState.credentialRotated(newCekVersion: 2, newLatVersion: 1)

        XCTAssertEqual(rotated1, rotated2)
        XCTAssertNotEqual(rotated1, rotated3)

        let error1 = AuthenticationViewModel.AuthenticationState.error(message: "test", retryable: true)
        let error2 = AuthenticationViewModel.AuthenticationState.error(message: "test", retryable: true)
        let error3 = AuthenticationViewModel.AuthenticationState.error(message: "different", retryable: true)

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    // MARK: - Credential Key Count Tests

    func testRemainingKeyCountWithoutCredential() {
        // When no credential is stored, should return 0
        XCTAssertEqual(viewModel.remainingKeyCount, 0)
    }

    func testNeedsReenrollmentWithoutCredential() {
        // When no credential is stored, needs re-enrollment
        XCTAssertTrue(viewModel.needsReenrollment)
    }
}
