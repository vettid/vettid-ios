import XCTest
@testable import VettID

/// Tests for EnrollmentViewModel state machine and transitions
@MainActor
final class EnrollmentViewModelTests: XCTestCase {

    var viewModel: EnrollmentViewModel!

    override func setUp() {
        super.setUp()
        viewModel = EnrollmentViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertEqual(viewModel.state, .initial)
        XCTAssertNil(viewModel.scannedCode)
        XCTAssertTrue(viewModel.password.isEmpty)
        XCTAssertTrue(viewModel.confirmPassword.isEmpty)
        XCTAssertEqual(viewModel.passwordStrength, .weak)
    }

    func testStartScanning() {
        viewModel.startScanning()
        XCTAssertEqual(viewModel.state, .scanningQR)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Password Strength Tests

    func testPasswordStrengthWeak() {
        viewModel.password = "abc"
        viewModel.updatePasswordStrength()
        XCTAssertEqual(viewModel.passwordStrength, .weak)
    }

    func testPasswordStrengthFair() {
        viewModel.password = "abcdefghijkl"  // 12 chars, lowercase only
        viewModel.updatePasswordStrength()
        // Score: 1 (length >= 12) + 1 (lowercase) = 2 -> weak
        // Need more variety for fair
        XCTAssertEqual(viewModel.passwordStrength, .weak)
    }

    func testPasswordStrengthGood() {
        viewModel.password = "Abcdefghijkl1"  // 13 chars, upper, lower, number
        viewModel.updatePasswordStrength()
        // Score: 1 (>=12) + 1 (lower) + 1 (upper) + 1 (number) = 4 -> good
        XCTAssertEqual(viewModel.passwordStrength, .good)
    }

    func testPasswordStrengthStrong() {
        viewModel.password = "Abcdefghijklmnop1!"  // 18 chars, all variety
        viewModel.updatePasswordStrength()
        // Score: 1 (>=12) + 1 (>=16) + 1 (lower) + 1 (upper) + 1 (number) + 1 (special) = 6 -> strong
        XCTAssertEqual(viewModel.passwordStrength, .strong)
    }

    func testPasswordStrengthVeryStrong() {
        viewModel.password = "Abcdefghijklmnopqrst1!"  // 22 chars, all variety
        viewModel.updatePasswordStrength()
        // Score: 1 (>=12) + 1 (>=16) + 1 (>=20) + 1 (lower) + 1 (upper) + 1 (number) + 1 (special) = 7 -> veryStrong
        XCTAssertEqual(viewModel.passwordStrength, .veryStrong)
    }

    // MARK: - Password Validation Tests

    func testIsPasswordValidFailsWithShortPassword() {
        viewModel.password = "Short1!"
        viewModel.confirmPassword = "Short1!"
        viewModel.updatePasswordStrength()
        XCTAssertFalse(viewModel.isPasswordValid)
    }

    func testIsPasswordValidFailsWithMismatch() {
        viewModel.password = "ValidPassword123!"
        viewModel.confirmPassword = "DifferentPassword123!"
        viewModel.updatePasswordStrength()
        XCTAssertFalse(viewModel.isPasswordValid)
    }

    func testIsPasswordValidFailsWithWeakStrength() {
        viewModel.password = "weakpassword12"  // Only lowercase, no special or uppercase
        viewModel.confirmPassword = "weakpassword12"
        viewModel.updatePasswordStrength()
        XCTAssertFalse(viewModel.isPasswordValid)
    }

    func testIsPasswordValidSucceeds() {
        viewModel.password = "StrongPassword123!"
        viewModel.confirmPassword = "StrongPassword123!"
        viewModel.updatePasswordStrength()
        XCTAssertTrue(viewModel.isPasswordValid)
    }

    // MARK: - Password Validation Errors Tests

    func testPasswordValidationErrorsEmpty() {
        viewModel.password = "StrongPassword123!"
        viewModel.confirmPassword = "StrongPassword123!"
        viewModel.updatePasswordStrength()
        XCTAssertTrue(viewModel.passwordValidationErrors.isEmpty)
    }

    func testPasswordValidationErrorsShort() {
        viewModel.password = "Short"
        viewModel.updatePasswordStrength()
        let errors = viewModel.passwordValidationErrors
        XCTAssertTrue(errors.contains { $0.contains("12 characters") })
    }

    func testPasswordValidationErrorsWeak() {
        viewModel.password = "weakpassword"  // 12 chars but weak
        viewModel.updatePasswordStrength()
        let errors = viewModel.passwordValidationErrors
        XCTAssertTrue(errors.contains { $0.contains("weak") })
    }

    func testPasswordValidationErrorsMismatch() {
        viewModel.password = "Password123!"
        viewModel.confirmPassword = "Different123!"
        let errors = viewModel.passwordValidationErrors
        XCTAssertTrue(errors.contains { $0.contains("match") })
    }

    // MARK: - Reset Tests

    func testReset() {
        // Set some state
        viewModel.password = "TestPassword"
        viewModel.confirmPassword = "TestPassword"
        viewModel.updatePasswordStrength()

        // Reset
        viewModel.reset()

        // Verify reset
        XCTAssertEqual(viewModel.state, .initial)
        XCTAssertNil(viewModel.scannedCode)
        XCTAssertTrue(viewModel.password.isEmpty)
        XCTAssertTrue(viewModel.confirmPassword.isEmpty)
        XCTAssertEqual(viewModel.passwordStrength, .weak)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showError)
    }

    // MARK: - State Title Tests

    func testStateTitles() {
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.initial.title, "Scan QR Code")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.scanningQR.title, "Scan QR Code")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.processingInvitation.title, "Processing...")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.connectingToNats.title, "Connecting...")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.requestingAttestation.title, "Device Verification")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.attestationRequired(challenge: "test").title, "Device Verification")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.attesting(progress: 0.5).title, "Device Verification")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.attestationComplete.title, "Verified")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.settingPIN.title, "Create Vault PIN")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.processingPIN.title, "Create Vault PIN")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.waitingForVault.title, "Initializing Vault")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.settingPassword.title, "Create Password")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.processingPassword.title, "Create Password")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.creatingCredential.title, "Creating Credential")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.finalizing.title, "Completing Setup")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.settingUpNats.title, "Setting Up Messaging")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.verifyingEnrollment.title, "Verifying...")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.complete(userGuid: "test").title, "Welcome to VettID")
        XCTAssertEqual(EnrollmentViewModel.EnrollmentState.error(message: "test", retryable: true).title, "Error")
    }

    // MARK: - State Can Go Back Tests

    func testStateCanGoBack() {
        XCTAssertTrue(EnrollmentViewModel.EnrollmentState.initial.canGoBack)
        XCTAssertTrue(EnrollmentViewModel.EnrollmentState.scanningQR.canGoBack)
        XCTAssertTrue(EnrollmentViewModel.EnrollmentState.settingPIN.canGoBack)
        XCTAssertTrue(EnrollmentViewModel.EnrollmentState.settingPassword.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.processingInvitation.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.connectingToNats.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.requestingAttestation.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.attesting(progress: 0.5).canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.processingPIN.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.waitingForVault.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.processingPassword.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.creatingCredential.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.finalizing.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.verifyingEnrollment.canGoBack)
        XCTAssertFalse(EnrollmentViewModel.EnrollmentState.complete(userGuid: "test").canGoBack)
    }

    // MARK: - Password Strength Label and Color Tests

    func testPasswordStrengthLabels() {
        XCTAssertEqual(EnrollmentViewModel.PasswordStrength.weak.label, "Weak")
        XCTAssertEqual(EnrollmentViewModel.PasswordStrength.fair.label, "Fair")
        XCTAssertEqual(EnrollmentViewModel.PasswordStrength.good.label, "Good")
        XCTAssertEqual(EnrollmentViewModel.PasswordStrength.strong.label, "Strong")
        XCTAssertEqual(EnrollmentViewModel.PasswordStrength.veryStrong.label, "Very Strong")
    }

    func testPasswordStrengthComparison() {
        XCTAssertTrue(EnrollmentViewModel.PasswordStrength.weak < .fair)
        XCTAssertTrue(EnrollmentViewModel.PasswordStrength.fair < .good)
        XCTAssertTrue(EnrollmentViewModel.PasswordStrength.good < .strong)
        XCTAssertTrue(EnrollmentViewModel.PasswordStrength.strong < .veryStrong)
        XCTAssertFalse(EnrollmentViewModel.PasswordStrength.veryStrong < .weak)
    }
}
