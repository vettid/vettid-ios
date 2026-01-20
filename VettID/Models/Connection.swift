import Foundation

/// Represents a connection between two users
struct Connection: Codable, Identifiable, Equatable {
    let id: String
    let peerGuid: String
    let peerDisplayName: String
    let peerAvatarUrl: String?
    let status: ConnectionStatus
    let trustLevel: TrustLevel
    let createdAt: Date
    let lastMessageAt: Date?
    let unreadCount: Int
    let isFavorite: Bool
    let tags: [String]
    let mutualConnectionCount: Int

    // Default initializer for backward compatibility
    init(
        id: String,
        peerGuid: String,
        peerDisplayName: String,
        peerAvatarUrl: String? = nil,
        status: ConnectionStatus,
        trustLevel: TrustLevel = .new,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        unreadCount: Int = 0,
        isFavorite: Bool = false,
        tags: [String] = [],
        mutualConnectionCount: Int = 0
    ) {
        self.id = id
        self.peerGuid = peerGuid
        self.peerDisplayName = peerDisplayName
        self.peerAvatarUrl = peerAvatarUrl
        self.status = status
        self.trustLevel = trustLevel
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isFavorite = isFavorite
        self.tags = tags
        self.mutualConnectionCount = mutualConnectionCount
    }
}

/// Connection status
enum ConnectionStatus: String, Codable {
    case pending
    case active
    case revoked
}

/// Trust level for connections - builds over time based on interaction
enum TrustLevel: String, Codable, CaseIterable {
    case new = "new"
    case established = "established"
    case trusted = "trusted"
    case verified = "verified"

    var displayName: String {
        switch self {
        case .new: return "New"
        case .established: return "Established"
        case .trusted: return "Trusted"
        case .verified: return "Verified"
        }
    }

    var description: String {
        switch self {
        case .new: return "Recently connected"
        case .established: return "Regular interaction"
        case .trusted: return "Long-term connection"
        case .verified: return "Identity verified"
        }
    }

    var color: String {
        switch self {
        case .new: return "#9E9E9E"       // Gray
        case .established: return "#2196F3" // Blue
        case .trusted: return "#4CAF50"     // Green
        case .verified: return "#9C27B0"    // Purple
        }
    }
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
