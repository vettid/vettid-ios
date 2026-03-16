import Foundation

/// ViewModel for conversation/messaging screen
///
/// Messages are sent and received via NATS (vault-to-vault).
/// Message flow: App → Vault (message.send) → Peer Vault → Peer App
@MainActor
final class ConversationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var messages: [Message] = []
    @Published private(set) var connectionName = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isSending = false
    @Published private(set) var hasMoreMessages = false
    @Published var errorMessage: String?

    // MARK: - Properties

    var connectionId: String = ""
    var currentUserId: String = ""

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?
    private var messageHandler: MessageHandler?
    var messagingClient: MessagingClient?

    // MARK: - Transport Key

    /// Transport key for app-vault encrypted messaging (loaded via messagingClient)
    @Published private(set) var transportKey: Data?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?,
        messagingClient: MessagingClient? = nil
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
        self.messagingClient = messagingClient
    }

    /// Configure the NATS message handler for vault-to-vault messaging
    func configureMessageHandler(_ handler: MessageHandler) {
        self.messageHandler = handler
    }

    // MARK: - Computed Properties

    /// Messages grouped by date
    var groupedMessages: [MessageGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { message in
            calendar.startOfDay(for: message.sentAt)
        }

        return grouped.map { MessageGroup(date: $0.key, messages: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Loading

    /// Load messages for the connection, trying NATS first with HTTP fallback
    func loadMessages() async {
        guard !connectionId.isEmpty else {
            errorMessage = "No connection specified"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        // Try NATS-based loading first
        if messagingClient != nil {
            let natsSuccess = await loadFromNats()
            if natsSuccess {
                isLoading = false
                return
            }
            // Fall through to HTTP on NATS failure
        }

        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        do {
            // Load connection details for name
            let connection = try await apiClient.getConnection(id: connectionId, authToken: authToken)
            connectionName = connection.peerDisplayName

            // Load messages
            let loadedMessages = try await apiClient.getMessageHistory(
                connectionId: connectionId,
                limit: 50,
                authToken: authToken
            )

            // Decrypt messages
            messages = try await decryptMessages(loadedMessages)
            hasMoreMessages = loadedMessages.count >= 50

            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Load messages from vault via NATS MessagingClient
    /// - Returns: true if NATS loading succeeded
    @discardableResult
    func loadFromNats() async -> Bool {
        guard let client = messagingClient else { return false }

        do {
            // Load transport key for this connection
            transportKey = try await client.getTransportKey(connectionId: connectionId)

            // Load message history from vault
            let storedMessages = try await client.listMessages(connectionId: connectionId, limit: 50)
            let isoFormatter = ISO8601DateFormatter()

            messages = storedMessages.map { stored -> Message in
                let sentDate = isoFormatter.date(from: stored.sentAt) ?? Date()
                let senderId = stored.senderGuid.isEmpty ? (stored.direction == "outbound" ? currentUserId : "") : stored.senderGuid

                let status: MessageStatus
                switch stored.status {
                case "read": status = .read
                case "delivered": status = .delivered
                case "sent": status = .sent
                case "failed": status = .failed
                default: status = .sent
                }

                return Message(
                    id: stored.messageId,
                    connectionId: stored.connectionId,
                    senderId: senderId,
                    content: stored.content,
                    contentType: MessageContentType(rawValue: stored.contentType) ?? .text,
                    sentAt: sentDate,
                    receivedAt: stored.direction == "inbound" ? sentDate : nil,
                    readAt: stored.status == "read" ? sentDate : nil,
                    status: status
                )
            }

            hasMoreMessages = storedMessages.count >= 50
            return true
        } catch {
            #if DEBUG
            print("[ConversationViewModel] NATS loadFromNats failed, falling back to HTTP: \(error)")
            #endif
            return false
        }
    }

    /// Load the transport key for this connection from the vault
    func loadTransportKey() async {
        guard let client = messagingClient else { return }
        do {
            transportKey = try await client.getTransportKey(connectionId: connectionId)
        } catch {
            #if DEBUG
            print("[ConversationViewModel] Failed to load transport key: \(error)")
            #endif
        }
    }

    /// Load more messages (pagination)
    func loadMoreMessages() async {
        guard hasMoreMessages,
              let oldestMessage = messages.first,
              let authToken = authTokenProvider() else {
            return
        }

        do {
            let olderMessages = try await apiClient.getMessageHistory(
                connectionId: connectionId,
                limit: 50,
                before: oldestMessage.sentAt,
                authToken: authToken
            )

            let decrypted = try await decryptMessages(olderMessages)
            messages = decrypted + messages
            hasMoreMessages = olderMessages.count >= 50
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Send Message

    /// Send a new message via NATS (vault-to-vault)
    func sendMessage(_ content: String) async {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        // Check auth early if no messaging client or handler configured (will need API fallback)
        if messagingClient == nil && messageHandler == nil && authTokenProvider() == nil {
            errorMessage = "Not authenticated"
            return
        }

        isSending = true
        errorMessage = nil

        do {
            let sentTimestamp: String
            let sentMessageId: String

            // Priority 1: Send plaintext to vault via MessagingClient (vault handles encryption)
            if let client = messagingClient {
                let result = try await client.sendMessage(
                    connectionId: connectionId,
                    content: trimmedContent,
                    contentType: "text"
                )
                sentMessageId = result.messageId
                sentTimestamp = result.timestamp
            }
            // Priority 2: Send via NATS MessageHandler (app-side encryption)
            else if let handler = messageHandler {
                let encrypted = try cryptoManager.encryptForConnection(
                    plaintext: trimmedContent,
                    connectionId: connectionId
                )
                let sentMessage = try await handler.sendMessage(
                    connectionId: connectionId,
                    encryptedContent: encrypted.ciphertext.base64EncodedString(),
                    nonce: encrypted.nonce.base64EncodedString(),
                    contentType: "text"
                )
                sentMessageId = sentMessage.messageId
                sentTimestamp = sentMessage.timestamp
            }
            // Priority 3: Fallback to HTTP API
            else if let authToken = authTokenProvider() {
                let encrypted = try cryptoManager.encryptForConnection(
                    plaintext: trimmedContent,
                    connectionId: connectionId
                )
                let apiMessage = try await apiClient.sendMessage(
                    connectionId: connectionId,
                    encryptedContent: encrypted.ciphertext,
                    nonce: encrypted.nonce,
                    authToken: authToken
                )
                sentMessageId = apiMessage.id
                sentTimestamp = ISO8601DateFormatter().string(from: apiMessage.sentAt)
            } else {
                throw ConversationError.notAuthenticated
            }

            // Create local message with decrypted content
            let localMessage = Message(
                id: sentMessageId,
                connectionId: connectionId,
                senderId: currentUserId,
                content: trimmedContent,
                contentType: .text,
                sentAt: ISO8601DateFormatter().date(from: sentTimestamp) ?? Date(),
                receivedAt: nil,
                readAt: nil,
                status: .sent
            )

            messages.append(localMessage)
            isSending = false
        } catch {
            errorMessage = error.localizedDescription
            isSending = false
        }
    }

    // MARK: - Mark as Read

    /// Mark a message as read and send read receipt via NATS
    func markAsRead(_ messageId: String) async {
        do {
            // Send read receipt via NATS (preferred) or fallback to API
            if let handler = messageHandler {
                _ = try await handler.sendReadReceipt(
                    connectionId: connectionId,
                    messageId: messageId
                )
            } else if let authToken = authTokenProvider() {
                try await apiClient.markAsRead(messageId: messageId, authToken: authToken)
            }

            // Update local state
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                let message = messages[index]
                messages[index] = Message(
                    id: message.id,
                    connectionId: message.connectionId,
                    senderId: message.senderId,
                    content: message.content,
                    contentType: message.contentType,
                    sentAt: message.sentAt,
                    receivedAt: message.receivedAt,
                    readAt: Date(),
                    status: .read
                )
            }
        } catch {
            // Silently ignore errors for mark as read
            #if DEBUG
            print("[ConversationViewModel] Failed to send read receipt: \(error)")
            #endif
        }
    }

    // MARK: - Incoming Messages

    /// Handle an incoming message from a peer (received via MessageSubscriber)
    /// Uses the IncomingMessage type from MessageSubscriber.swift
    func handleIncomingMessage(_ incoming: IncomingMessage) {
        // Decrypt the message
        do {
            // IncomingMessage has base64 strings for ciphertext and nonce
            guard let ciphertext = Data(base64Encoded: incoming.encryptedContent),
                  let nonce = Data(base64Encoded: incoming.nonce) else {
                #if DEBUG
                print("[ConversationViewModel] Invalid base64 in incoming message")
                #endif
                return
            }

            let decrypted = try cryptoManager.decryptFromConnection(
                ciphertext: ciphertext,
                nonce: nonce,
                connectionId: incoming.connectionId
            )

            let message = Message(
                id: incoming.messageId,
                connectionId: incoming.connectionId,
                senderId: incoming.senderId,
                content: decrypted,
                contentType: MessageContentType(rawValue: incoming.contentType) ?? .text,
                sentAt: incoming.sentAt,
                receivedAt: Date(),
                readAt: nil,
                status: .delivered
            )

            // Only add if this is for our connection and not a duplicate
            if incoming.connectionId == connectionId,
               !messages.contains(where: { $0.id == incoming.messageId }) {
                messages.append(message)
            }
        } catch {
            #if DEBUG
            print("[ConversationViewModel] Failed to decrypt incoming message: \(error)")
            #endif
        }
    }

    /// Handle a read receipt from a peer (received via forApp.read-receipt)
    func handleReadReceipt(messageId: String, connectionId: String, readAt: Date) {
        guard connectionId == self.connectionId else { return }

        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            let message = messages[index]
            messages[index] = Message(
                id: message.id,
                connectionId: message.connectionId,
                senderId: message.senderId,
                content: message.content,
                contentType: message.contentType,
                sentAt: message.sentAt,
                receivedAt: message.receivedAt,
                readAt: readAt,
                status: .read
            )
        }
    }

    // MARK: - Decryption

    /// Decrypt a list of messages
    private func decryptMessages(_ encryptedMessages: [Message]) async throws -> [Message] {
        var decrypted: [Message] = []

        for message in encryptedMessages {
            // For messages from the current user, content is already plain text
            // For received messages, we need to decrypt
            if message.senderId == currentUserId {
                decrypted.append(message)
            } else {
                // Attempt to decrypt
                if Data(base64Encoded: message.content) != nil {
                    // The nonce would typically be stored separately
                    // For now, assume the content is already decrypted or handle gracefully
                    decrypted.append(message)
                } else {
                    decrypted.append(message)
                }
            }
        }

        return decrypted
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Errors

enum ConversationError: LocalizedError {
    case notAuthenticated
    case noMessageHandler
    case sendFailed(String)
    case decryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated"
        case .noMessageHandler:
            return "Message handler not configured"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        case .decryptionFailed(let reason):
            return "Failed to decrypt message: \(reason)"
        }
    }
}
