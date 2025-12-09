import Foundation
import Combine

/// Manages NATS connection lifecycle
@MainActor
final class NatsConnectionManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectionState: NatsConnectionState = .disconnected
    @Published private(set) var lastError: Error?

    // MARK: - Dependencies

    private let credentialStore: NatsCredentialStore
    private let apiClient: APIClient

    // MARK: - Connection State

    private var natsClient: NatsClientWrapper?
    private var reconnectTask: Task<Void, Never>?
    private var subscriptions: [String: NatsSubscription] = [:]

    // MARK: - Configuration

    private let maxReconnectAttempts = 5
    private let reconnectDelaySeconds: [Double] = [1, 2, 4, 8, 16] // Exponential backoff

    // MARK: - Initialization

    nonisolated init(credentialStore: NatsCredentialStore = NatsCredentialStore(),
                     apiClient: APIClient = APIClient()) {
        self.credentialStore = credentialStore
        self.apiClient = apiClient
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
    case error(Error)

    static func == (lhs: NatsConnectionState, rhs: NatsConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.reconnecting, .reconnecting):
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

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
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
