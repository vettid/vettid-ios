import XCTest
@testable import VettID

final class RecoveryQRCodeTests: XCTestCase {

    // MARK: - Valid QR Code Tests

    func testParseValidQRCode() {
        let qrString = """
        {
            "type": "vettid_recovery",
            "token": "recovery-token-12345",
            "vault": "nats://vault.vettid.dev:4222",
            "nonce": "random-nonce-abc123"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNotNil(qrCode)
        XCTAssertEqual(qrCode?.type, "vettid_recovery")
        XCTAssertEqual(qrCode?.token, "recovery-token-12345")
        XCTAssertEqual(qrCode?.vault, "nats://vault.vettid.dev:4222")
        XCTAssertEqual(qrCode?.nonce, "random-nonce-abc123")
        XCTAssertTrue(qrCode?.isValid ?? false)
    }

    func testParseValidQRCodeWithExpiration() {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let qrString = """
        {
            "type": "vettid_recovery",
            "token": "recovery-token-12345",
            "vault": "nats://vault.vettid.dev:4222",
            "nonce": "random-nonce-abc123",
            "expires_at": "\(futureDate)"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNotNil(qrCode)
        XCTAssertTrue(qrCode?.isValid ?? false)
        XCTAssertNotNil(qrCode?.expiresAt)
    }

    // MARK: - Invalid QR Code Tests

    func testParseInvalidType() {
        let qrString = """
        {
            "type": "other_type",
            "token": "recovery-token-12345",
            "vault": "nats://vault.vettid.dev:4222",
            "nonce": "random-nonce-abc123"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNil(qrCode, "QR code with wrong type should return nil")
    }

    func testParseEmptyToken() {
        let qrString = """
        {
            "type": "vettid_recovery",
            "token": "",
            "vault": "nats://vault.vettid.dev:4222",
            "nonce": "random-nonce-abc123"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNil(qrCode, "QR code with empty token should return nil")
    }

    func testParseExpiredQRCode() {
        let pastDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let qrString = """
        {
            "type": "vettid_recovery",
            "token": "recovery-token-12345",
            "vault": "nats://vault.vettid.dev:4222",
            "nonce": "random-nonce-abc123",
            "expires_at": "\(pastDate)"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNil(qrCode, "Expired QR code should return nil")
    }

    func testParseInvalidJSON() {
        let qrString = "not-valid-json"

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNil(qrCode)
    }

    func testParseMissingFields() {
        let qrString = """
        {
            "type": "vettid_recovery",
            "token": "recovery-token-12345"
        }
        """

        let qrCode = RecoveryQRCode.parse(from: qrString)

        XCTAssertNil(qrCode, "QR code missing required fields should return nil")
    }

    // MARK: - Validation Tests

    func testIsValidWithAllFields() {
        let qrCode = RecoveryQRCode(
            type: "vettid_recovery",
            token: "token",
            vault: "vault",
            nonce: "nonce",
            expiresAt: nil
        )

        XCTAssertTrue(qrCode.isValid)
    }

    func testIsValidWithWrongType() {
        let qrCode = RecoveryQRCode(
            type: "wrong_type",
            token: "token",
            vault: "vault",
            nonce: "nonce",
            expiresAt: nil
        )

        XCTAssertFalse(qrCode.isValid)
    }

    func testIsValidWithEmptyVault() {
        let qrCode = RecoveryQRCode(
            type: "vettid_recovery",
            token: "token",
            vault: "",
            nonce: "nonce",
            expiresAt: nil
        )

        XCTAssertFalse(qrCode.isValid)
    }

    func testIsValidWithFutureExpiration() {
        let qrCode = RecoveryQRCode(
            type: "vettid_recovery",
            token: "token",
            vault: "vault",
            nonce: "nonce",
            expiresAt: Date().addingTimeInterval(3600)
        )

        XCTAssertTrue(qrCode.isValid)
    }

    func testIsValidWithPastExpiration() {
        let qrCode = RecoveryQRCode(
            type: "vettid_recovery",
            token: "token",
            vault: "vault",
            nonce: "nonce",
            expiresAt: Date().addingTimeInterval(-3600)
        )

        XCTAssertFalse(qrCode.isValid)
    }
}

// MARK: - Recovery Error Tests

final class RecoveryErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(RecoveryError.invalidQRCode.errorDescription)
        XCTAssertNotNil(RecoveryError.qrCodeExpired.errorDescription)
        XCTAssertNotNil(RecoveryError.tokenExchangeFailed("test").errorDescription)
        XCTAssertNotNil(RecoveryError.credentialSaveFailed.errorDescription)
        XCTAssertNotNil(RecoveryError.networkError.errorDescription)
        XCTAssertNotNil(RecoveryError.cancelled.errorDescription)
    }

    func testTokenExchangeFailedIncludesMessage() {
        let error = RecoveryError.tokenExchangeFailed("Custom error message")
        XCTAssertTrue(error.errorDescription?.contains("Custom error message") ?? false)
    }
}

// MARK: - Recovery State Tests

final class RecoveryStateTests: XCTestCase {

    func testStateEquality() {
        XCTAssertEqual(RecoveryState.idle, RecoveryState.idle)
        XCTAssertEqual(RecoveryState.scanning, RecoveryState.scanning)
        XCTAssertEqual(RecoveryState.completed(userGuid: "abc"), RecoveryState.completed(userGuid: "abc"))
        XCTAssertNotEqual(RecoveryState.completed(userGuid: "abc"), RecoveryState.completed(userGuid: "xyz"))
        XCTAssertEqual(RecoveryState.failed(error: .networkError), RecoveryState.failed(error: .networkError))
    }
}

// MARK: - RecoveryViewModel Tests

@MainActor
final class RecoveryViewModelTests: XCTestCase {

    func testInitialState() {
        let viewModel = RecoveryViewModel()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.scannedQRCode)
        XCTAssertTrue(viewModel.newPassword.isEmpty)
        XCTAssertTrue(viewModel.confirmPassword.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStartScanning() {
        let viewModel = RecoveryViewModel()

        viewModel.startScanning()

        XCTAssertEqual(viewModel.state, .scanning)
    }

    func testHandleValidQRCode() {
        let viewModel = RecoveryViewModel()
        let validQR = """
        {
            "type": "vettid_recovery",
            "token": "token",
            "vault": "vault",
            "nonce": "nonce"
        }
        """

        viewModel.handleScannedCode(validQR)

        XCTAssertEqual(viewModel.state, .enteringPassword)
        XCTAssertNotNil(viewModel.scannedQRCode)
    }

    func testHandleInvalidQRCode() {
        let viewModel = RecoveryViewModel()

        viewModel.handleScannedCode("invalid")

        XCTAssertEqual(viewModel.state, .failed(error: .invalidQRCode))
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testPasswordValidation() {
        let viewModel = RecoveryViewModel()

        // Empty password
        XCTAssertFalse(viewModel.canProceedWithPassword)

        // Too short
        viewModel.newPassword = "short"
        viewModel.confirmPassword = "short"
        XCTAssertFalse(viewModel.canProceedWithPassword)
        XCTAssertNotNil(viewModel.passwordError)

        // Mismatch
        viewModel.newPassword = "password123"
        viewModel.confirmPassword = "different123"
        XCTAssertFalse(viewModel.canProceedWithPassword)

        // Valid
        viewModel.newPassword = "password123"
        viewModel.confirmPassword = "password123"
        XCTAssertTrue(viewModel.canProceedWithPassword)
        XCTAssertNil(viewModel.passwordError)
    }

    func testCancelRecovery() {
        let viewModel = RecoveryViewModel()
        viewModel.startScanning()
        viewModel.newPassword = "test"

        viewModel.cancelRecovery()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.scannedQRCode)
        XCTAssertTrue(viewModel.newPassword.isEmpty)
    }

    func testRetryFromFailure() {
        let viewModel = RecoveryViewModel()
        viewModel.handleScannedCode("invalid")
        XCTAssertEqual(viewModel.state, .failed(error: .invalidQRCode))

        viewModel.retry()

        XCTAssertEqual(viewModel.state, .scanning)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRetryWithExistingQRCode() {
        let viewModel = RecoveryViewModel()
        let validQR = """
        {
            "type": "vettid_recovery",
            "token": "token",
            "vault": "vault",
            "nonce": "nonce"
        }
        """
        viewModel.handleScannedCode(validQR)

        // Simulate failure
        viewModel.errorMessage = "Test error"

        viewModel.retry()

        XCTAssertEqual(viewModel.state, .enteringPassword)
        XCTAssertNil(viewModel.errorMessage)
    }
}
