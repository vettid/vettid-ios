import Foundation
import Combine

#if canImport(Nats)
import Nats
#endif

/// Manages NATS connections for multiple service vaults
///
/// Unlike the main NatsConnectionManager (user's vault), this manages
/// connections to service NATS clusters for each active service contract.
///
/// Features:
/// - Connect on app launch for all active contracts
/// - Automatic reconnection handling
/// - Connection status monitoring per service
/// - Background connection management
@MainActor
final class ServiceNATSManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var connections: [String: ServiceConnectionState] = [:]
    @Published private(set) var isInitialized: Bool = false

    // MARK: - Dependencies

    private let contractStore: ContractStore
    private var serviceClients: [String: ServiceNATSClient] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var messageHandlers: [String: [(ServiceNATSMessage) -> Void]] = [:]

    // MARK: - Configuration

    private let maxReconnectAttempts = 5
    private let reconnectDelaySeconds: [Double] = [1, 2, 4, 8, 16]

    // MARK: - Initialization

    init(contractStore: ContractStore = ContractStore()) {
        self.contractStore = contractStore
    }

    // MARK: - Lifecycle

    /// Initialize connections for all active contracts
    /// Called on app launch
    func initialize() async {
        guard !isInitialized else { return }

        do {
            let activeContracts = try contractStore.listActiveContracts()

            #if DEBUG
            print("[ServiceNATS] Initializing connections for \(activeContracts.count) active contracts")
            #endif

            for contract in activeContracts {
                await connectToService(contractId: contract.contractId)
            }

            isInitialized = true
        } catch {
            #if DEBUG
            print("[ServiceNATS] Failed to load active contracts: \(error)")
            #endif
        }
    }

    /// Connect to a specific service's NATS cluster
    func connectToService(contractId: String) async {
        // Get credentials from store
        guard let credentials = try? contractStore.retrieveNATSCredentials(contractId: contractId) else {
            connections[contractId] = .error("No credentials found")
            #if DEBUG
            print("[ServiceNATS] No credentials for contract \(contractId)")
            #endif
            return
        }

        connections[contractId] = .connecting

        do {
            let client = ServiceNATSClient(
                serviceId: credentials.serviceId,
                endpoint: credentials.endpoint,
                jwt: credentials.jwt,
                seed: credentials.seed
            )

            try await client.connect()

            serviceClients[contractId] = client
            connections[contractId] = .connected

            // Subscribe to service messages
            await subscribeToServiceMessages(contractId: contractId, client: client, credentials: credentials)

            #if DEBUG
            print("[ServiceNATS] Connected to service \(credentials.serviceId)")
            #endif

        } catch {
            connections[contractId] = .error(error.localizedDescription)
            #if DEBUG
            print("[ServiceNATS] Failed to connect to service: \(error)")
            #endif

            // Schedule reconnection
            scheduleReconnect(contractId: contractId)
        }
    }

    /// Disconnect from a specific service
    func disconnect(contractId: String) async {
        // Cancel any pending reconnect
        reconnectTasks[contractId]?.cancel()
        reconnectTasks.removeValue(forKey: contractId)

        // Disconnect client
        await serviceClients[contractId]?.disconnect()
        serviceClients.removeValue(forKey: contractId)

        connections.removeValue(forKey: contractId)

        #if DEBUG
        print("[ServiceNATS] Disconnected from contract \(contractId)")
        #endif
    }

    /// Disconnect from all services
    func disconnectAll() async {
        for (contractId, _) in serviceClients {
            await disconnect(contractId: contractId)
        }

        isInitialized = false
    }

    // MARK: - Messaging

    /// Publish a message to a service
    func publish(
        to contractId: String,
        subject: String,
        data: Data
    ) async throws {
        guard let client = serviceClients[contractId] else {
            throw ServiceNATSError.notConnected
        }

        try await client.publish(data, to: subject)
    }

    /// Publish an encrypted message to a service
    func publishEncrypted(
        to contractId: String,
        message: ServiceEncryptedMessage
    ) async throws {
        guard let client = serviceClients[contractId],
              let credentials = try? contractStore.retrieveNATSCredentials(contractId: contractId) else {
            throw ServiceNATSError.notConnected
        }

        let data = try JSONEncoder().encode(message)
        try await client.publish(data, to: credentials.subjects.publish)
    }

    /// Register a message handler for a service
    func onMessage(
        contractId: String,
        handler: @escaping (ServiceNATSMessage) -> Void
    ) {
        if messageHandlers[contractId] == nil {
            messageHandlers[contractId] = []
        }
        messageHandlers[contractId]?.append(handler)
    }

    /// Get connection status for a service
    func connectionStatus(for contractId: String) -> ServiceConnectionState {
        connections[contractId] ?? .disconnected
    }

    /// Check if connected to a service
    func isConnected(to contractId: String) -> Bool {
        if case .connected = connections[contractId] {
            return true
        }
        return false
    }

    // MARK: - Private Methods

    private func subscribeToServiceMessages(
        contractId: String,
        client: ServiceNATSClient,
        credentials: ServiceNATSCredentials
    ) async {
        do {
            let stream = try await client.subscribe(to: credentials.subjects.subscribe)

            Task {
                for await message in stream {
                    // Dispatch to handlers
                    let handlers = messageHandlers[contractId] ?? []
                    for handler in handlers {
                        handler(message)
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[ServiceNATS] Failed to subscribe: \(error)")
            #endif
        }
    }

    private func scheduleReconnect(contractId: String) {
        reconnectTasks[contractId]?.cancel()

        reconnectTasks[contractId] = Task {
            for (attempt, delay) in reconnectDelaySeconds.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                    if Task.isCancelled { return }

                    await connectToService(contractId: contractId)

                    if case .connected = connections[contractId] {
                        return // Success
                    }
                } catch {
                    if attempt == maxReconnectAttempts - 1 {
                        connections[contractId] = .error("Reconnection failed after \(maxReconnectAttempts) attempts")
                    }
                }
            }
        }
    }
}

// MARK: - Service Connection State

enum ServiceConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)

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
        case .error(let message): return "Error: \(message)"
        }
    }
}

// MARK: - Service NATS Message

struct ServiceNATSMessage {
    let subject: String
    let data: Data
    let receivedAt: Date

    var stringValue: String? {
        String(data: data, encoding: .utf8)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Service NATS Client

/// Individual NATS client for a service connection
private class ServiceNATSClient {
    private let serviceId: String
    private let endpoint: String
    private let jwt: String
    private let seed: String
    private var subscriptionTasks: [String: Task<Void, Never>] = [:]

    #if canImport(Nats)
    private var client: NatsClient?
    private var credentialsFileURL: URL?
    #endif

    init(serviceId: String, endpoint: String, jwt: String, seed: String) {
        self.serviceId = serviceId
        self.endpoint = endpoint
        self.jwt = jwt
        self.seed = seed
    }

    func connect() async throws {
        #if canImport(Nats)
        guard let url = URL(string: endpoint) else {
            throw ServiceNATSError.invalidEndpoint
        }

        // Write credentials to temp file
        let credsContent = """
        -----BEGIN NATS USER JWT-----
        \(jwt)
        ------END NATS USER JWT------

        ************************* IMPORTANT *************************
        NKEY Seed printed below can be used to sign and prove identity.
        NKEYs are sensitive and should be treated as secrets.

        -----BEGIN USER NKEY SEED-----
        \(seed)
        ------END USER NKEY SEED------
        """

        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let credsDir = containerDir.appendingPathComponent("service_nats_creds", isDirectory: true)

        if !FileManager.default.fileExists(atPath: credsDir.path) {
            try FileManager.default.createDirectory(at: credsDir, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.complete
            ])
        }

        let credsFile = credsDir.appendingPathComponent("service_\(serviceId)_\(UUID().uuidString).creds")

        try credsContent.write(to: credsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([
            .protectionKey: FileProtectionType.complete
        ], ofItemAtPath: credsFile.path)

        credentialsFileURL = credsFile

        let options = NatsClientOptions()
            .url(url)
            .credentialsFile(credsFile)

        client = options.build()
        try await client?.connect()
        #else
        // Stub for development
        try await Task.sleep(nanoseconds: 100_000_000)
        #if DEBUG
        print("[ServiceNATS] Stub: Connected to \(endpoint)")
        #endif
        #endif
    }

    func disconnect() async {
        // Cancel subscriptions
        for (_, task) in subscriptionTasks {
            task.cancel()
        }
        subscriptionTasks.removeAll()

        #if canImport(Nats)
        try? await client?.close()
        client = nil

        // Securely delete credentials file
        if let credsFile = credentialsFileURL {
            try? FileManager.default.removeItem(at: credsFile)
            credentialsFileURL = nil
        }
        #endif
    }

    func publish(_ data: Data, to subject: String) async throws {
        #if canImport(Nats)
        guard let client = client else {
            throw ServiceNATSError.notConnected
        }
        try await client.publish(data, subject: subject)
        #else
        #if DEBUG
        print("[ServiceNATS] Stub: Published \(data.count) bytes to \(subject)")
        #endif
        #endif
    }

    func subscribe(to subject: String) async throws -> AsyncStream<ServiceNATSMessage> {
        #if canImport(Nats)
        guard let client = client else {
            throw ServiceNATSError.notConnected
        }

        let subscription = try await client.subscribe(subject: subject)

        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await msg in subscription {
                        if Task.isCancelled { break }
                        let message = ServiceNATSMessage(
                            subject: msg.subject,
                            data: msg.payload ?? Data(),
                            receivedAt: Date()
                        )
                        continuation.yield(message)
                    }
                } catch {
                    // Stream ended
                }
                continuation.finish()
            }
            self.subscriptionTasks[subject] = task
        }
        #else
        #if DEBUG
        print("[ServiceNATS] Stub: Subscribed to \(subject)")
        #endif
        return AsyncStream { continuation in
            continuation.finish()
        }
        #endif
    }
}

// MARK: - Errors

enum ServiceNATSError: Error, LocalizedError {
    case notConnected
    case invalidEndpoint
    case connectionFailed(String)
    case publishFailed(String)
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to service"
        case .invalidEndpoint:
            return "Invalid NATS endpoint URL"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .publishFailed(let reason):
            return "Publish failed: \(reason)"
        case .noCredentials:
            return "No NATS credentials available"
        }
    }
}
