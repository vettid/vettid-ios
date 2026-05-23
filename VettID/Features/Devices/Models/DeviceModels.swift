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

// MARK: - Authorize Device (Stage-2 pairing)

/// Metadata shown to the user when they authorize a new desktop
/// session. Mirrors Android `PendingDeviceInfo`. The desktop's
/// fingerprints are surfaced verbatim so the user can compare them
/// bit-for-bit against the desktop's own Settings → Device tab.
struct PendingDeviceInfo: Equatable {
    let connectionId: String
    let hostname: String
    let platform: String
    let osName: String
    let osVersion: String
    let appVersion: String
    let clientIp: String
    let binaryFingerprint: String
    let machineFingerprint: String
    let defaultDurationSeconds: Int
    let maxDurationSeconds: Int

    static func from(notification: DevicePendingAuthNotification) -> PendingDeviceInfo {
        PendingDeviceInfo(
            connectionId: notification.connectionId,
            hostname: notification.deviceMetadata?.hostname ?? "",
            platform: notification.deviceMetadata?.platform ?? "",
            osName: notification.deviceMetadata?.osName ?? "",
            osVersion: notification.deviceMetadata?.osVersion ?? "",
            appVersion: notification.deviceMetadata?.appVersion ?? "",
            clientIp: notification.deviceMetadata?.clientIp ?? "",
            binaryFingerprint: notification.deviceMetadata?.binaryFingerprint ?? "",
            machineFingerprint: notification.deviceMetadata?.machineFingerprint ?? "",
            defaultDurationSeconds: notification.defaultDurationSeconds,
            maxDurationSeconds: notification.maxDurationSeconds
        )
    }

    /// Conservative defaults when the user scans the QR before the
    /// vault's pending-authorization notification arrives. The vault
    /// separately enforces its own session-duration policy, so these
    /// are display-time suggestions, not the source of truth. Matches
    /// Android `DEFAULT_FALLBACK_DURATION_S` / `MAX_FALLBACK_DURATION_S`.
    static func fallback(connectionId: String) -> PendingDeviceInfo {
        PendingDeviceInfo(
            connectionId: connectionId,
            hostname: "",
            platform: "",
            osName: "",
            osVersion: "",
            appVersion: "",
            clientIp: "",
            binaryFingerprint: "",
            machineFingerprint: "",
            defaultDurationSeconds: 24 * 60 * 60,
            maxDurationSeconds: 30 * 24 * 60 * 60
        )
    }
}

/// QR payload shown by the desktop at Stage-2 — user scans this in the
/// app. JSON shape on the wire: `{"t":"<64-hex token>","c":"<conn id>"}`.
struct ScannedDeviceAuthQr: Equatable {
    let approvalToken: String
    let connectionId: String

    /// Decode the JSON-encoded QR payload. Validates the token is the
    /// expected 64-hex length and that the connection_id is non-empty;
    /// returns nil on any other shape.
    static func parse(_ text: String) -> ScannedDeviceAuthQr? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["t"] as? String,
              let conn  = json["c"] as? String,
              token.count == 64,
              !conn.isEmpty
        else { return nil }
        return ScannedDeviceAuthQr(approvalToken: token, connectionId: conn)
    }
}

/// Existing-session summary surfaced in the ConfirmReplace prompt.
/// Mirrors Android `ExistingDeviceSummary`.
struct ExistingDeviceSummary: Equatable, Identifiable {
    let connectionId: String
    let deviceName: String
    let lastActiveAt: Int
    let expiresAt: Int

    var id: String { connectionId }
}

enum AuthorizeDeviceState: Equatable {
    case scanning
    case ready(scanned: ScannedDeviceAuthQr, info: PendingDeviceInfo, deviceName: String, durationSeconds: Int)
    case submitting
    case confirmReplace(scanned: ScannedDeviceAuthQr, info: PendingDeviceInfo, deviceName: String, durationSeconds: Int, existingDevices: [ExistingDeviceSummary])
    case done
    case error(String)
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
