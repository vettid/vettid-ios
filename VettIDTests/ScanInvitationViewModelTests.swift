import XCTest
@testable import VettID

/// Tests for ScanInvitationViewModel
@MainActor
final class ScanInvitationViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        if case .scanning = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected scanning state")
        }
        XCTAssertTrue(viewModel.manualCode.isEmpty)
    }

    // MARK: - QR Code Parsing

    func testOnQrCodeScanned_deepLink() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("vettid://invite/ABC123")

        if case .preview(let code, _) = viewModel.state {
            XCTAssertEqual(code, "ABC123")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnQrCodeScanned_webUrl() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("https://vettid.com/invite/XYZ789")

        if case .preview(let code, _) = viewModel.state {
            XCTAssertEqual(code, "XYZ789")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnQrCodeScanned_rawCode() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("RAWCODE123")

        if case .preview(let code, _) = viewModel.state {
            XCTAssertEqual(code, "RAWCODE123")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnQrCodeScanned_emptyCode() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("")

        if case .error(let message) = viewModel.state {
            XCTAssertTrue(message.contains("Invalid"))
        } else {
            XCTFail("Expected error state for empty code")
        }
    }

    // MARK: - Manual Code Entry

    func testSubmitManualCode_valid() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })
        viewModel.manualCode = "MANUAL123"

        viewModel.submitManualCode()

        if case .preview(let code, _) = viewModel.state {
            XCTAssertEqual(code, "MANUAL123")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testSubmitManualCode_empty() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })
        viewModel.manualCode = "   "

        viewModel.submitManualCode()

        // Should remain in scanning state
        if case .scanning = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected scanning state for empty manual code")
        }
    }

    // MARK: - Accept Invitation

    func testAcceptInvitation_noAuthToken() async {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { nil })

        // First set a code
        viewModel.onQrCodeScanned("TEST123")

        await viewModel.acceptInvitation()

        if case .error(let message) = viewModel.state {
            XCTAssertEqual(message, "Not authenticated")
        } else {
            XCTFail("Expected error state")
        }
    }

    func testAcceptInvitation_notInPreviewState() async {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        // Don't set a code, stay in scanning state
        await viewModel.acceptInvitation()

        // Should remain in scanning state
        if case .scanning = viewModel.state {
            // Expected - no state change
        } else {
            XCTFail("Expected scanning state when not in preview")
        }
    }

    // MARK: - Reset

    func testReset() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        // Put into preview state
        viewModel.onQrCodeScanned("TEST123")
        viewModel.manualCode = "some code"

        // Reset
        viewModel.reset()

        if case .scanning = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected scanning state after reset")
        }
        XCTAssertTrue(viewModel.manualCode.isEmpty)
    }
}
