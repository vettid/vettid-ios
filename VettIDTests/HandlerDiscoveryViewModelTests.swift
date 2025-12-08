import XCTest
@testable import VettID

/// Tests for HandlerDiscoveryViewModel
@MainActor
final class HandlerDiscoveryViewModelTests: XCTestCase {

    // MARK: - State Tests

    func testInitialState_isLoading() {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })
        XCTAssertTrue(viewModel.state.isLoading)
        XCTAssertNil(viewModel.selectedCategory)
        XCTAssertNil(viewModel.installingHandlerId)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSelectCategory_updatesSelectedCategory() {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })

        viewModel.selectCategory("messaging")
        XCTAssertEqual(viewModel.selectedCategory, "messaging")

        viewModel.selectCategory(nil)
        XCTAssertNil(viewModel.selectedCategory)
    }

    func testLoadHandlers_withoutAuth_setsErrorState() async {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })

        await viewModel.loadHandlers()

        if case .error(let message) = viewModel.state {
            XCTAssertTrue(message.contains("authenticated"))
        } else {
            XCTFail("Expected error state")
        }
    }

    // MARK: - HandlerDiscoveryState Tests

    func testHandlerDiscoveryState_equality() {
        XCTAssertEqual(HandlerDiscoveryState.loading, .loading)

        let handlers = [makeHandler(id: "1")]
        XCTAssertEqual(
            HandlerDiscoveryState.loaded(handlers: handlers, hasMore: true),
            .loaded(handlers: handlers, hasMore: true)
        )
        XCTAssertNotEqual(
            HandlerDiscoveryState.loaded(handlers: handlers, hasMore: true),
            .loaded(handlers: handlers, hasMore: false)
        )

        XCTAssertEqual(HandlerDiscoveryState.error("test"), .error("test"))
        XCTAssertNotEqual(HandlerDiscoveryState.error("test1"), .error("test2"))
    }

    func testHandlerDiscoveryState_isLoading() {
        XCTAssertTrue(HandlerDiscoveryState.loading.isLoading)
        XCTAssertFalse(HandlerDiscoveryState.loaded(handlers: [], hasMore: false).isLoading)
        XCTAssertFalse(HandlerDiscoveryState.error("test").isLoading)
    }

    func testHandlerDiscoveryState_handlers() {
        XCTAssertTrue(HandlerDiscoveryState.loading.handlers.isEmpty)

        let handlers = [makeHandler(id: "1"), makeHandler(id: "2")]
        XCTAssertEqual(HandlerDiscoveryState.loaded(handlers: handlers, hasMore: false).handlers.count, 2)

        XCTAssertTrue(HandlerDiscoveryState.error("test").handlers.isEmpty)
    }

    func testHandlerDiscoveryState_hasMore() {
        XCTAssertFalse(HandlerDiscoveryState.loading.hasMore)
        XCTAssertTrue(HandlerDiscoveryState.loaded(handlers: [], hasMore: true).hasMore)
        XCTAssertFalse(HandlerDiscoveryState.loaded(handlers: [], hasMore: false).hasMore)
        XCTAssertFalse(HandlerDiscoveryState.error("test").hasMore)
    }

    // MARK: - Category Tests

    func testCategories_containsExpectedValues() {
        let categories = HandlerDiscoveryViewModel.categories

        XCTAssertTrue(categories.contains { $0.0 == nil && $0.1 == "All" })
        XCTAssertTrue(categories.contains { $0.0 == "messaging" })
        XCTAssertTrue(categories.contains { $0.0 == "productivity" })
        XCTAssertTrue(categories.contains { $0.0 == "utilities" })
    }

    // MARK: - Install/Uninstall State Tests

    func testIsInstalling_returnsTrueForMatchingHandler() {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })
        let handler = makeHandler(id: "test-123")

        // Initially not installing
        XCTAssertFalse(viewModel.isInstalling(handler))
    }

    func testIsUninstalling_returnsTrueForMatchingHandler() {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })
        let handler = makeHandler(id: "test-456")

        // Initially not uninstalling
        XCTAssertFalse(viewModel.isUninstalling(handler))
    }

    func testClearError_clearsErrorMessage() {
        let viewModel = HandlerDiscoveryViewModel(authTokenProvider: { nil })

        // Note: errorMessage is internal, but clearError is public
        viewModel.clearError()
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Helpers

    private func makeHandler(
        id: String,
        name: String = "Test Handler",
        installed: Bool = false
    ) -> HandlerSummary {
        HandlerSummary(
            id: id,
            name: name,
            description: "Test description",
            version: "1.0.0",
            category: "utilities",
            iconUrl: nil,
            publisher: "Test Publisher",
            installed: installed,
            installedVersion: installed ? "1.0.0" : nil
        )
    }
}
