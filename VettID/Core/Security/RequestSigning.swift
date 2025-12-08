import Foundation
import CryptoKit

/// Request signing and replay protection
/// Implements HMAC-based request signing with timestamp and nonce
final class RequestSigner {

    // MARK: - Configuration

    /// Header names for signed requests
    enum Header {
        static let timestamp = "X-VettID-Timestamp"
        static let nonce = "X-VettID-Nonce"
        static let signature = "X-VettID-Signature"
        static let deviceId = "X-VettID-Device-ID"
    }

    /// Maximum age of a request in seconds (for replay protection)
    private let maxRequestAge: TimeInterval = 300  // 5 minutes

    /// Device ID for this device
    private let deviceId: String

    // MARK: - Initialization

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    // MARK: - Request Signing

    /// Sign a URLRequest with timestamp, nonce, and HMAC signature
    /// - Parameters:
    ///   - request: The request to sign
    ///   - signingKey: The key to use for HMAC (typically derived from user credentials)
    /// - Returns: A new URLRequest with signing headers added
    func signRequest(_ request: URLRequest, with signingKey: SymmetricKey) -> URLRequest {
        var signedRequest = request

        // Generate timestamp and nonce
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = generateNonce()

        // Add headers
        signedRequest.setValue(timestamp, forHTTPHeaderField: Header.timestamp)
        signedRequest.setValue(nonce, forHTTPHeaderField: Header.nonce)
        signedRequest.setValue(deviceId, forHTTPHeaderField: Header.deviceId)

        // Create signature
        let signature = createSignature(
            request: request,
            timestamp: timestamp,
            nonce: nonce,
            signingKey: signingKey
        )
        signedRequest.setValue(signature, forHTTPHeaderField: Header.signature)

        return signedRequest
    }

    /// Create HMAC signature for request
    private func createSignature(
        request: URLRequest,
        timestamp: String,
        nonce: String,
        signingKey: SymmetricKey
    ) -> String {
        // Build canonical request string
        let canonicalRequest = buildCanonicalRequest(
            request: request,
            timestamp: timestamp,
            nonce: nonce
        )

        // Compute HMAC-SHA256
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(canonicalRequest.utf8),
            using: signingKey
        )

        return Data(signature).base64EncodedString()
    }

    /// Build canonical request string for signing
    /// Format: METHOD\nPATH\nQUERY\nTIMESTAMP\nNONCE\nDEVICE_ID\nBODY_HASH
    private func buildCanonicalRequest(
        request: URLRequest,
        timestamp: String,
        nonce: String
    ) -> String {
        var components: [String] = []

        // HTTP method
        components.append(request.httpMethod ?? "GET")

        // Path
        components.append(request.url?.path ?? "/")

        // Query string (sorted alphabetically)
        if let query = request.url?.query {
            let sortedQuery = query.split(separator: "&")
                .sorted()
                .joined(separator: "&")
            components.append(sortedQuery)
        } else {
            components.append("")
        }

        // Timestamp
        components.append(timestamp)

        // Nonce
        components.append(nonce)

        // Device ID
        components.append(deviceId)

        // Body hash (SHA-256 of body or empty string)
        if let body = request.httpBody, !body.isEmpty {
            let bodyHash = SHA256.hash(data: body)
            components.append(Data(bodyHash).base64EncodedString())
        } else {
            components.append("")
        }

        return components.joined(separator: "\n")
    }

    /// Generate a cryptographically secure random nonce
    private func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Replay Protection (for server-side validation reference)

    /// Validate a request timestamp is within acceptable range
    /// Note: This is primarily for reference - actual replay protection happens server-side
    func isTimestampValid(_ timestamp: String) -> Bool {
        guard let timestampInt = Int(timestamp) else {
            return false
        }

        let requestTime = Date(timeIntervalSince1970: TimeInterval(timestampInt))
        let age = abs(Date().timeIntervalSince(requestTime))

        return age <= maxRequestAge
    }
}

// MARK: - Signing Key Derivation

extension RequestSigner {

    /// Derive a signing key from user credentials
    /// Uses HKDF to derive a separate key for request signing
    static func deriveSigningKey(from masterKey: SymmetricKey, salt: Data? = nil) -> SymmetricKey {
        let info = "VettID-Request-Signing-v1".data(using: .utf8)!
        let saltData = salt ?? Data(repeating: 0, count: 32)

        // Use HKDF to derive a signing key
        return SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: saltData,
            info: info,
            outputByteCount: 32
        ))
    }
}

// MARK: - Request Validation Errors

enum RequestSigningError: Error, LocalizedError {
    case missingTimestamp
    case missingNonce
    case missingSignature
    case invalidTimestamp
    case expiredRequest
    case invalidSignature
    case replayedRequest

    var errorDescription: String? {
        switch self {
        case .missingTimestamp:
            return "Request is missing timestamp header"
        case .missingNonce:
            return "Request is missing nonce header"
        case .missingSignature:
            return "Request is missing signature header"
        case .invalidTimestamp:
            return "Request timestamp is invalid"
        case .expiredRequest:
            return "Request has expired"
        case .invalidSignature:
            return "Request signature is invalid"
        case .replayedRequest:
            return "Request appears to be a replay attack"
        }
    }
}
