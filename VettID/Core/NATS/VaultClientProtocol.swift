import Foundation

// MARK: - Vault Client Protocol

/// Protocol for NATS-based vault clients that use the OwnerSpaceClient
/// request-response pattern. Provides a shared `sendAndAwait` implementation
/// to eliminate boilerplate across WalletClient, MigrationClient, FeedClient, etc.
protocol VaultClientProtocol {
    var ownerSpaceClient: OwnerSpaceClient { get }
    var clientName: String { get }
}

extension VaultClientProtocol {
    /// Send a request to the vault and await the response with error handling.
    /// Shared implementation used by all vault clients.
    func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[\(clientName)] Sending \(messageType) request via OwnerSpaceClient")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout
        )

        guard response.success else {
            let error = response.error ?? "Request failed"
            #if DEBUG
            print("[\(clientName)] \(messageType) failed: \(error)")
            #endif
            throw VaultClientError.requestFailed(
                clientName: clientName,
                messageType: messageType,
                error: error,
                errorCode: response.errorCode
            )
        }

        #if DEBUG
        print("[\(clientName)] \(messageType) response received")
        #endif

        return response
    }
}

// MARK: - Shared Error Type

enum VaultClientError: LocalizedError {
    case requestFailed(clientName: String, messageType: String, error: String, errorCode: String?)
    case invalidResponse(clientName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let client, let messageType, let error, let errorCode):
            if let code = errorCode {
                return "\(client) request '\(messageType)' failed [\(code)]: \(error)"
            }
            return "\(client) request '\(messageType)' failed: \(error)"
        case .invalidResponse(let client, let reason):
            return "\(client) invalid response: \(reason)"
        }
    }
}
