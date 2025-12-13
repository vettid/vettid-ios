import Foundation

/// Actor for handling request/response correlation with the vault
///
/// This actor manages pending requests and matches incoming responses
/// to their corresponding requests using request IDs.
actor VaultResponseHandler {

    // MARK: - Types

    typealias ResponseContinuation = CheckedContinuation<VaultEventResponse, Error>

    // MARK: - Properties

    private let vaultEventClient: VaultEventClient
    private var pendingRequests: [String: ResponseContinuation] = [:]
    private var responseTask: Task<Void, Never>?

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultEventClient: VaultEventClient) {
        self.vaultEventClient = vaultEventClient
    }

    // MARK: - Start/Stop

    /// Start listening for responses
    func startListening() async {
        guard responseTask == nil else { return }

        responseTask = Task {
            do {
                let responseStream = try await vaultEventClient.subscribeToResponses()

                for await response in responseStream {
                    handleResponse(response)
                }
            } catch {
                // Log error but keep handler running
                print("VaultResponseHandler: Failed to subscribe to responses: \(error)")
            }
        }
    }

    /// Stop listening for responses
    func stopListening() {
        responseTask?.cancel()
        responseTask = nil

        // Cancel all pending requests
        for (requestId, continuation) in pendingRequests {
            continuation.resume(throwing: VaultResponseError.handlerStopped)
            pendingRequests.removeValue(forKey: requestId)
        }
    }

    // MARK: - Request Submission

    /// Submit an event and await the response
    func submitAndAwait(
        _ event: VaultEventType,
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        let requestId = try await vaultEventClient.submitEvent(event)
        return try await awaitResponse(forRequestId: requestId, timeout: timeout ?? defaultTimeout)
    }

    /// Submit raw event data and await the response
    func submitRawAndAwait(
        type: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        let requestId = try await vaultEventClient.submitRawEvent(type: type, payload: payload)
        return try await awaitResponse(forRequestId: requestId, timeout: timeout ?? defaultTimeout)
    }

    // MARK: - Fire and Forget

    /// Submit an event without waiting for a response
    func submitFireAndForget(_ event: VaultEventType) async throws -> String {
        try await vaultEventClient.submitEvent(event)
    }

    // MARK: - Pending Request Management

    /// Get count of pending requests
    var pendingRequestCount: Int {
        pendingRequests.count
    }

    /// Check if a request is pending
    func isRequestPending(_ requestId: String) -> Bool {
        pendingRequests[requestId] != nil
    }

    /// Cancel a pending request
    func cancelRequest(_ requestId: String) {
        if let continuation = pendingRequests.removeValue(forKey: requestId) {
            continuation.resume(throwing: VaultResponseError.cancelled)
        }
    }

    // MARK: - Private Methods

    private func awaitResponse(forRequestId requestId: String, timeout: TimeInterval) async throws -> VaultEventResponse {
        try await withCheckedThrowingContinuation { (continuation: ResponseContinuation) in
            // Register the pending request
            pendingRequests[requestId] = continuation

            // Start timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.handleTimeout(requestId: requestId)
            }
        }
    }

    private func handleResponse(_ response: VaultEventResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestId) else {
            // No pending request for this response - might be fire-and-forget or timed out
            return
        }

        continuation.resume(returning: response)
    }

    private func handleTimeout(requestId: String) {
        guard let continuation = pendingRequests.removeValue(forKey: requestId) else {
            // Already handled or cancelled
            return
        }

        continuation.resume(throwing: VaultResponseError.timeout)
    }

    deinit {
        responseTask?.cancel()
    }
}

// MARK: - Errors

enum VaultResponseError: LocalizedError {
    case timeout
    case cancelled
    case handlerStopped
    case eventSubmissionFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Request timed out waiting for vault response"
        case .cancelled:
            return "Request was cancelled"
        case .handlerStopped:
            return "Response handler was stopped"
        case .eventSubmissionFailed(let reason):
            return "Failed to submit event: \(reason)"
        case .invalidResponse:
            return "Received invalid response from vault"
        }
    }
}

// MARK: - Convenience Extensions

extension VaultResponseHandler {

    /// Execute a handler in the vault and wait for the result
    func executeHandler(
        handlerId: String,
        payload: [String: Any],
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        let anyCodablePayload = payload.compactMapValues { AnyCodableValue($0) }
        return try await submitRawAndAwait(
            type: "handler.execute",
            payload: [
                "handler_id": AnyCodableValue(handlerId),
                "payload": AnyCodableValue(anyCodablePayload)
            ],
            timeout: timeout
        )
    }

    /// Send a message through the vault
    func sendMessage(
        recipient: String,
        content: String,
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        try await submitAndAwait(
            .sendMessage(recipient: recipient, content: content),
            timeout: timeout
        )
    }

    /// Retrieve a secret from the vault
    func retrieveSecret(
        secretId: String,
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        try await submitAndAwait(
            .retrieveSecret(secretId: secretId),
            timeout: timeout
        )
    }

    /// Store a secret in the vault
    func storeSecret(
        secretId: String,
        data: Data,
        timeout: TimeInterval? = nil
    ) async throws -> VaultEventResponse {
        try await submitAndAwait(
            .storeSecret(secretId: secretId, data: data),
            timeout: timeout
        )
    }
}
