import XCTest
@testable import VettID

/// Tests for ConnectionsViewModel
@MainActor
final class ConnectionsViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let viewModel = ConnectionsViewModel(authTokenProvider: { "test-token" })

        if case .loading = viewModel.state {
            // Expected initial state
        } else {
            XCTFail("Expected loading state, got \(viewModel.state)")
        }
        XCTAssertTrue(viewModel.searchQuery.isEmpty)
    }

    // MARK: - Filtering

    func testFilteredConnections_emptySearch() {
        let viewModel = ConnectionsViewModel(authTokenProvider: { "test-token" })
        viewModel.searchQuery = ""

        // Filtered connections should return all when search is empty
        let filtered = viewModel.filteredConnections
        XCTAssertTrue(filtered.isEmpty) // No connections loaded yet
    }

    func testFilteredConnections_withSearch() {
        let viewModel = ConnectionsViewModel(authTokenProvider: { "test-token" })
        viewModel.searchQuery = "test"

        // Should filter based on search query
        let filtered = viewModel.filteredConnections
        XCTAssertTrue(filtered.isEmpty) // No connections loaded
    }

    // MARK: - State Transitions

    func testStateTransition_noAuthToken() async {
        let viewModel = ConnectionsViewModel(authTokenProvider: { nil })

        await viewModel.loadConnections()

        if case .error(let message) = viewModel.state {
            XCTAssertEqual(message, "Not authenticated")
        } else {
            XCTFail("Expected error state")
        }
    }
}
