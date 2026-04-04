import Foundation

// MARK: - Feed Event

enum FeedEvent: Identifiable {
    case message(MessageEvent)
    case connectionRequest(ConnectionRequestEvent)
    case authRequest(AuthRequestEvent)
    case vaultActivity(VaultActivityEvent)
    case transferRequest(TransferRequestEvent)

    var id: String {
        switch self {
        case .message(let e): return e.id
        case .connectionRequest(let e): return e.id
        case .authRequest(let e): return e.id
        case .vaultActivity(let e): return e.id
        case .transferRequest(let e): return e.id
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let e): return e.timestamp
        case .connectionRequest(let e): return e.timestamp
        case .authRequest(let e): return e.timestamp
        case .vaultActivity(let e): return e.timestamp
        case .transferRequest(let e): return e.timestamp
        }
    }

    var isRead: Bool {
        switch self {
        case .message(let e): return e.isRead
        case .connectionRequest(let e): return e.isRead
        case .authRequest(let e): return e.isRead
        case .vaultActivity(let e): return e.isRead
        case .transferRequest(let e): return e.isRead
        }
    }
}

// MARK: - Transfer Request Event

struct TransferRequestEvent: Identifiable {
    let id: String
    let senderName: String
    let amountSats: Int64
    let walletId: String?
    let connectionId: String
    let timestamp: Date
    var isRead: Bool

    var amountBtc: Double {
        Double(amountSats) / 100_000_000.0
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
        case backupRestored = "backup_restored"
        case credentialAdded = "credential_added"
        case keysRefreshed = "keys_refreshed"
        case agentConnected = "agent_connected"
        case agentDisconnected = "agent_disconnected"
        case devicePaired = "device_paired"
        case deviceRevoked = "device_revoked"
        case handlerRegistered = "handler_registered"
        case handlerRemoved = "handler_removed"
        case transferInitiated = "transfer_initiated"
        case transferCompleted = "transfer_completed"

        var icon: String {
            switch self {
            case .vaultStarted: return "play.circle.fill"
            case .vaultStopped: return "stop.circle.fill"
            case .backupCreated: return "externaldrive.fill"
            case .backupRestored: return "arrow.down.circle.fill"
            case .credentialAdded: return "key.fill"
            case .keysRefreshed: return "arrow.triangle.2.circlepath"
            case .agentConnected: return "cpu.fill"
            case .agentDisconnected: return "cpu"
            case .devicePaired: return "desktopcomputer"
            case .deviceRevoked: return "xmark.rectangle.fill"
            case .handlerRegistered: return "puzzlepiece.fill"
            case .handlerRemoved: return "puzzlepiece"
            case .transferInitiated: return "arrow.right.arrow.left.circle.fill"
            case .transferCompleted: return "checkmark.circle.fill"
            }
        }

        var color: String {
            switch self {
            case .vaultStarted: return "green"
            case .vaultStopped: return "orange"
            case .backupCreated: return "blue"
            case .backupRestored: return "blue"
            case .credentialAdded: return "purple"
            case .keysRefreshed: return "teal"
            case .agentConnected: return "purple"
            case .agentDisconnected: return "orange"
            case .devicePaired: return "green"
            case .deviceRevoked: return "orange"
            case .handlerRegistered: return "teal"
            case .handlerRemoved: return "orange"
            case .transferInitiated: return "blue"
            case .transferCompleted: return "green"
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
