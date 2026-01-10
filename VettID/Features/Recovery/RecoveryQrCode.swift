import Foundation

// MARK: - Recovery QR Code

/// Recovery QR code content as displayed by the Account Portal.
///
/// After the 24-hour security delay, the Account Portal displays a QR code
/// containing recovery information that the app scans to restore credentials.
///
/// QR Code Format:
/// ```json
/// {
///   "type": "vettid_recovery",
///   "token": "recovery_token_here",
///   "vault": "nats://vault.vettid.dev:4222",
///   "nonce": "random_nonce",
///   "owner_space": "user.abc123",
///   "credentials": "-----BEGIN NATS USER JWT-----\n..."
/// }
/// ```
struct RecoveryQrCode: Codable, Equatable {
    let type: String
    let token: String
    let vault: String
    let nonce: String
    let ownerSpace: String
    let credentials: String

    enum CodingKeys: String, CodingKey {
        case type
        case token
        case vault
        case nonce
        case ownerSpace = "owner_space"
        case credentials
    }

    // MARK: - Constants

    static let expectedType = "vettid_recovery"

    // MARK: - Parsing

    /// Parse QR code content into RecoveryQrCode.
    ///
    /// - Parameter content: Raw QR code content (JSON string)
    /// - Returns: Parsed RecoveryQrCode or nil if invalid
    static func parse(_ content: String) -> RecoveryQrCode? {
        guard let data = content.data(using: .utf8) else {
            #if DEBUG
            print("[RecoveryQrCode] Failed to convert content to data")
            #endif
            return nil
        }

        do {
            let qrCode = try JSONDecoder().decode(RecoveryQrCode.self, from: data)

            // Validate type
            guard qrCode.type == expectedType else {
                #if DEBUG
                print("[RecoveryQrCode] Invalid QR code type: \(qrCode.type) (expected \(expectedType))")
                #endif
                return nil
            }

            // Validate required fields are not empty
            guard !qrCode.token.isEmpty,
                  !qrCode.vault.isEmpty,
                  !qrCode.nonce.isEmpty,
                  !qrCode.ownerSpace.isEmpty,
                  !qrCode.credentials.isEmpty else {
                #if DEBUG
                print("[RecoveryQrCode] Missing required fields in recovery QR code")
                #endif
                return nil
            }

            return qrCode
        } catch {
            #if DEBUG
            print("[RecoveryQrCode] Failed to parse recovery QR code: \(error)")
            #endif
            return nil
        }
    }

    /// Validate if a string looks like a VettID recovery QR code.
    /// Quick check before full parsing.
    static func isRecoveryQrCode(_ content: String) -> Bool {
        return content.contains("\"type\"") &&
               content.contains("\"vettid_recovery\"") &&
               content.contains("\"token\"")
    }

    // MARK: - NATS Helpers

    /// Extract NATS endpoint from vault URL.
    /// Converts "nats://vault.vettid.dev:4222" to "vault.vettid.dev:4222"
    var natsEndpoint: String {
        var endpoint = vault
        endpoint = endpoint.replacingOccurrences(of: "nats://", with: "")
        endpoint = endpoint.replacingOccurrences(of: "tls://", with: "")
        return endpoint
    }

    /// Get the topic for recovery request.
    /// Format: {ownerSpace}.forVault.recovery.claim
    var recoveryTopic: String {
        return "\(ownerSpace).forVault.recovery.claim"
    }

    /// Get the topic for recovery response.
    /// Format: {ownerSpace}.forApp.recovery.result
    var responseTopic: String {
        return "\(ownerSpace).forApp.recovery.result"
    }

    /// Parse NATS credentials from the credential file content.
    /// Returns (jwt, seed) tuple or nil if parsing fails.
    func parseNatsCredentials() -> (jwt: String, seed: String)? {
        // Extract JWT
        guard let jwtStartRange = credentials.range(of: "-----BEGIN NATS USER JWT-----"),
              let jwtEndRange = credentials.range(of: "-----END NATS USER JWT-----") else {
            #if DEBUG
            print("[RecoveryQrCode] Failed to find JWT markers")
            #endif
            return nil
        }

        let jwtContent = credentials[jwtStartRange.upperBound..<jwtEndRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract NKEY seed
        guard let seedStartRange = credentials.range(of: "-----BEGIN USER NKEY SEED-----"),
              let seedEndRange = credentials.range(of: "-----END USER NKEY SEED-----") else {
            #if DEBUG
            print("[RecoveryQrCode] Failed to find seed markers")
            #endif
            return nil
        }

        let seedContent = credentials[seedStartRange.upperBound..<seedEndRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !jwtContent.isEmpty, !seedContent.isEmpty else {
            #if DEBUG
            print("[RecoveryQrCode] JWT or seed content is empty")
            #endif
            return nil
        }

        return (jwt: String(jwtContent), seed: String(seedContent))
    }
}

// MARK: - Recovery Exchange Result

/// Result of recovery token exchange via NATS.
struct RecoveryExchangeResult: Codable, Equatable {
    let success: Bool
    let message: String
    let credentials: String?
    let natsEndpoint: String?
    let ownerSpace: String?
    let messageSpace: String?
    let credentialId: String?
    let userGuid: String?
    let credentialVersion: Int?
    let sealedCredential: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case credentials
        case natsEndpoint = "nats_endpoint"
        case ownerSpace = "owner_space"
        case messageSpace = "message_space"
        case credentialId = "credential_id"
        case userGuid = "user_guid"
        case credentialVersion = "credential_version"
        case sealedCredential = "sealed_credential"
    }

    init(
        success: Bool,
        message: String,
        credentials: String? = nil,
        natsEndpoint: String? = nil,
        ownerSpace: String? = nil,
        messageSpace: String? = nil,
        credentialId: String? = nil,
        userGuid: String? = nil,
        credentialVersion: Int? = nil,
        sealedCredential: String? = nil
    ) {
        self.success = success
        self.message = message
        self.credentials = credentials
        self.natsEndpoint = natsEndpoint
        self.ownerSpace = ownerSpace
        self.messageSpace = messageSpace
        self.credentialId = credentialId
        self.userGuid = userGuid
        self.credentialVersion = credentialVersion
        self.sealedCredential = sealedCredential
    }
}

// MARK: - QR Recovery Error

enum QrRecoveryError: Error, LocalizedError, Equatable {
    case invalidQrCode
    case invalidCredentials
    case connectionFailed(String)
    case subscriptionFailed(String)
    case publishFailed(String)
    case exchangeTimeout
    case exchangeFailed(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidQrCode:
            return "Invalid recovery QR code. Please scan a valid VettID recovery QR code."
        case .invalidCredentials:
            return "Failed to parse recovery credentials from QR code."
        case .connectionFailed(let message):
            return "Failed to connect to vault: \(message)"
        case .subscriptionFailed(let message):
            return "Failed to subscribe: \(message)"
        case .publishFailed(let message):
            return "Failed to send recovery request: \(message)"
        case .exchangeTimeout:
            return "Recovery exchange timed out. Please try again."
        case .exchangeFailed(let message):
            return "Recovery exchange failed: \(message)"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        }
    }
}
