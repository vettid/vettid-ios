import XCTest
@testable import VettID

/// Tests for HandlerExecutionViewModel
@MainActor
final class HandlerExecutionViewModelTests: XCTestCase {

    // MARK: - State Tests

    func testInitialState() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })

        XCTAssertTrue(viewModel.inputValues.isEmpty)
        XCTAssertFalse(viewModel.isExecuting)
        XCTAssertNil(viewModel.result)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSetValue_updatesInputValues() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })

        viewModel.setValue("test value", forKey: "field1")
        XCTAssertEqual(viewModel.getValue(forKey: "field1"), "test value")

        viewModel.setValue("another", forKey: "field2")
        XCTAssertEqual(viewModel.getValue(forKey: "field2"), "another")
    }

    func testGetValue_returnsEmptyStringForMissingKey() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })
        XCTAssertEqual(viewModel.getValue(forKey: "nonexistent"), "")
    }

    func testClearInputs_removesAllValues() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })

        viewModel.setValue("value1", forKey: "key1")
        viewModel.setValue("value2", forKey: "key2")

        XCTAssertEqual(viewModel.inputValues.count, 2)

        viewModel.clearInputs()

        XCTAssertTrue(viewModel.inputValues.isEmpty)
    }

    func testClearResult_clearsResultAndError() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })

        viewModel.clearResult()

        XCTAssertNil(viewModel.result)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testExecute_withoutAuth_setsErrorMessage() async {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })

        await viewModel.execute(handlerId: "test-handler")

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage!.contains("authenticated"))
        XCTAssertFalse(viewModel.isExecuting)
    }

    // MARK: - Success/Error State Tests

    func testIsSuccess_returnsFalseWithNoResult() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })
        XCTAssertFalse(viewModel.isSuccess)
    }

    func testIsError_returnsFalseWithNoResult() {
        let viewModel = HandlerExecutionViewModel(authTokenProvider: { nil })
        XCTAssertFalse(viewModel.isError)
    }

    // MARK: - API Response Types Tests

    func testExecuteHandlerResponse_decoding_success() throws {
        let json = """
        {
            "request_id": "req-123",
            "status": "success",
            "output": {"result": "hello"},
            "error": null,
            "execution_time_ms": 42
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ExecuteHandlerResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.requestId, "req-123")
        XCTAssertEqual(response.status, "success")
        XCTAssertNotNil(response.output)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.executionTimeMs, 42)
    }

    func testExecuteHandlerResponse_decoding_error() throws {
        let json = """
        {
            "request_id": "req-456",
            "status": "error",
            "output": null,
            "error": "Handler execution failed",
            "execution_time_ms": 100
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ExecuteHandlerResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.requestId, "req-456")
        XCTAssertEqual(response.status, "error")
        XCTAssertNil(response.output)
        XCTAssertEqual(response.error, "Handler execution failed")
    }

    func testExecuteHandlerResponse_decoding_timeout() throws {
        let json = """
        {
            "request_id": "req-789",
            "status": "timeout",
            "output": null,
            "error": "Execution timed out after 30000ms",
            "execution_time_ms": 30000
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ExecuteHandlerResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "timeout")
        XCTAssertEqual(response.executionTimeMs, 30000)
    }
}
