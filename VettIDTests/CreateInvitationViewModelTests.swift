import XCTest
@testable import VettID

/// Tests for CreateInvitationViewModel
@MainActor
final class CreateInvitationViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { "test-token" })

        if case .idle = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected idle state")
        }
        XCTAssertEqual(viewModel.expirationMinutes, 60)
    }

    // MARK: - State Transitions

    func testCreateInvitation_noAuthToken() async {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { nil })

        await viewModel.createInvitation()

        if case .error(let message) = viewModel.state {
            XCTAssertEqual(message, "Not authenticated")
        } else {
            XCTFail("Expected error state")
        }
    }

    // MARK: - Computed Properties

    func testInvitationCode_nilWhenIdle() {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { "test-token" })

        XCTAssertNil(viewModel.invitationCode)
    }

    func testQrCodeData_nilWhenIdle() {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { "test-token" })

        XCTAssertNil(viewModel.qrCodeData)
    }

    func testDeepLinkUrl_nilWhenIdle() {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { "test-token" })

        XCTAssertNil(viewModel.deepLinkUrl)
    }

    // MARK: - Reset

    func testReset() async {
        let viewModel = CreateInvitationViewModel(authTokenProvider: { nil })

        // Put into error state
        await viewModel.createInvitation()

        // Reset
        viewModel.reset()

        if case .idle = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected idle state after reset")
        }
    }
}
