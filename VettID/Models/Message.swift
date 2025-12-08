import Foundation

/// Represents a message in a conversation
struct Message: Codable, Identifiable, Equatable {
    let id: String
    let connectionId: String
    let senderId: String
    let content: String
    let contentType: MessageContentType
    let sentAt: Date
    let receivedAt: Date?
    let readAt: Date?
    let status: MessageStatus
}

/// Type of message content
enum MessageContentType: String, Codable {
    case text
    case image
    case file
}

/// Message delivery status
enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

/// Request to send a message
struct SendMessageRequest: Encodable {
    let connectionId: String
    let encryptedContent: String  // Base64-encoded encrypted content
    let nonce: String             // Base64-encoded nonce
    let contentType: String
}

/// Response when sending a message
struct SendMessageResponse: Decodable {
    let messageId: String
    let sentAt: Date
}

/// Message history response
struct MessageHistoryResponse: Decodable {
    let messages: [Message]
    let hasMore: Bool
}

/// Unread message counts per connection
struct UnreadCountResponse: Decodable {
    let counts: [String: Int]
}

/// Mark message as read request
struct MarkReadRequest: Encodable {
    let messageId: String
}

/// Group of messages by date for display
struct MessageGroup: Identifiable {
    let id: String
    let date: Date
    let messages: [Message]

    init(date: Date, messages: [Message]) {
        self.id = date.ISO8601Format()
        self.date = date
        self.messages = messages
    }
}
