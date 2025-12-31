import Foundation
import CryptoKit

/// API Security features for VettID iOS
///
/// Provides:
/// - Request signing (HMAC-SHA256)
/// - Nonce-based replay protection
/// - Request timestamp validation
/// - Certificate pinning via Info.plist NSPinnedDomains (when custom domain deployed)
///
/// IMPORTANT: AWS API Gateway uses certificates that rotate automatically.
/// Certificate pinning is NOT recommended for API Gateway endpoints without
/// a custom domain with stable certificates.
///
/// Current setup:
/// - ATS enabled (HTTPS only, TLS 1.2+, PFS required)
/// - Certificate pinning prepared for custom domains only
/// - See Info.plist for NSPinnedDomains configuration
actor ApiSecurity {

    // MARK: - Constants

    static let nonceHeader = "X-VettID-Nonce"
    static let timestampHeader = "X-VettID-Timestamp"
    static let signatureHeader = "X-VettID-Signature"
    static let requestIdHeader = "X-VettID-Request-ID"

    /// Maximum age for request timestamp (5 minutes)
    private let maxTimestampAgeMs: Int64 = 5 * 60 * 1000

    /// Nonce cache size limit
    private let maxNonceCacheSize = 10000

    // MARK: - State

    /// Cache of used nonces to prevent replay attacks
    private var usedNonces: [String: Int64] = [:]

    // MARK: - Initialization

    init() {}

    // MARK: - Nonce Generation

    /// Generate a cryptographically secure nonce
    func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Generate a unique request ID
    func generateRequestId() -> String {
        UUID().uuidString
    }

    // MARK: - Request Signing

    /// Sign a request using HMAC-SHA256
    ///
    /// - Parameters:
    ///   - method: HTTP method
    ///   - path: Request path
    ///   - timestamp: Unix timestamp in milliseconds
    ///   - nonce: Unique nonce
    ///   - body: Request body (empty string if no body)
    ///   - secretKey: Signing key (should be derived from user credentials)
    /// - Returns: Base64-encoded signature
    func signRequest(
        method: String,
        path: String,
        timestamp: Int64,
        nonce: String,
        body: String,
        secretKey: Data
    ) -> String {
        // Create canonical request string
        let canonicalRequest = [
            method.uppercased(),
            path,
            String(timestamp),
            nonce,
            hashBody(body)
        ].joined(separator: "\n")

        // Sign with HMAC-SHA256
        let key = SymmetricKey(data: secretKey)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(canonicalRequest.utf8),
            using: key
        )

        return Data(signature).base64EncodedString()
    }

    /// Hash the request body using SHA-256
    private func hashBody(_ body: String) -> String {
        guard !body.isEmpty else { return "" }

        let hash = SHA256.hash(data: Data(body.utf8))
        return Data(hash).base64EncodedString()
    }

    // MARK: - Replay Protection

    /// Validate that a nonce hasn't been used before
    /// - Returns: true if nonce is valid (unused)
    func validateNonce(_ nonce: String) -> Bool {
        // Clean up old nonces
        cleanupOldNonces()

        // Check if nonce already exists
        if usedNonces[nonce] != nil {
            return false
        }

        // Add nonce to cache
        usedNonces[nonce] = currentTimeMillis()
        return true
    }

    /// Validate request timestamp is recent
    func validateTimestamp(_ timestamp: Int64) -> Bool {
        let now = currentTimeMillis()
        let age = now - timestamp

        // Timestamp should be recent and not in the future (with small tolerance)
        return age >= -1000 && age <= maxTimestampAgeMs
    }

    /// Clean up old nonces from cache
    private func cleanupOldNonces() {
        let cutoff = currentTimeMillis() - maxTimestampAgeMs

        // Remove old entries
        usedNonces = usedNonces.filter { $0.value >= cutoff }

        // If still too large, remove oldest entries
        if usedNonces.count > maxNonceCacheSize {
            let sorted = usedNonces.sorted { $0.value < $1.value }
            let toKeep = sorted.suffix(maxNonceCacheSize / 2)
            usedNonces = Dictionary(uniqueKeysWithValues: toKeep.map { ($0.key, $0.value) })
        }
    }

    /// Clear all cached nonces (call on logout)
    func clearNonceCache() {
        usedNonces.removeAll()
    }

    // MARK: - Helpers

    private func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - URLRequest Extension

extension URLRequest {

    /// Add security headers to the request
    /// - Parameters:
    ///   - apiSecurity: ApiSecurity instance
    ///   - signingKey: Optional signing key for request signature
    mutating func addSecurityHeaders(
        using apiSecurity: ApiSecurity,
        signingKey: Data? = nil
    ) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = await apiSecurity.generateNonce()
        let requestId = await apiSecurity.generateRequestId()

        setValue(String(timestamp), forHTTPHeaderField: ApiSecurity.timestampHeader)
        setValue(nonce, forHTTPHeaderField: ApiSecurity.nonceHeader)
        setValue(requestId, forHTTPHeaderField: ApiSecurity.requestIdHeader)

        // Add signature if signing key is available
        if let signingKey = signingKey,
           let url = self.url {
            let body = httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let signature = await apiSecurity.signRequest(
                method: httpMethod ?? "GET",
                path: url.path,
                timestamp: timestamp,
                nonce: nonce,
                body: body,
                secretKey: signingKey
            )
            setValue(signature, forHTTPHeaderField: ApiSecurity.signatureHeader)
        }
    }
}

// MARK: - Certificate Pinning Documentation

/*
 CERTIFICATE PINNING IMPLEMENTATION GUIDE

 iOS supports certificate pinning via two methods:

 1. Info.plist NSPinnedDomains (Declarative - Recommended)
    - Configure in Info.plist under NSAppTransportSecurity
    - Automatically enforced by URLSession
    - No code changes required
    - See Info.plist for configuration template

 2. URLSessionDelegate (Programmatic - For custom logic)
    - Implement urlSession(_:didReceive:completionHandler:)
    - Validate server certificate against known pins
    - More flexible but requires careful implementation

 WHEN TO ENABLE PINNING:

 Certificate pinning should ONLY be enabled when:
 1. Custom domain (api.vettid.dev) is deployed with stable ACM certificate
 2. SPKI hashes are generated and verified
 3. Backup pins from CA chain are included for rotation resilience

 DO NOT enable pinning against:
 - execute-api.us-east-1.amazonaws.com (AWS rotates certs automatically)
 - Any domain without stable, predictable certificates

 GENERATING SPKI HASHES:

 openssl s_client -connect api.vettid.dev:443 | \
     openssl x509 -pubkey -noout | \
     openssl pkey -pubin -outform der | \
     openssl dgst -sha256 -binary | base64

 PROGRAMMATIC PINNING EXAMPLE:

 class PinningDelegate: NSObject, URLSessionDelegate {
     private let pinnedHashes: Set<String> = [
         "YOUR_PRIMARY_PIN_HASH_HERE",
         "YOUR_BACKUP_PIN_HASH_HERE"
     ]

     func urlSession(
         _ session: URLSession,
         didReceive challenge: URLAuthenticationChallenge,
         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
     ) {
         guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let serverTrust = challenge.protectionSpace.serverTrust,
               let certificate = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
             completionHandler(.cancelAuthenticationChallenge, nil)
             return
         }

         // Get public key and compute SPKI hash
         guard let publicKey = SecCertificateCopyKey(certificate),
               let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
             completionHandler(.cancelAuthenticationChallenge, nil)
             return
         }

         let hash = SHA256.hash(data: publicKeyData)
         let hashString = Data(hash).base64EncodedString()

         if pinnedHashes.contains(hashString) {
             completionHandler(.useCredential, URLCredential(trust: serverTrust))
         } else {
             completionHandler(.cancelAuthenticationChallenge, nil)
         }
     }
 }
 */
