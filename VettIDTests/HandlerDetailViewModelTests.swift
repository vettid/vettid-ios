import XCTest
@testable import VettID

/// Tests for HandlerDetailViewModel
@MainActor
final class HandlerDetailViewModelTests: XCTestCase {

    // MARK: - State Tests

    func testInitialState_isLoading() {
        let viewModel = HandlerDetailViewModel(authTokenProvider: { nil })
        XCTAssertTrue(viewModel.state.isLoading)
        XCTAssertFalse(viewModel.isInstalling)
        XCTAssertFalse(viewModel.isUninstalling)
        XCTAssertFalse(viewModel.showExecutionSheet)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadHandler_withoutAuth_setsErrorState() async {
        let viewModel = HandlerDetailViewModel(authTokenProvider: { nil })

        await viewModel.loadHandler("test-id")

        if case .error(let message) = viewModel.state {
            XCTAssertTrue(message.contains("authenticated"))
        } else {
            XCTFail("Expected error state")
        }
    }

    func testCurrentHandler_returnsNilWhenNotLoaded() {
        let viewModel = HandlerDetailViewModel(authTokenProvider: { nil })
        XCTAssertNil(viewModel.currentHandler)
    }

    func testClearError_clearsErrorMessage() {
        let viewModel = HandlerDetailViewModel(authTokenProvider: { nil })
        viewModel.clearError()
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - HandlerDetailState Tests

    func testHandlerDetailState_equality() {
        XCTAssertEqual(HandlerDetailState.loading, .loading)

        let handler1 = makeDetailResponse(id: "1", version: "1.0")
        let handler2 = makeDetailResponse(id: "1", version: "1.0")
        let handler3 = makeDetailResponse(id: "2", version: "1.0")

        XCTAssertEqual(HandlerDetailState.loaded(handler1), .loaded(handler2))
        XCTAssertNotEqual(HandlerDetailState.loaded(handler1), .loaded(handler3))

        XCTAssertEqual(HandlerDetailState.error("test"), .error("test"))
        XCTAssertNotEqual(HandlerDetailState.error("a"), .error("b"))
    }

    func testHandlerDetailState_isLoading() {
        XCTAssertTrue(HandlerDetailState.loading.isLoading)
        XCTAssertFalse(HandlerDetailState.loaded(makeDetailResponse()).isLoading)
        XCTAssertFalse(HandlerDetailState.error("test").isLoading)
    }

    // MARK: - Helpers

    private func makeDetailResponse(
        id: String = "test-id",
        version: String = "1.0.0"
    ) -> HandlerDetailResponse {
        HandlerDetailResponse(
            id: id,
            name: "Test Handler",
            description: "Test description",
            version: version,
            category: "utilities",
            iconUrl: nil,
            publisher: "Test Publisher",
            publishedAt: "2025-01-01T00:00:00Z",
            sizeBytes: 1024,
            permissions: [],
            inputSchema: [:],
            outputSchema: [:],
            changelog: nil,
            installed: false,
            installedVersion: nil
        )
    }
}
