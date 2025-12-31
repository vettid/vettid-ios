import XCTest
@testable import VettID

/// Tests for ProfileViewModel
@MainActor
final class ProfileViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let viewModel = ProfileViewModel(authTokenProvider: { "test-token" })

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.profile)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isPublishing)
    }

    // MARK: - State Transitions

    func testLoadProfile_noAuthToken() async {
        let viewModel = ProfileViewModel(authTokenProvider: { nil })

        await viewModel.loadProfile()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "Not authenticated")
    }

    func testUpdateProfile_noAuthToken() async {
        let viewModel = ProfileViewModel(authTokenProvider: { nil })

        let profile = Profile(
            guid: "test-guid",
            displayName: "Test User",
            avatarUrl: nil,
            bio: nil,
            location: nil,
            lastUpdated: Date()
        )

        await viewModel.updateProfile(profile)

        XCTAssertEqual(viewModel.errorMessage, "Not authenticated")
    }

    func testPublishProfile_noProfile() async {
        let viewModel = ProfileViewModel(authTokenProvider: { "test-token" })

        await viewModel.publishProfile()

        // Should not publish if no profile loaded
        XCTAssertFalse(viewModel.isPublishing)
    }

}
