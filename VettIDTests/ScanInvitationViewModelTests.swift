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
    }

    // MARK: - QR Code Parsing

    func testOnQrCodeScanned_deepLink() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("vettid://invite/ABC123")

        if case .preview(let info) = viewModel.state {
            XCTAssertEqual(info.code, "ABC123")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnQrCodeScanned_webUrl() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("https://vettid.com/invite/XYZ789")

        if case .preview(let info) = viewModel.state {
            XCTAssertEqual(info.code, "XYZ789")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnQrCodeScanned_rawCode() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onQrCodeScanned("RAWCODE123")

        if case .preview(let info) = viewModel.state {
            XCTAssertEqual(info.code, "RAWCODE123")
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

    func testOnManualCodeEntered_valid() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onManualCodeEntered("MANUAL123")

        if case .preview(let info) = viewModel.state {
            XCTAssertEqual(info.code, "MANUAL123")
        } else {
            XCTFail("Expected preview state")
        }
    }

    func testOnManualCodeEntered_empty() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        viewModel.onManualCodeEntered("   ")

        // Should show error for empty code
        if case .error(let message) = viewModel.state {
            XCTAssertTrue(message.contains("enter"))
        } else {
            XCTFail("Expected error state for empty manual code")
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

        // Should be in error state because no code was scanned
        if case .error(let message) = viewModel.state {
            XCTAssertEqual(message, "No invitation code")
        } else {
            XCTFail("Expected error state when no code was scanned")
        }
    }

    // MARK: - Reset

    func testReset() {
        let viewModel = ScanInvitationViewModel(authTokenProvider: { "test-token" })

        // Put into preview state
        viewModel.onQrCodeScanned("TEST123")

        // Reset
        viewModel.reset()

        if case .scanning = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected scanning state after reset")
        }
    }
}
