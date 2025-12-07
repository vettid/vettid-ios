import Foundation
import SwiftUI

/// Manages NATS account setup and connection state
@MainActor
final class NatsSetupViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var setupState: SetupState = .initial
    @Published private(set) var accountInfo: NatsAccountInfo?
    @Published var showError: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let connectionManager: NatsConnectionManager
    private let credentialStore: NatsCredentialStore

    // MARK: - State Enum

    enum SetupState: Equatable {
        case initial
        case checkingStatus
        case creatingAccount
        case generatingToken
        case connecting
        case connected(NatsAccountStatus)
        case error(String)

        var title: String {
            switch self {
            case .initial: return "NATS Setup"
            case .checkingStatus: return "Checking Status..."
            case .creatingAccount: return "Creating Account..."
            case .generatingToken: return "Generating Token..."
            case .connecting: return "Connecting..."
            case .connected: return "Connected"
            case .error: return "Error"
            }
        }

        var isProcessing: Bool {
            switch self {
            case .checkingStatus, .creatingAccount, .generatingToken, .connecting:
                return true
            default:
                return false
            }
        }

        static func == (lhs: SetupState, rhs: SetupState) -> Bool {
            switch (lhs, rhs) {
            case (.initial, .initial),
                 (.checkingStatus, .checkingStatus),
                 (.creatingAccount, .creatingAccount),
                 (.generatingToken, .generatingToken),
                 (.connecting, .connecting):
                return true
            case (.connected(let a), .connected(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        connectionManager: NatsConnectionManager = NatsConnectionManager(),
        credentialStore: NatsCredentialStore = NatsCredentialStore()
    ) {
        self.apiClient = apiClient
        self.connectionManager = connectionManager
        self.credentialStore = credentialStore
    }

    // MARK: - Setup Flow

    /// Start the NATS setup flow
    func setupNats(authToken: String) async {
        do {
            // Step 1: Check if account exists
            setupState = .checkingStatus
            let status = try await apiClient.getNatsStatus(authToken: authToken)

            if status.hasAccount, let account = status.account {
                accountInfo = account
                // Account exists, just connect
                try await connectWithExistingAccount(authToken: authToken)
            } else {
                // Create new account
                try await createAccountAndConnect(authToken: authToken)
            }

        } catch {
            handleError(error)
        }
    }

    /// Create NATS account and connect
    private func createAccountAndConnect(authToken: String) async throws {
        // Step 1: Create account
        setupState = .creatingAccount
        let accountResponse = try await apiClient.createNatsAccount(authToken: authToken)

        accountInfo = NatsAccountInfo(
            ownerSpaceId: accountResponse.ownerSpaceId,
            messageSpaceId: accountResponse.messageSpaceId,
            status: accountResponse.status,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        try credentialStore.saveAccountInfo(accountInfo!)

        // Step 2: Generate token
        setupState = .generatingToken
        let tokenResponse = try await apiClient.generateNatsToken(
            request: .app(deviceId: getDeviceId()),
            authToken: authToken
        )

        let credentials = NatsCredentials(from: tokenResponse)
        try credentialStore.saveCredentials(credentials)

        // Step 3: Connect
        setupState = .connecting
        try await connectionManager.connect(authToken: authToken)

        // Success
        setupState = .connected(NatsAccountStatus(
            ownerSpaceId: accountResponse.ownerSpaceId,
            messageSpaceId: accountResponse.messageSpaceId,
            isConnected: true
        ))
    }

    /// Connect using existing account
    private func connectWithExistingAccount(authToken: String) async throws {
        // Check if we need new credentials
        if connectionManager.credentialsNeedRefresh() {
            setupState = .generatingToken
            _ = try await connectionManager.refreshCredentials(authToken: authToken)
        }

        setupState = .connecting
        try await connectionManager.connect(authToken: authToken)

        setupState = .connected(NatsAccountStatus(
            ownerSpaceId: accountInfo?.ownerSpaceId ?? "",
            messageSpaceId: accountInfo?.messageSpaceId ?? "",
            isConnected: true
        ))
    }

    /// Disconnect from NATS
    func disconnect() async {
        await connectionManager.disconnect()
        setupState = .initial
    }

    /// Retry after error
    func retry(authToken: String) async {
        setupState = .initial
        await setupNats(authToken: authToken)
    }

    /// Reset state
    func reset() {
        setupState = .initial
        accountInfo = nil
        errorMessage = nil
        showError = false
    }

    // MARK: - Private Helpers

    private func handleError(_ error: Error) {
        let message: String
        if let apiError = error as? APIError {
            message = apiError.errorDescription ?? "Unknown API error"
        } else if let natsError = error as? NatsConnectionError {
            message = natsError.errorDescription ?? "Connection error"
        } else {
            message = error.localizedDescription
        }

        errorMessage = message
        showError = true
        setupState = .error(message)
    }

    private func getDeviceId() -> String {
        let key = "com.vettid.device_id"
        if let deviceId = UserDefaults.standard.string(forKey: key) {
            return deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Account Status

struct NatsAccountStatus: Equatable {
    let ownerSpaceId: String
    let messageSpaceId: String
    let isConnected: Bool

    var ownerSpaceShortId: String {
        String(ownerSpaceId.prefix(20)) + "..."
    }
}
