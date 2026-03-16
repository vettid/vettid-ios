import Foundation

// MARK: - Connected Device

/// Represents a device connected to the user's vault
struct ConnectedDevice: Identifiable, Equatable {
    let connectionId: String
    let deviceName: String
    let hostname: String?
    let platform: String?
    let status: DeviceConnectionStatus
    let sessionId: String?
    let sessionStatus: SessionStatus?
    let sessionExpires: Date?
    let connectedAt: Date
    let lastActiveAt: Date

    var id: String { connectionId }

    /// Whether this device's session is currently active
    var isSessionActive: Bool {
        guard let sessionStatus = sessionStatus else { return false }
        return sessionStatus == .active
    }

    /// Whether this device's session is expiring soon (within 30 minutes)
    var isSessionExpiringSoon: Bool {
        guard let expires = sessionExpires else { return false }
        return expires.timeIntervalSinceNow > 0 && expires.timeIntervalSinceNow < 30 * 60
    }

    /// Formatted time remaining until session expires
    var sessionTimeRemaining: String? {
        guard let expires = sessionExpires else { return nil }
        let remaining = expires.timeIntervalSinceNow
        guard remaining > 0 else { return "Expired" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Platform icon name for SF Symbols
    var platformIcon: String {
        switch platform?.lowercased() {
        case "ios": return "iphone"
        case "android": return "candybarphone"
        case "desktop", "macos", "windows", "linux": return "desktopcomputer"
        case "web": return "globe"
        default: return "laptopcomputer.and.iphone"
        }
    }

    // MARK: - Parsing

    /// Parse a ConnectedDevice from a vault response dictionary
    static func from(dict: [String: Any]) -> ConnectedDevice? {
        guard let connectionId = dict["connection_id"] as? String,
              let deviceName = dict["device_name"] as? String else {
            return nil
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()

        func parseDate(_ value: Any?) -> Date {
            guard let string = value as? String else { return Date() }
            return dateFormatter.date(from: string)
                ?? fallbackFormatter.date(from: string)
                ?? Date()
        }

        func parseDateOptional(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return dateFormatter.date(from: string)
                ?? fallbackFormatter.date(from: string)
        }

        let statusString = dict["status"] as? String ?? "active"
        let sessionStatusString = dict["session_status"] as? String

        return ConnectedDevice(
            connectionId: connectionId,
            deviceName: deviceName,
            hostname: dict["hostname"] as? String,
            platform: dict["platform"] as? String,
            status: DeviceConnectionStatus(rawValue: statusString) ?? .active,
            sessionId: dict["session_id"] as? String,
            sessionStatus: sessionStatusString.flatMap { SessionStatus(rawValue: $0) },
            sessionExpires: parseDateOptional(dict["session_expires"]),
            connectedAt: parseDate(dict["connected_at"]),
            lastActiveAt: parseDate(dict["last_active_at"])
        )
    }
}

// MARK: - Device Connection Status

enum DeviceConnectionStatus: String, Equatable {
    case active
    case inactive
    case revoked
    case pending

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Session Status

enum SessionStatus: String, Equatable {
    case active
    case expired
    case revoked

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Device Management State

enum DeviceManagementState: Equatable {
    case loading
    case loaded([ConnectedDevice])
    case empty
    case error(String)

    static func == (lhs: DeviceManagementState, rhs: DeviceManagementState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty):
            return true
        case (.loaded(let a), .loaded(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Device Pairing State

enum DevicePairingState: Equatable {
    case idle
    case creating
    case showingCode(inviteCode: String, expiresAt: Date)
    case waitingApproval
    case approved
    case denied
    case timeout
    case error(String)

    static func == (lhs: DevicePairingState, rhs: DevicePairingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.creating, .creating),
             (.waitingApproval, .waitingApproval),
             (.approved, .approved), (.denied, .denied),
             (.timeout, .timeout):
            return true
        case (.showingCode(let a1, let a2), .showingCode(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Device Approval State

enum DeviceApprovalState: Equatable {
    case loading
    case ready(DeviceApprovalInfo)
    case processingApproval
    case processingDenial
    case approved
    case denied
    case timeout
    case error(String)

    static func == (lhs: DeviceApprovalState, rhs: DeviceApprovalState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading),
             (.processingApproval, .processingApproval),
             (.processingDenial, .processingDenial),
             (.approved, .approved), (.denied, .denied),
             (.timeout, .timeout):
            return true
        case (.ready(let a), .ready(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Device Approval Info

/// Wraps DeviceApprovalRequest with Equatable conformance for state usage
struct DeviceApprovalInfo: Equatable {
    let requestId: String
    let connectionId: String
    let deviceName: String
    let operation: String?
    let secretCategory: String?
    let timestamp: Date?

    init(from request: DeviceApprovalRequest) {
        self.requestId = request.requestId
        self.connectionId = request.connectionId
        self.deviceName = request.deviceName
        self.operation = request.operation
        self.secretCategory = request.secretCategory

        if let ts = request.timestamp {
            let formatter = ISO8601DateFormatter()
            self.timestamp = formatter.date(from: ts)
        } else {
            self.timestamp = nil
        }
    }
}

// MARK: - Device Management Constants

enum DeviceConstants {
    /// Heartbeat interval in seconds
    static let heartbeatInterval: TimeInterval = 120

    /// Pairing code expiration in seconds (5 minutes)
    static let pairingCodeExpiration: TimeInterval = 300

    /// Approval timeout in seconds (2 minutes)
    static let approvalTimeout: TimeInterval = 120
}
