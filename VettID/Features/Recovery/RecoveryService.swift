import Foundation

/// Service for handling credential recovery via QR code
/// Per Architecture v2.0 Section 5.18, recovery flow:
/// 1. User initiates recovery on Account Portal
/// 2. After 24h delay, Account Portal displays QR code
/// 3. App scans QR code containing recovery token
/// 4. App sends token to vault via NATS
/// 5. Vault returns new credential
actor RecoveryService {

    private let apiBaseURL: String
    private let session: URLSession

    init(apiBaseURL: String = "https://api.vettid.dev") {
        self.apiBaseURL = apiBaseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Exchange recovery token for new credential
    /// - Parameters:
    ///   - qrCode: Parsed recovery QR code
    ///   - deviceId: Device identifier
    ///   - newPassword: New password for the recovered credential
    /// - Returns: Recovery response with new credential
    func exchangeRecoveryToken(
        qrCode: RecoveryQRCode,
        deviceId: String,
        newPassword: String
    ) async throws -> RecoveryTokenResponse {

        // Generate password hash and salt
        let salt = generateSalt()
        let passwordHash = hashPassword(newPassword, salt: salt)

        let request = RecoveryTokenRequest(
            token: qrCode.token,
            nonce: qrCode.nonce,
            deviceId: deviceId,
            deviceType: "ios",
            newPasswordHash: passwordHash,
            passwordSalt: salt
        )

        // Determine endpoint - use vault URL from QR code or fallback to API
        let endpoint = "\(apiBaseURL)/vault/recovery/exchange"

        guard let url = URL(string: endpoint) else {
            throw RecoveryError.networkError
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RecoveryError.networkError
            }

            if httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(RecoveryTokenResponse.self, from: data)
            } else if httpResponse.statusCode == 400 {
                // Try to decode error response
                if let errorResponse = try? JSONDecoder().decode(RecoveryTokenResponse.self, from: data),
                   let error = errorResponse.error {
                    throw RecoveryError.tokenExchangeFailed(error)
                }
                throw RecoveryError.tokenExchangeFailed("Invalid request")
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw RecoveryError.tokenExchangeFailed("Recovery token is invalid or expired")
            } else {
                throw RecoveryError.tokenExchangeFailed("Server error: \(httpResponse.statusCode)")
            }
        } catch let error as RecoveryError {
            throw error
        } catch {
            print("[RecoveryService] Network error: \(error)")
            throw RecoveryError.networkError
        }
    }

    /// Exchange recovery token via NATS (direct vault communication)
    /// This is the preferred method per Architecture v2.0
    /// - Parameters:
    ///   - qrCode: Parsed recovery QR code
    ///   - deviceId: Device identifier
    ///   - newPassword: New password for the recovered credential
    ///   - natsClient: NATS client for vault communication
    /// - Returns: Recovery response with new credential
    func exchangeRecoveryTokenViaNATS(
        qrCode: RecoveryQRCode,
        deviceId: String,
        newPassword: String,
        publish: @escaping (String, Data) async throws -> Data
    ) async throws -> RecoveryTokenResponse {

        // Generate password hash and salt
        let salt = generateSalt()
        let passwordHash = hashPassword(newPassword, salt: salt)

        let request = RecoveryTokenRequest(
            token: qrCode.token,
            nonce: qrCode.nonce,
            deviceId: deviceId,
            deviceType: "ios",
            newPasswordHash: passwordHash,
            passwordSalt: salt
        )

        // NATS subject for recovery
        // Format: vault.recovery.{token_prefix}
        let tokenPrefix = String(qrCode.token.prefix(8))
        let subject = "vault.recovery.\(tokenPrefix)"

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        do {
            let responseData = try await publish(subject, requestData)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(RecoveryTokenResponse.self, from: responseData)

            if response.success {
                return response
            } else {
                throw RecoveryError.tokenExchangeFailed(response.error ?? "Unknown error")
            }
        } catch let error as RecoveryError {
            throw error
        } catch {
            print("[RecoveryService] NATS error: \(error)")
            throw RecoveryError.networkError
        }
    }

    // MARK: - Private Helpers

    private func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private func hashPassword(_ password: String, salt: String) -> String {
        // Use PBKDF2 for password hashing
        // In production, this would use Argon2id via the PasswordHasher
        guard let passwordData = password.data(using: .utf8),
              let saltData = Data(base64Encoded: salt) else {
            return ""
        }

        var derivedKey = [UInt8](repeating: 0, count: 32)

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password,
            passwordData.count,
            [UInt8](saltData),
            saltData.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            100_000,
            &derivedKey,
            derivedKey.count
        )

        guard status == kCCSuccess else {
            return ""
        }

        return Data(derivedKey).base64EncodedString()
    }
}

// CommonCrypto import for PBKDF2
import CommonCrypto
