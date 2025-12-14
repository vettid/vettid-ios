import Foundation

// MARK: - Feed Event

enum FeedEvent: Identifiable {
    case message(MessageEvent)
    case connectionRequest(ConnectionRequestEvent)
    case authRequest(AuthRequestEvent)
    case vaultActivity(VaultActivityEvent)

    var id: String {
        switch self {
        case .message(let e): return e.id
        case .connectionRequest(let e): return e.id
        case .authRequest(let e): return e.id
        case .vaultActivity(let e): return e.id
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let e): return e.timestamp
        case .connectionRequest(let e): return e.timestamp
        case .authRequest(let e): return e.timestamp
        case .vaultActivity(let e): return e.timestamp
        }
    }

    var isRead: Bool {
        switch self {
        case .message(let e): return e.isRead
        case .connectionRequest(let e): return e.isRead
        case .authRequest(let e): return e.isRead
        case .vaultActivity(let e): return e.isRead
        }
    }
}

// MARK: - Message Event

struct MessageEvent: Identifiable {
    let id: String
    let senderId: String
    let senderName: String
    let senderAvatarUrl: String?
    let preview: String
    let timestamp: Date
    var isRead: Bool
    let connectionId: String

    static func mock() -> MessageEvent {
        MessageEvent(
            id: UUID().uuidString,
            senderId: "sender-123",
            senderName: "John Doe",
            senderAvatarUrl: nil,
            preview: "Hey, how are you doing?",
            timestamp: Date().addingTimeInterval(-300),
            isRead: false,
            connectionId: "conn-123"
        )
    }
}

// MARK: - Connection Request Event

struct ConnectionRequestEvent: Identifiable {
    let id: String
    let requesterId: String
    let requesterName: String
    let requesterAvatarUrl: String?
    let timestamp: Date
    var isRead: Bool
    let status: ConnectionRequestStatus

    enum ConnectionRequestStatus: String {
        case pending
        case accepted
        case declined
    }

    static func mock() -> ConnectionRequestEvent {
        ConnectionRequestEvent(
            id: UUID().uuidString,
            requesterId: "requester-456",
            requesterName: "Jane Smith",
            requesterAvatarUrl: nil,
            timestamp: Date().addingTimeInterval(-3600),
            isRead: false,
            status: .pending
        )
    }
}

// MARK: - Auth Request Event

struct AuthRequestEvent: Identifiable {
    let id: String
    let serviceName: String
    let serviceIcon: String?
    let actionType: String
    let timestamp: Date
    var isRead: Bool
    let status: AuthRequestStatus

    enum AuthRequestStatus: String {
        case pending
        case approved
        case denied
        case expired
    }

    static func mock() -> AuthRequestEvent {
        AuthRequestEvent(
            id: UUID().uuidString,
            serviceName: "Banking App",
            serviceIcon: nil,
            actionType: "Login Request",
            timestamp: Date().addingTimeInterval(-1800),
            isRead: true,
            status: .approved
        )
    }
}

// MARK: - Vault Activity Event

struct VaultActivityEvent: Identifiable {
    let id: String
    let activityType: VaultActivityType
    let description: String
    let timestamp: Date
    var isRead: Bool

    enum VaultActivityType: String {
        case vaultStarted = "vault_started"
        case vaultStopped = "vault_stopped"
        case backupCreated = "backup_created"
        case credentialAdded = "credential_added"
        case keysRefreshed = "keys_refreshed"

        var icon: String {
            switch self {
            case .vaultStarted: return "play.circle.fill"
            case .vaultStopped: return "stop.circle.fill"
            case .backupCreated: return "externaldrive.fill"
            case .credentialAdded: return "key.fill"
            case .keysRefreshed: return "arrow.triangle.2.circlepath"
            }
        }

        var color: String {
            switch self {
            case .vaultStarted: return "green"
            case .vaultStopped: return "orange"
            case .backupCreated: return "blue"
            case .credentialAdded: return "purple"
            case .keysRefreshed: return "teal"
            }
        }
    }

    static func mock() -> VaultActivityEvent {
        VaultActivityEvent(
            id: UUID().uuidString,
            activityType: .vaultStarted,
            description: "Vault started successfully",
            timestamp: Date().addingTimeInterval(-7200),
            isRead: true
        )
    }
}

// MARK: - Mock Data Generator

extension FeedEvent {
    static func mockFeed() -> [FeedEvent] {
        [
            .message(MessageEvent.mock()),
            .connectionRequest(ConnectionRequestEvent.mock()),
            .authRequest(AuthRequestEvent.mock()),
            .vaultActivity(VaultActivityEvent.mock()),
            .message(MessageEvent(
                id: UUID().uuidString,
                senderId: "sender-789",
                senderName: "Alice Johnson",
                senderAvatarUrl: nil,
                preview: "The documents are ready for review.",
                timestamp: Date().addingTimeInterval(-86400),
                isRead: true,
                connectionId: "conn-456"
            )),
            .vaultActivity(VaultActivityEvent(
                id: UUID().uuidString,
                activityType: .backupCreated,
                description: "Backup completed successfully",
                timestamp: Date().addingTimeInterval(-172800),
                isRead: true
            ))
        ].sorted { $0.timestamp > $1.timestamp }
    }
}
