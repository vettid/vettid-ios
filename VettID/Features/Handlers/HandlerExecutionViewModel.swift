import Foundation
import Combine

/// ViewModel for executing handlers
@MainActor
final class HandlerExecutionViewModel: ObservableObject {

    // MARK: - Published State

    @Published var inputValues: [String: String] = [:]
    @Published private(set) var isExecuting: Bool = false
    @Published private(set) var result: ExecuteHandlerResponse? = nil
    @Published var errorMessage: String? = nil

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Configuration

    private let defaultTimeoutMs = 30000

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Execution

    /// Execute the handler with current input values
    func execute(handlerId: String) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isExecuting = true
        errorMessage = nil
        result = nil

        do {
            // Convert string values to AnyCodableValue
            let input = inputValues.mapValues { AnyCodableValue($0) }

            let response = try await apiClient.executeHandler(
                handlerId: handlerId,
                input: input,
                timeoutMs: defaultTimeoutMs,
                authToken: authToken
            )

            result = response

            if response.status == "error" {
                errorMessage = response.error ?? "Execution failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isExecuting = false
    }

    // MARK: - Input Management

    /// Set a value for an input field
    func setValue(_ value: String, forKey key: String) {
        inputValues[key] = value
    }

    /// Get a value for an input field
    func getValue(forKey key: String) -> String {
        inputValues[key] ?? ""
    }

    /// Clear all input values
    func clearInputs() {
        inputValues.removeAll()
    }

    /// Clear the result
    func clearResult() {
        result = nil
        errorMessage = nil
    }

    // MARK: - Helpers

    /// Check if execution was successful
    var isSuccess: Bool {
        result?.status == "success"
    }

    /// Check if execution failed
    var isError: Bool {
        result?.status == "error" || result?.status == "timeout"
    }
}
