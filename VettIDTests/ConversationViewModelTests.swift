import XCTest
@testable import VettID

/// Tests for ConversationViewModel
@MainActor
final class ConversationViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.connectionName.isEmpty)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Grouped Messages

    func testGroupedMessages_empty() {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })

        XCTAssertTrue(viewModel.groupedMessages.isEmpty)
    }

    // MARK: - Load Messages

    func testLoadMessages_noAuthToken() async {
        let viewModel = ConversationViewModel(authTokenProvider: { nil })
        viewModel.connectionId = "test-connection"

        await viewModel.loadMessages()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "Not authenticated")
    }

    func testLoadMessages_noConnectionId() async {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })
        // connectionId not set

        await viewModel.loadMessages()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "No connection specified")
    }

    // MARK: - Send Message

    func testSendMessage_emptyContent() async {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })
        viewModel.connectionId = "test-connection"

        await viewModel.sendMessage("")

        // Should not send empty message
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSendMessage_whitespaceOnly() async {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })
        viewModel.connectionId = "test-connection"

        await viewModel.sendMessage("   \n  ")

        // Should not send whitespace-only message
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSendMessage_noAuthToken() async {
        let viewModel = ConversationViewModel(authTokenProvider: { nil })
        viewModel.connectionId = "test-connection"

        await viewModel.sendMessage("Hello")

        XCTAssertEqual(viewModel.errorMessage, "Not authenticated")
    }

    // MARK: - Error Handling

    func testClearError() {
        let viewModel = ConversationViewModel(authTokenProvider: { "test-token" })
        viewModel.errorMessage = "Test error"

        viewModel.clearError()

        XCTAssertNil(viewModel.errorMessage)
    }
}
