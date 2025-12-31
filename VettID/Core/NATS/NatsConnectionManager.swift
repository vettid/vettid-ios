import Foundation
import Combine

/// Manages NATS connection lifecycle
@MainActor
final class NatsConnectionManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectionState: NatsConnectionState = .disconnected
    @Published private(set) var lastError: Error?
    @Published private(set) var isSessionEstablished: Bool = false

    // MARK: - Dependencies

    private let credentialStore: NatsCredentialStore
    private let apiClient: APIClient
    private let sessionKeyManager: SessionKeyManager

    // MARK: - Connection State

    private var natsClient: NatsClientWrapper?
    private var reconnectTask: Task<Void, Never>?
    private var subscriptions: [String: NatsSubscription] = [:]
    private var ownerSpaceId: String?

    // MARK: - Configuration

    private let maxReconnectAttempts = 5
    private let reconnectDelaySeconds: [Double] = [1, 2, 4, 8, 16] // Exponential backoff
    private let bootstrapTimeout: TimeInterval = 30

    /// Timeout for waiting for vault to start (30 seconds)
    private let vaultStartTimeout: TimeInterval = 30

    /// Poll interval when waiting for vault to become ready (5 seconds)
    private let vaultPollInterval: TimeInterval = 5

    // MARK: - Auto-Start Vault

    /// Provider for user GUID (needed for action-token vault lifecycle)
    private let userGuidProvider: () -> String?

    // MARK: - Initialization

    init(credentialStore: NatsCredentialStore = NatsCredentialStore(),
         apiClient: APIClient = APIClient(),
         sessionKeyManager: SessionKeyManager = SessionKeyManager(),
         userGuidProvider: @escaping () -> String? = { nil }) {
        self.credentialStore = credentialStore
        self.apiClient = apiClient
        self.sessionKeyManager = sessionKeyManager
        self.userGuidProvider = userGuidProvider
    }

    /// Get the session key manager for E2E operations
    var keyManager: SessionKeyManager {
        sessionKeyManager
    }

    // MARK: - Connection Management

    /// Connect to NATS using stored or refreshed credentials
    func connect(authToken: String) async throws {
        guard connectionState != .connected else { return }

        connectionState = .connecting
        lastError = nil

        do {
            // Get or refresh credentials
            var credentials = try credentialStore.getCredentials()

            if credentials == nil || credentials!.shouldRefresh {
                credentials = try await refreshCredentials(authToken: authToken)
            }

            guard let creds = credentials else {
                throw NatsConnectionError.noCredentials
            }

            // Create and connect NATS client
            natsClient = NatsClientWrapper(
                endpoint: creds.endpoint,
                jwt: creds.jwt,
                seed: creds.seed
            )

            try await natsClient?.connect()

            connectionState = .connected

            // Start monitoring connection
            startConnectionMonitoring()

        } catch {
            lastError = error
            connectionState = .error(error)
            throw error
        }
    }

    /// Connect to NATS using credentials from enrollment
    /// This is called after enrollment when credentials are provided in the enrollFinalize response
    func connectWithEnrollmentCredentials(_ credentials: NatsCredentials, ownerSpace: String? = nil) async throws {
        guard connectionState != .connected else { return }

        connectionState = .connecting
        lastError = nil

        do {
            // Store the credentials for future use
            try credentialStore.saveCredentials(credentials)

            // Store owner space ID for bootstrap
            self.ownerSpaceId = ownerSpace ?? credentials.ownerSpace

            // Create and connect NATS client
            natsClient = NatsClientWrapper(
                endpoint: credentials.endpoint,
                jwt: credentials.jwt,
                seed: credentials.seed
            )

            try await natsClient?.connect()

            connectionState = .connected

            // Start monitoring connection
            startConnectionMonitoring()

            #if DEBUG
            print("[NATS] Connected with enrollment credentials")
            print("[NATS] Endpoint: \(credentials.endpoint)")
            print("[NATS] OwnerSpace: \(ownerSpaceId ?? "unknown")")
            print("[NATS] JWT expires: \(credentials.expiresAt)")
            #endif

            // Perform E2E bootstrap if owner space is known
            if ownerSpaceId != nil {
                try await performBootstrap()
            }

        } catch {
            lastError = error
            connectionState = .error(error)
            throw error
        }
    }

    // MARK: - E2E Bootstrap

    /// Perform E2E session bootstrap with the vault
    /// This establishes encrypted communication after NATS connection
    func performBootstrap() async throws {
        guard connectionState == .connected else {
            throw NatsConnectionError.notConnected
        }

        guard let ownerSpace = ownerSpaceId else {
            throw NatsConnectionError.connectionFailed("No owner space ID for bootstrap")
        }

        // Check if we already have an active session
        if await sessionKeyManager.hasActiveSession {
            isSessionEstablished = true
            #if DEBUG
            print("[NATS] E2E session already established")
            #endif
            return
        }

        #if DEBUG
        print("[NATS] Starting E2E bootstrap...")
        #endif

        do {
            // Generate bootstrap request
            let bootstrapRequest = try await sessionKeyManager.initiateBootstrap()

            // Subscribe to bootstrap response topic
            // Subscribe with wildcard to receive response on forApp.app.bootstrap.{requestId}
            let responseTopic = "\(ownerSpace).forApp.app.bootstrap.>"
            let responseStream = try await subscribe(to: responseTopic)

            // Send bootstrap request
            let requestTopic = "\(ownerSpace).forVault.app.bootstrap"
            let requestData = try JSONEncoder().encode(bootstrapRequest)
            try await publish(requestData, to: requestTopic)

            // Wait for response with timeout
            let response = try await withThrowingTaskGroup(of: BootstrapResponse.self) { group in
                // Response listener task
                group.addTask {
                    for await message in responseStream {
                        if let response = try? JSONDecoder().decode(BootstrapResponse.self, from: message.data) {
                            if response.requestId == bootstrapRequest.requestId {
                                return response
                            }
                        }
                    }
                    throw NatsConnectionError.connectionFailed("Bootstrap response stream ended")
                }

                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.bootstrapTimeout * 1_000_000_000))
                    throw NatsConnectionError.connectionFailed("Bootstrap timed out")
                }

                // Return first result (response or timeout)
                guard let result = try await group.next() else {
                    throw NatsConnectionError.connectionFailed("Bootstrap failed")
                }

                group.cancelAll()
                return result
            }

            // Complete bootstrap key exchange
            try await sessionKeyManager.completeBootstrap(response: response)

            // Update credentials if provided in response
            if let newCreds = response.credentials {
                if let parsed = NatsCredentials(
                    fromCredsFileContent: newCreds,
                    endpoint: "", // Keep existing endpoint
                    ownerSpace: ownerSpace,
                    messageSpace: nil,
                    topics: nil
                ) {
                    try credentialStore.saveCredentials(parsed)
                }
            }

            isSessionEstablished = true

            #if DEBUG
            print("[NATS] E2E bootstrap complete, sessionId: \(response.sessionId)")
            #endif

        } catch {
            await sessionKeyManager.cancelBootstrap()
            throw error
        }
    }

    /// Clear E2E session (e.g., on logout)
    func clearSession() async {
        await sessionKeyManager.clearSession()
        isSessionEstablished = false
    }

    /// Disconnect from NATS
    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        await natsClient?.disconnect()
        natsClient = nil

        subscriptions.removeAll()
        connectionState = .disconnected
    }

    /// Reconnect with exponential backoff
    func reconnect(authToken: String) async {
        guard connectionState != .reconnecting else { return }

        connectionState = .reconnecting

        for (attempt, delay) in reconnectDelaySeconds.enumerated() {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                if Task.isCancelled { return }

                try await connect(authToken: authToken)
                return // Success
            } catch {
                if attempt == maxReconnectAttempts - 1 {
                    lastError = error
                    connectionState = .error(error)
                }
            }
        }
    }

    // MARK: - Auto-Start Vault Connection

    /// Connect to NATS with automatic vault start on auth failure
    ///
    /// When NATS connection fails due to authentication errors (timeout, auth failure),
    /// this method automatically attempts to start the vault EC2 instance and waits
    /// for it to become ready before retrying the connection.
    ///
    /// - Parameters:
    ///   - authToken: Cognito authentication token
    ///   - autoStartVault: If true, attempt to start vault on auth failure (default: true)
    func connectWithAutoStart(authToken: String, autoStartVault: Bool = true) async throws {
        guard connectionState != .connected else { return }

        connectionState = .connecting
        lastError = nil

        do {
            try await connect(authToken: authToken)
        } catch {
            // Check if this looks like an auth error that might be due to vault not running
            let errorMessage = error.localizedDescription.lowercased()
            let isAuthError = errorMessage.contains("auth") ||
                              errorMessage.contains("timeout") ||
                              errorMessage.contains("connection") ||
                              errorMessage.contains("refused")

            // Attempt to start vault if this looks like an auth error and auto-start is enabled
            if autoStartVault && isAuthError {
                #if DEBUG
                print("[NATS] Auth error detected - attempting to start vault")
                #endif

                let vaultStarted = await attemptVaultStart(authToken: authToken)

                if vaultStarted {
                    #if DEBUG
                    print("[NATS] Vault started - retrying connection")
                    #endif

                    // Retry connection without auto-start to avoid infinite loop
                    try await connectWithAutoStart(authToken: authToken, autoStartVault: false)
                    return
                }
            }

            // Re-throw original error if we couldn't recover
            lastError = error
            connectionState = .error(error)
            throw error
        }
    }

    /// Attempt to start the vault EC2 instance and wait for it to become ready
    ///
    /// - Parameter authToken: Cognito authentication token
    /// - Returns: true if vault was started successfully and is running
    private func attemptVaultStart(authToken: String) async -> Bool {
        guard let userGuid = userGuidProvider() else {
            #if DEBUG
            print("[NATS] Cannot start vault - no user GUID available")
            #endif
            return false
        }

        connectionState = .startingVault

        do {
            // Try to start the vault using action-token flow
            let startResponse = try await apiClient.startVaultAction(
                userGuid: userGuid,
                cognitoToken: authToken
            )

            #if DEBUG
            print("[NATS] Vault start response: \(startResponse.status)")
            #endif

            // If already running, we're good
            if startResponse.status == "running" {
                #if DEBUG
                print("[NATS] Vault is already running")
                #endif
                return true
            }

            // If starting or pending, wait for it to become ready
            if startResponse.status == "starting" || startResponse.status == "pending" {
                #if DEBUG
                print("[NATS] Vault is starting - waiting for it to become ready")
                #endif
                return await waitForVaultReady(authToken: authToken, userGuid: userGuid)
            }

            // Unknown status
            #if DEBUG
            print("[NATS] Unexpected vault start status: \(startResponse.status)")
            #endif
            return false

        } catch {
            #if DEBUG
            print("[NATS] Failed to start vault: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Poll vault status until it's running or timeout
    ///
    /// - Parameters:
    ///   - authToken: Cognito authentication token
    ///   - userGuid: User GUID for action-token API
    /// - Returns: true if vault became ready within timeout
    private func waitForVaultReady(authToken: String, userGuid: String) async -> Bool {
        connectionState = .waitingForVault

        let startTime = Date()
        let deadline = startTime.addingTimeInterval(vaultStartTimeout)

        while Date() < deadline {
            // Wait before polling
            try? await Task.sleep(nanoseconds: UInt64(vaultPollInterval * 1_000_000_000))

            if Task.isCancelled { return false }

            do {
                let status = try await apiClient.getVaultStatusAction(
                    userGuid: userGuid,
                    cognitoToken: authToken
                )

                #if DEBUG
                print("[NATS] Vault status: \(status.instanceStatus ?? "unknown")")
                #endif

                // Check if vault is running
                if status.instanceStatus == "running" {
                    #if DEBUG
                    print("[NATS] Vault is now running")
                    #endif

                    // Give the vault-manager a moment to fully initialize
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    return true
                }

                // Check if vault stopped unexpectedly
                if status.instanceStatus == "stopped" || status.instanceStatus == "terminated" {
                    #if DEBUG
                    print("[NATS] Vault stopped unexpectedly")
                    #endif
                    return false
                }

                // Still pending/starting, keep waiting

            } catch {
                #if DEBUG
                print("[NATS] Failed to get vault status: \(error.localizedDescription)")
                #endif
                // Keep polling on error
            }
        }

        #if DEBUG
        print("[NATS] Timeout waiting for vault to start")
        #endif
        return false
    }

    // MARK: - Credential Management

    /// Refresh NATS credentials via API
    func refreshCredentials(authToken: String) async throws -> NatsCredentials {
        let response = try await apiClient.generateNatsToken(
            request: .app(deviceId: getDeviceId()),
            authToken: authToken
        )

        let credentials = NatsCredentials(from: response)
        try credentialStore.saveCredentials(credentials)

        return credentials
    }

    /// Check if credentials need refresh
    func credentialsNeedRefresh() -> Bool {
        guard let credentials = try? credentialStore.getCredentials() else {
            return true
        }
        return credentials.shouldRefresh
    }

    // MARK: - Publish/Subscribe

    /// Publish message to a topic
    func publish(_ data: Data, to topic: String) async throws {
        guard let client = natsClient, connectionState == .connected else {
            throw NatsConnectionError.notConnected
        }

        try await client.publish(data, to: topic)
    }

    /// Publish encodable message to a topic
    func publish<T: Encodable>(_ message: T, to topic: String) async throws {
        let data = try JSONEncoder().encode(message)
        try await publish(data, to: topic)
    }

    /// Subscribe to a topic
    func subscribe(to topic: String) async throws -> AsyncStream<NatsMessage> {
        guard let client = natsClient, connectionState == .connected else {
            throw NatsConnectionError.notConnected
        }

        return try await client.subscribe(to: topic)
    }

    /// Subscribe to a topic with typed messages
    func subscribe<T: Decodable>(to topic: String, type: T.Type) async throws -> AsyncStream<T> {
        let rawStream = try await subscribe(to: topic)

        return AsyncStream { continuation in
            Task {
                for await message in rawStream {
                    if let decoded = try? JSONDecoder().decode(T.self, from: message.data) {
                        continuation.yield(decoded)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Unsubscribe from a topic
    func unsubscribe(from topic: String) async {
        subscriptions.removeValue(forKey: topic)
        await natsClient?.unsubscribe(from: topic)
    }

    // MARK: - Private Methods

    private func startConnectionMonitoring() {
        // Monitor for disconnection events
        // In a real implementation, this would listen to NATS client events
    }

    private func getDeviceId() -> String {
        // Get or generate a unique device identifier
        let key = "com.vettid.device_id"
        if let deviceId = UserDefaults.standard.string(forKey: key) {
            return deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Connection State

enum NatsConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    /// Starting the vault EC2 instance
    case startingVault
    /// Waiting for vault to become ready
    case waitingForVault
    case error(Error)

    static func == (lhs: NatsConnectionState, rhs: NatsConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.reconnecting, .reconnecting),
             (.startingVault, .startingVault),
             (.waitingForVault, .waitingForVault):
            return true
        case (.error, .error):
            return true // Simplified comparison
        default:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Whether the connection is in a transitional state (connecting, starting vault, etc.)
    var isTransitioning: Bool {
        switch self {
        case .connecting, .reconnecting, .startingVault, .waitingForVault:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .startingVault: return "Starting Vault..."
        case .waitingForVault: return "Waiting for Vault..."
        case .error: return "Error"
        }
    }
}

// MARK: - Errors

enum NatsConnectionError: LocalizedError {
    case noCredentials
    case notConnected
    case connectionFailed(String)
    case publishFailed(String)
    case subscribeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No NATS credentials available"
        case .notConnected:
            return "Not connected to NATS"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .publishFailed(let reason):
            return "Publish failed: \(reason)"
        case .subscribeFailed(let reason):
            return "Subscribe failed: \(reason)"
        }
    }
}

// MARK: - Message Types

struct NatsMessage {
    let topic: String
    let data: Data
    let headers: [String: String]?

    var stringValue: String? {
        String(data: data, encoding: .utf8)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

struct NatsSubscription {
    let topic: String
    let id: String
}

// MARK: - NATS Client Wrapper

#if canImport(Nats)
import Nats

/// Production wrapper using nats.swift library
class NatsClientWrapper {
    private let endpoint: String
    private let jwt: String
    private let seed: String
    private var client: NatsClient?
    private var subscriptions: [String: NatsSubscription] = [:]

    init(endpoint: String, jwt: String, seed: String) {
        self.endpoint = endpoint
        self.jwt = jwt
        self.seed = seed
    }

    func connect() async throws {
        guard let url = URL(string: endpoint) else {
            throw NatsConnectionError.connectionFailed("Invalid NATS endpoint URL")
        }

        let options = NatsClientOptions()
            .url(url)
            .credentialsJWT(jwt: jwt, seed: seed)

        client = options.build()
        try await client?.connect()
    }

    func disconnect() async {
        // Cancel all subscriptions
        for (_, subscription) in subscriptions {
            await subscription.unsubscribe()
        }
        subscriptions.removeAll()

        await client?.close()
        client = nil
    }

    func publish(_ data: Data, to topic: String) async throws {
        guard let client = client else {
            throw NatsConnectionError.notConnected
        }
        try await client.publish(data, subject: topic)
    }

    func subscribe(to topic: String) async throws -> AsyncStream<NatsMessage> {
        guard let client = client else {
            throw NatsConnectionError.notConnected
        }

        let subscription = try await client.subscribe(subject: topic)
        subscriptions[topic] = subscription

        return AsyncStream { continuation in
            Task {
                for try await msg in subscription {
                    let natsMessage = NatsMessage(
                        topic: msg.subject,
                        data: msg.payload ?? Data(),
                        headers: msg.headers?.dictionary
                    )
                    continuation.yield(natsMessage)
                }
                continuation.finish()
            }
        }
    }

    func unsubscribe(from topic: String) async {
        if let subscription = subscriptions.removeValue(forKey: topic) {
            await subscription.unsubscribe()
        }
    }
}

// Extension to convert NatsHeaderMap to [String: String]
private extension NatsHeaderMap {
    var dictionary: [String: String] {
        var result: [String: String] = [:]
        for (key, values) in self {
            if let firstValue = values.first {
                result[key.description] = firstValue.description
            }
        }
        return result
    }
}

#else

/// Stub wrapper for when nats.swift is not available (testing/development)
class NatsClientWrapper {
    private let endpoint: String
    private let jwt: String
    private let seed: String

    init(endpoint: String, jwt: String, seed: String) {
        self.endpoint = endpoint
        self.jwt = jwt
        self.seed = seed
        #if DEBUG
        print("[NATS] Using stub NatsClientWrapper - add nats.swift package for real connectivity")
        #endif
    }

    func connect() async throws {
        // Simulate connection delay
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        #if DEBUG
        print("[NATS] Stub: Connected to \(endpoint)")
        #endif
    }

    func disconnect() async {
        #if DEBUG
        print("[NATS] Stub: Disconnected")
        #endif
    }

    func publish(_ data: Data, to topic: String) async throws {
        #if DEBUG
        print("[NATS] Stub: Published \(data.count) bytes to \(topic)")
        #endif
    }

    func subscribe(to topic: String) async throws -> AsyncStream<NatsMessage> {
        #if DEBUG
        print("[NATS] Stub: Subscribed to \(topic)")
        #endif
        // Return empty stream for stub
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func unsubscribe(from topic: String) async {
        #if DEBUG
        print("[NATS] Stub: Unsubscribed from \(topic)")
        #endif
    }
}

#endif
