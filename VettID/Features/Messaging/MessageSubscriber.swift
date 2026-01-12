import Foundation
import Combine

/// Connection events for real-time updates
enum ConnectionEvent {
    case invitationAccepted(Connection)
    case connectionRevoked(String)
    case profileUpdated(connectionId: String, profile: Profile)
    case messageReceived(Message)
}

/// Incoming message from NATS
struct IncomingMessage: Decodable {
    let messageId: String
    let connectionId: String
    let senderId: String
    let encryptedContent: String
    let nonce: String
    let contentType: String
    let sentAt: Date
}

/// Subscriber for real-time messages via NATS
final class MessageSubscriber {

    // MARK: - Properties

    private let connectionManager: NatsConnectionManager
    private let cryptoManager: ConnectionCryptoManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Publishers

    private let messageSubject = PassthroughSubject<Message, Never>()
    private let connectionEventSubject = PassthroughSubject<ConnectionEvent, Never>()

    /// Publisher for incoming messages
    var messagePublisher: AnyPublisher<Message, Never> {
        messageSubject.eraseToAnyPublisher()
    }

    /// Publisher for connection events
    var connectionEventPublisher: AnyPublisher<ConnectionEvent, Never> {
        connectionEventSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(
        connectionManager: NatsConnectionManager,
        cryptoManager: ConnectionCryptoManager
    ) {
        self.connectionManager = connectionManager
        self.cryptoManager = cryptoManager
    }

    // MARK: - Subscriptions

    /// Subscribe to incoming messages
    func subscribeToMessages() async throws {
        // Subscribe to message topic via NATS
        // Topic: OwnerSpace.{guid}.forApp.messages

        let stream = try await connectionManager.subscribe(
            to: "forApp.messages",
            type: IncomingMessage.self
        )

        Task {
            for await incomingMessage in stream {
                await processIncomingMessage(incomingMessage)
            }
        }
    }

    /// Subscribe to connection events
    func subscribeToConnectionEvents() async throws {
        // Subscribe to connection events via NATS
        // Topic: OwnerSpace.{guid}.forApp.connections

        let stream = try await connectionManager.subscribe(
            to: "forApp.connections",
            type: ConnectionEventPayload.self
        )

        Task {
            for await eventPayload in stream {
                await processConnectionEvent(eventPayload)
            }
        }
    }

    // MARK: - Message Processing

    /// Process an incoming message
    private func processIncomingMessage(_ incoming: IncomingMessage) async {
        do {
            // Decrypt the message content
            guard let ciphertext = Data(base64Encoded: incoming.encryptedContent),
                  let nonce = Data(base64Encoded: incoming.nonce) else {
                return
            }

            let decryptedContent = try cryptoManager.decryptFromConnection(
                ciphertext: ciphertext,
                nonce: nonce,
                connectionId: incoming.connectionId
            )

            // Create message object
            let message = Message(
                id: incoming.messageId,
                connectionId: incoming.connectionId,
                senderId: incoming.senderId,
                content: decryptedContent,
                contentType: MessageContentType(rawValue: incoming.contentType) ?? .text,
                sentAt: incoming.sentAt,
                receivedAt: Date(),
                readAt: nil,
                status: .delivered
            )

            // Publish to subscribers
            messageSubject.send(message)
            connectionEventSubject.send(.messageReceived(message))
        } catch {
            // Log decryption error but don't crash
            #if DEBUG
            print("Failed to decrypt message: \(error)")
            #endif
        }
    }

    /// Process a connection event
    private func processConnectionEvent(_ payload: ConnectionEventPayload) async {
        switch payload.eventType {
        case "invitation_accepted":
            if let connection = payload.connection {
                connectionEventSubject.send(.invitationAccepted(connection))
            }

        case "connection_revoked":
            if let connectionId = payload.connectionId {
                connectionEventSubject.send(.connectionRevoked(connectionId))
            }

        case "profile_updated":
            if let connectionId = payload.connectionId,
               let profile = payload.profile {
                connectionEventSubject.send(.profileUpdated(connectionId: connectionId, profile: profile))
            }

        default:
            break
        }
    }

    // MARK: - Unsubscribe

    /// Stop all subscriptions
    func unsubscribe() {
        cancellables.removeAll()
    }
}

// MARK: - Connection Event Payload

struct ConnectionEventPayload: Decodable {
    let eventType: String
    let connectionId: String?
    let connection: Connection?
    let profile: Profile?
}

// MARK: - Message Observer

/// Observable object for SwiftUI integration
@MainActor
final class MessageObserver: ObservableObject {

    // MARK: - Published State

    @Published private(set) var newMessages: [Message] = []
    @Published private(set) var connectionEvents: [ConnectionEvent] = []

    // MARK: - Properties

    private let subscriber: MessageSubscriber
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(subscriber: MessageSubscriber) {
        self.subscriber = subscriber
        setupSubscriptions()
    }

    // MARK: - Setup

    private func setupSubscriptions() {
        subscriber.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.newMessages.append(message)
            }
            .store(in: &cancellables)

        subscriber.connectionEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.connectionEvents.append(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Clear

    /// Clear new messages after they've been processed
    func clearNewMessages() {
        newMessages.removeAll()
    }

    /// Clear connection events after they've been processed
    func clearConnectionEvents() {
        connectionEvents.removeAll()
    }

    /// Get messages for a specific connection
    func messages(for connectionId: String) -> [Message] {
        newMessages.filter { $0.connectionId == connectionId }
    }
}
