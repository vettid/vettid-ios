import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Transfer State

/// State machine for device transfer flow
enum TransferState: Equatable {
    /// No active transfer
    case idle

    /// Requesting transfer from another device (new device flow)
    case requesting

    /// Waiting for approval from old device (new device flow)
    case waitingForApproval(transferId: String, expiresAt: Date)

    /// Received a transfer request to approve (old device flow)
    case pendingApproval(request: TransferRequestedEvent)

    /// Transfer was approved
    case approved(transferId: String)

    /// Transfer was denied
    case denied(transferId: String)

    /// Transfer request expired
    case expired(transferId: String)

    /// Transfer completed successfully
    case completed(transferId: String)

    /// Error during transfer
    case error(message: String)

    // MARK: - Equatable

    static func == (lhs: TransferState, rhs: TransferState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.requesting, .requesting):
            return true
        case (.waitingForApproval(let id1, let date1), .waitingForApproval(let id2, let date2)):
            return id1 == id2 && date1 == date2
        case (.pendingApproval(let req1), .pendingApproval(let req2)):
            return req1 == req2
        case (.approved(let id1), .approved(let id2)):
            return id1 == id2
        case (.denied(let id1), .denied(let id2)):
            return id1 == id2
        case (.expired(let id1), .expired(let id2)):
            return id1 == id2
        case (.completed(let id1), .completed(let id2)):
            return id1 == id2
        case (.error(let msg1), .error(let msg2)):
            return msg1 == msg2
        default:
            return false
        }
    }
}

// MARK: - Transfer Request (Outgoing)

/// Request to initiate a transfer from another device
struct TransferInitiationRequest: Codable {
    let requestId: String
    let sourceDeviceInfo: DeviceInfo
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sourceDeviceInfo = "source_device_info"
        case timestamp
    }
}

// MARK: - Transfer Response

/// Response to a transfer request
struct TransferResponse: Codable {
    let transferId: String
    let approved: Bool
    let reason: String?
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case approved
        case reason
        case timestamp
    }
}

// MARK: - Transfer Credential Payload

/// Encrypted credential payload sent during approved transfer
struct TransferCredentialPayload: Codable {
    let transferId: String
    let encryptedCredential: String
    let publicKey: String
    let signature: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case encryptedCredential = "encrypted_credential"
        case publicKey = "public_key"
        case signature
        case timestamp
    }
}

// MARK: - Device Info Helpers

extension DeviceInfo {
    /// Create DeviceInfo for the current device
    static func current() -> DeviceInfo {
        #if os(iOS)
        let device = UIDevice.current
        return DeviceInfo(
            deviceId: device.identifierForVendor?.uuidString ?? UUID().uuidString,
            model: device.model,
            osVersion: "\(device.systemName) \(device.systemVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            location: nil // Location would be populated separately if available
        )
        #else
        return DeviceInfo(
            deviceId: UUID().uuidString,
            model: "Unknown",
            osVersion: "Unknown",
            appVersion: nil,
            location: nil
        )
        #endif
    }
}

// MARK: - Transfer Timeouts

enum TransferTimeout {
    /// Default transfer request expiration (15 minutes)
    static let requestExpiration: TimeInterval = 15 * 60

    /// Warning threshold before expiration (2 minutes)
    static let warningThreshold: TimeInterval = 2 * 60

    /// Minimum time required to complete transfer
    static let minimumRequired: TimeInterval = 30
}

// MARK: - Transfer Error

enum TransferError: LocalizedError {
    case notAuthenticated
    case transferAlreadyPending
    case transferNotFound
    case transferExpired
    case biometricFailed
    case networkError(String)
    case encryptionError
    case invalidCredential
    case deviceMismatch

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be authenticated to transfer credentials"
        case .transferAlreadyPending:
            return "A transfer is already in progress"
        case .transferNotFound:
            return "Transfer request not found"
        case .transferExpired:
            return "Transfer request has expired"
        case .biometricFailed:
            return "Biometric authentication failed"
        case .networkError(let message):
            return "Network error: \(message)"
        case .encryptionError:
            return "Failed to encrypt credential for transfer"
        case .invalidCredential:
            return "Invalid credential data received"
        case .deviceMismatch:
            return "Device verification failed"
        }
    }
}
