import Foundation

/// Represents a connection between two users
struct Connection: Codable, Identifiable, Equatable {
    let id: String
    let peerGuid: String
    let peerDisplayName: String
    let peerAvatarUrl: String?
    let status: ConnectionStatus
    let createdAt: Date
    let lastMessageAt: Date?
    let unreadCount: Int
}

/// Connection status
enum ConnectionStatus: String, Codable {
    case pending
    case active
    case revoked
}

/// Connection invitation for establishing new connections
struct ConnectionInvitation: Codable {
    let invitationId: String
    let invitationCode: String
    let qrCodeData: String
    let deepLinkUrl: String
    let expiresAt: Date
    let creatorDisplayName: String
}

/// Request to create an invitation
struct CreateInvitationRequest: Encodable {
    let expiresInMinutes: Int
    let publicKey: String  // Base64-encoded X25519 public key
}

/// Request to accept an invitation
struct AcceptInvitationRequest: Encodable {
    let code: String
    let publicKey: String  // Base64-encoded X25519 public key
}

/// Request to revoke a connection
struct RevokeConnectionRequest: Encodable {
    let connectionId: String
}

/// Response when accepting an invitation
struct AcceptInvitationResponse: Decodable {
    let connection: Connection
    let peerPublicKey: String  // Base64-encoded peer's X25519 public key
}

/// Connection list response
struct ConnectionListResponse: Decodable {
    let connections: [Connection]
    let total: Int
}

/// Statistics about a connection
struct ConnectionStats: Codable {
    let messageCount: Int
    let firstMessageAt: Date?
    let lastActiveAt: Date?
}
