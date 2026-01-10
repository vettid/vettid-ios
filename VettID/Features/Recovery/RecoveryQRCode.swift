import Foundation

/// Recovery QR code content per Architecture v2.0 Section 5.18
/// The QR code is displayed on the Account Portal after a 24-hour delay
/// and contains the recovery token for credential restoration.
struct RecoveryQRCode: Codable, Equatable {
    /// QR code type identifier - must be "vettid_recovery"
    let type: String

    /// Recovery token issued by the backend
    let token: String

    /// NATS vault URL for recovery
    let vault: String

    /// Random nonce for replay protection
    let nonce: String

    /// Optional expiration timestamp
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case type
        case token
        case vault
        case nonce
        case expiresAt = "expires_at"
    }

    /// Validates that this is a valid VettID recovery QR code
    var isValid: Bool {
        guard type == "vettid_recovery" else { return false }
        guard !token.isEmpty else { return false }
        guard !vault.isEmpty else { return false }
        guard !nonce.isEmpty else { return false }

        // Check expiration if present
        if let expires = expiresAt, expires < Date() {
            return false
        }

        return true
    }

    /// Parses a QR code string into a RecoveryQRCode
    /// - Parameter qrString: The raw QR code string content
    /// - Returns: A validated RecoveryQRCode or nil if parsing fails
    static func parse(from qrString: String) -> RecoveryQRCode? {
        guard let data = qrString.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let qrCode = try decoder.decode(RecoveryQRCode.self, from: data)
            guard qrCode.isValid else {
                return nil
            }
            return qrCode
        } catch {
            print("[RecoveryQRCode] Failed to parse QR code: \(error)")
            return nil
        }
    }
}

/// Recovery token exchange request
struct RecoveryTokenRequest: Codable {
    /// Recovery token from QR code
    let token: String

    /// Nonce from QR code for replay protection
    let nonce: String

    /// Device identifier requesting recovery
    let deviceId: String

    /// Device type (ios/android)
    let deviceType: String

    /// New password hash for re-encryption
    let newPasswordHash: String

    /// Salt used for password hashing
    let passwordSalt: String

    enum CodingKeys: String, CodingKey {
        case token
        case nonce
        case deviceId = "device_id"
        case deviceType = "device_type"
        case newPasswordHash = "new_password_hash"
        case passwordSalt = "password_salt"
    }
}

/// Recovery token exchange response
struct RecoveryTokenResponse: Codable {
    /// Whether recovery was successful
    let success: Bool

    /// New encrypted credential blob
    let encryptedCredential: String?

    /// User GUID for the recovered account
    let userGuid: String?

    /// Error message if recovery failed
    let error: String?

    /// Recovery completion timestamp
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case success
        case encryptedCredential = "encrypted_credential"
        case userGuid = "user_guid"
        case error
        case completedAt = "completed_at"
    }
}

/// Recovery state for tracking the recovery flow
enum RecoveryState: Equatable {
    case idle
    case scanning
    case validating
    case enteringPassword
    case exchangingToken
    case savingCredential
    case completed(userGuid: String)
    case failed(error: RecoveryError)
}

/// Recovery-specific errors
enum RecoveryError: Error, LocalizedError, Equatable {
    case invalidQRCode
    case qrCodeExpired
    case tokenExchangeFailed(String)
    case credentialSaveFailed
    case networkError
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidQRCode:
            return "Invalid recovery QR code. Please scan a valid VettID recovery code."
        case .qrCodeExpired:
            return "This recovery QR code has expired. Please request a new one from the Account Portal."
        case .tokenExchangeFailed(let message):
            return "Recovery failed: \(message)"
        case .credentialSaveFailed:
            return "Failed to save recovered credentials. Please try again."
        case .networkError:
            return "Network error. Please check your connection and try again."
        case .cancelled:
            return "Recovery was cancelled."
        }
    }
}
