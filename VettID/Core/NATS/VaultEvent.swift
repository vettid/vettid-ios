import Foundation

// MARK: - Security Event Types

/// Events received from the vault via NATS for security notifications
/// These events are used to alert users about recovery attempts, device transfers,
/// and potential fraud detection scenarios.
enum VaultSecurityEvent: Equatable {
    // MARK: - Recovery Events

    /// A recovery request has been initiated for this credential
    case recoveryRequested(RecoveryRequestedEvent)

    /// A recovery request was cancelled (by user or system)
    case recoveryCancelled(RecoveryCancelledEvent)

    /// A recovery was successfully completed
    case recoveryCompleted(RecoveryCompletedEvent)

    // MARK: - Transfer Events

    /// A new device is requesting credential transfer
    case transferRequested(TransferRequestedEvent)

    /// Transfer was approved by the user
    case transferApproved(TransferApprovedEvent)

    /// Transfer was denied by the user
    case transferDenied(TransferDeniedEvent)

    /// Transfer completed successfully
    case transferCompleted(TransferCompletedEvent)

    /// Transfer request expired without action
    case transferExpired(TransferExpiredEvent)

    // MARK: - Fraud Detection

    /// Potential fraud detected - recovery cancelled due to credential use
    case recoveryFraudDetected(RecoveryFraudDetectedEvent)
}

// MARK: - Recovery Event Details

struct RecoveryRequestedEvent: Codable, Equatable {
    let requestId: String
    let email: String?
    let requestedAt: Date
    let expiresAt: Date?
    let sourceIp: String?
    let userAgent: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case email
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
        case sourceIp = "source_ip"
        case userAgent = "user_agent"
    }
}

struct RecoveryCancelledEvent: Codable, Equatable {
    let requestId: String
    let reason: RecoveryCancelReason?
    let cancelledAt: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case reason
        case cancelledAt = "cancelled_at"
    }
}

enum RecoveryCancelReason: String, Codable, Equatable {
    case userCancelled = "user_cancelled"
    case expired = "expired"
    case fraudDetected = "fraud_detected"
    case adminCancelled = "admin_cancelled"
    case systemError = "system_error"
}

struct RecoveryCompletedEvent: Codable, Equatable {
    let requestId: String
    let completedAt: Date
    let newDeviceId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case completedAt = "completed_at"
        case newDeviceId = "new_device_id"
    }
}

// MARK: - Transfer Event Details

struct TransferRequestedEvent: Codable, Equatable {
    let transferId: String
    let sourceDeviceId: String?
    let targetDeviceInfo: DeviceInfo
    let requestedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case sourceDeviceId = "source_device_id"
        case targetDeviceInfo = "target_device_info"
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
    }
}

struct TransferApprovedEvent: Codable, Equatable {
    let transferId: String
    let approvedAt: Date

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case approvedAt = "approved_at"
    }
}

struct TransferDeniedEvent: Codable, Equatable {
    let transferId: String
    let deniedAt: Date
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case deniedAt = "denied_at"
        case reason
    }
}

struct TransferCompletedEvent: Codable, Equatable {
    let transferId: String
    let completedAt: Date
    let targetDeviceId: String

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case completedAt = "completed_at"
        case targetDeviceId = "target_device_id"
    }
}

struct TransferExpiredEvent: Codable, Equatable {
    let transferId: String
    let expiredAt: Date

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case expiredAt = "expired_at"
    }
}

// MARK: - Fraud Detection Event Details

struct RecoveryFraudDetectedEvent: Codable, Equatable {
    let requestId: String
    let reason: FraudDetectionReason
    let detectedAt: Date
    let credentialUsedAt: Date?
    let usageDetails: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case reason
        case detectedAt = "detected_at"
        case credentialUsedAt = "credential_used_at"
        case usageDetails = "usage_details"
    }
}

enum FraudDetectionReason: String, Codable, Equatable {
    /// Credential was used while recovery was pending
    case credentialUsedDuringRecovery = "credential_used_during_recovery"
    /// Multiple recovery attempts from different locations
    case multipleRecoveryAttempts = "multiple_recovery_attempts"
    /// Suspicious activity pattern detected
    case suspiciousActivity = "suspicious_activity"
}

// MARK: - Device Info

/// Information about a device requesting transfer
struct DeviceInfo: Codable, Equatable {
    let deviceId: String
    let model: String
    let osVersion: String
    let appVersion: String?
    let location: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case model
        case osVersion = "os_version"
        case appVersion = "app_version"
        case location
    }

    /// Human-readable description of the device
    var displayName: String {
        "\(model) (\(osVersion))"
    }
}

// MARK: - NATS Message Parsing

/// Raw security event message from NATS
struct SecurityEventMessage: Decodable {
    let eventId: String
    let eventType: String
    let timestamp: Date
    let data: SecurityEventData

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case timestamp
        case data
    }
}

/// Union type for event data payload
enum SecurityEventData: Decodable {
    case recoveryRequested(RecoveryRequestedEvent)
    case recoveryCancelled(RecoveryCancelledEvent)
    case recoveryCompleted(RecoveryCompletedEvent)
    case transferRequested(TransferRequestedEvent)
    case transferApproved(TransferApprovedEvent)
    case transferDenied(TransferDeniedEvent)
    case transferCompleted(TransferCompletedEvent)
    case transferExpired(TransferExpiredEvent)
    case recoveryFraudDetected(RecoveryFraudDetectedEvent)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try each event type
        if let event = try? container.decode(RecoveryRequestedEvent.self),
           event.requestId.isEmpty == false {
            self = .recoveryRequested(event)
        } else if let event = try? container.decode(RecoveryCancelledEvent.self) {
            self = .recoveryCancelled(event)
        } else if let event = try? container.decode(RecoveryCompletedEvent.self) {
            self = .recoveryCompleted(event)
        } else if let event = try? container.decode(TransferRequestedEvent.self) {
            self = .transferRequested(event)
        } else if let event = try? container.decode(TransferApprovedEvent.self) {
            self = .transferApproved(event)
        } else if let event = try? container.decode(TransferDeniedEvent.self) {
            self = .transferDenied(event)
        } else if let event = try? container.decode(TransferCompletedEvent.self) {
            self = .transferCompleted(event)
        } else if let event = try? container.decode(TransferExpiredEvent.self) {
            self = .transferExpired(event)
        } else if let event = try? container.decode(RecoveryFraudDetectedEvent.self) {
            self = .recoveryFraudDetected(event)
        } else {
            self = .unknown
        }
    }
}

// MARK: - VaultSecurityEvent Parsing

extension VaultSecurityEvent {

    /// Parse a security event from a NATS message
    static func parse(from message: SecurityEventMessage) -> VaultSecurityEvent? {
        switch message.eventType {
        case "recovery.requested":
            if case .recoveryRequested(let event) = message.data {
                return .recoveryRequested(event)
            }
        case "recovery.cancelled":
            if case .recoveryCancelled(let event) = message.data {
                return .recoveryCancelled(event)
            }
        case "recovery.completed":
            if case .recoveryCompleted(let event) = message.data {
                return .recoveryCompleted(event)
            }
        case "transfer.requested":
            if case .transferRequested(let event) = message.data {
                return .transferRequested(event)
            }
        case "transfer.approved":
            if case .transferApproved(let event) = message.data {
                return .transferApproved(event)
            }
        case "transfer.denied":
            if case .transferDenied(let event) = message.data {
                return .transferDenied(event)
            }
        case "transfer.completed":
            if case .transferCompleted(let event) = message.data {
                return .transferCompleted(event)
            }
        case "transfer.expired":
            if case .transferExpired(let event) = message.data {
                return .transferExpired(event)
            }
        case "security.fraud_detected", "recovery.fraud_detected":
            if case .recoveryFraudDetected(let event) = message.data {
                return .recoveryFraudDetected(event)
            }
        default:
            break
        }
        return nil
    }

    /// Parse directly from JSON data
    static func parse(from data: Data) -> VaultSecurityEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let message = try? decoder.decode(SecurityEventMessage.self, from: data) else {
            return nil
        }

        return parse(from: message)
    }
}

// MARK: - Event Identifiers

extension VaultSecurityEvent {

    /// Unique identifier for the event
    var eventId: String {
        switch self {
        case .recoveryRequested(let e): return "recovery-\(e.requestId)"
        case .recoveryCancelled(let e): return "recovery-\(e.requestId)"
        case .recoveryCompleted(let e): return "recovery-\(e.requestId)"
        case .transferRequested(let e): return "transfer-\(e.transferId)"
        case .transferApproved(let e): return "transfer-\(e.transferId)"
        case .transferDenied(let e): return "transfer-\(e.transferId)"
        case .transferCompleted(let e): return "transfer-\(e.transferId)"
        case .transferExpired(let e): return "transfer-\(e.transferId)"
        case .recoveryFraudDetected(let e): return "fraud-\(e.requestId)"
        }
    }

    /// Whether this event requires immediate user attention
    var requiresImmediateAttention: Bool {
        switch self {
        case .recoveryRequested, .transferRequested, .recoveryFraudDetected:
            return true
        default:
            return false
        }
    }

    /// Category for grouping related events
    var category: SecurityEventCategory {
        switch self {
        case .recoveryRequested, .recoveryCancelled, .recoveryCompleted:
            return .recovery
        case .transferRequested, .transferApproved, .transferDenied, .transferCompleted, .transferExpired:
            return .transfer
        case .recoveryFraudDetected:
            return .fraud
        }
    }
}

enum SecurityEventCategory: String {
    case recovery
    case transfer
    case fraud
}
