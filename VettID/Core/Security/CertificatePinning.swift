import Foundation
import CryptoKit
import Security

/// Certificate pinning delegate for URLSession
/// Implements SSL pinning to prevent MITM attacks
final class CertificatePinningDelegate: NSObject, URLSessionDelegate {

    // MARK: - Configuration

    /// Pin configuration for a domain
    struct PinConfiguration {
        let domain: String
        let publicKeyHashes: [String]  // Base64 encoded SHA-256 hashes of SPKI
        let includeSubdomains: Bool

        init(domain: String, publicKeyHashes: [String], includeSubdomains: Bool = true) {
            self.domain = domain
            self.publicKeyHashes = publicKeyHashes
            self.includeSubdomains = includeSubdomains
        }
    }

    /// Pinned certificates for VettID API domains
    /// These are SHA-256 hashes of the Subject Public Key Info (SPKI)
    /// NOTE: AWS API Gateway uses AWS-managed certificates that rotate automatically.
    /// Certificate pinning is disabled for API Gateway endpoints by default.
    private static let pinnedConfigurations: [PinConfiguration] = [
        // Production API (AWS API Gateway)
        PinConfiguration(
            domain: "tiqpij5mue.execute-api.us-east-1.amazonaws.com",
            publicKeyHashes: [
                // AWS API Gateway certificates rotate - pinning not recommended
                // These are placeholders if custom domain with stable cert is used
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",  // TODO: Replace with actual hash
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="   // TODO: Replace with actual hash
            ]
        )
    ]

    /// Whether to enforce pinning (can be disabled for testing)
    private let enforcePinning: Bool

    /// Callback for pin validation failures
    var onPinValidationFailed: ((String, String) -> Void)?

    // MARK: - Initialization

    init(enforcePinning: Bool = true) {
        #if DEBUG
        // Allow disabling pinning in debug builds for testing
        self.enforcePinning = enforcePinning
        #else
        // Always enforce in release builds
        self.enforcePinning = true
        #endif
        super.init()
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle server trust challenges
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Find pin configuration for this host
        guard let pinConfig = findPinConfiguration(for: host) else {
            // No pin configured for this host - use default handling
            #if DEBUG
            print("CertificatePinning: No pin configured for \(host), using default handling")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Skip pinning if disabled (debug only)
        guard enforcePinning else {
            #if DEBUG
            print("CertificatePinning: Pinning disabled for debugging")
            #endif
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // Validate the certificate chain
        if validateCertificateChain(serverTrust: serverTrust, against: pinConfig) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            onPinValidationFailed?(host, "Certificate pin validation failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Certificate Validation

    /// Find pin configuration for a host
    private func findPinConfiguration(for host: String) -> PinConfiguration? {
        for config in Self.pinnedConfigurations {
            if host == config.domain {
                return config
            }
            if config.includeSubdomains && host.hasSuffix("." + config.domain) {
                return config
            }
        }
        return nil
    }

    /// Validate certificate chain against pinned public keys
    private func validateCertificateChain(serverTrust: SecTrust, against config: PinConfiguration) -> Bool {
        // Evaluate the trust first
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        guard isValid else {
            #if DEBUG
            print("CertificatePinning: Trust evaluation failed: \(error?.localizedDescription ?? "unknown error")")
            #endif
            return false
        }

        // Get certificate chain (iOS 15+ API)
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificateChain.isEmpty else {
            return false
        }

        // Check each certificate in the chain against our pins
        for certificate in certificateChain {
            if let publicKeyHash = extractPublicKeyHash(from: certificate) {
                if config.publicKeyHashes.contains(publicKeyHash) {
                    return true
                }
            }
        }

        #if DEBUG
        print("CertificatePinning: No matching pin found for \(config.domain)")
        // Log the actual hashes for debugging (only in debug builds)
        for (index, cert) in certificateChain.enumerated() {
            if let hash = extractPublicKeyHash(from: cert) {
                print("  Certificate \(index) hash: \(hash)")
            }
        }
        #endif

        return false
    }

    /// Extract SHA-256 hash of the Subject Public Key Info (SPKI)
    private func extractPublicKeyHash(from certificate: SecCertificate) -> String? {
        // Get the public key from the certificate
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }

        // Get the external representation (SPKI)
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        // Hash the public key data with SHA-256
        let hash = SHA256.hash(data: publicKeyData)
        return Data(hash).base64EncodedString()
    }

    // MARK: - Utility

    /// Generate SPKI hash for a certificate file (for initial setup)
    /// This is a utility method to help generate the pin hashes
    static func generateSPKIHash(fromDERFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            return nil
        }

        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        let hash = SHA256.hash(data: publicKeyData)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - URLSessionTaskDelegate

extension CertificatePinningDelegate: URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Delegate to session-level handler
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}
