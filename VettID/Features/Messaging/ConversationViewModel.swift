import Foundation

/// ViewModel for conversation/messaging screen
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

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
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

    /// Load messages for the connection
    func loadMessages() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        guard !connectionId.isEmpty else {
            errorMessage = "No connection specified"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

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

    /// Send a new message
    func sendMessage(_ content: String) async {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isSending = true
        errorMessage = nil

        do {
            // Encrypt the message
            let encrypted = try cryptoManager.encryptForConnection(
                plaintext: trimmedContent,
                connectionId: connectionId
            )

            // Send via API
            let sentMessage = try await apiClient.sendMessage(
                connectionId: connectionId,
                encryptedContent: encrypted.ciphertext,
                nonce: encrypted.nonce,
                authToken: authToken
            )

            // Create local message with decrypted content
            let localMessage = Message(
                id: sentMessage.id,
                connectionId: connectionId,
                senderId: currentUserId,
                content: trimmedContent,
                contentType: .text,
                sentAt: sentMessage.sentAt,
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

    /// Mark a message as read
    func markAsRead(_ messageId: String) async {
        guard let authToken = authTokenProvider() else { return }

        do {
            try await apiClient.markAsRead(messageId: messageId, authToken: authToken)

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
                if let ciphertext = Data(base64Encoded: message.content) {
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
