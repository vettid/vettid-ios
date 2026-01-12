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
    ///
    /// SECURITY NOTE: AWS API Gateway uses AWS-managed certificates that rotate automatically.
    /// Certificate pinning is NOT recommended for API Gateway endpoints without a custom domain
    /// with stable certificates from ACM.
    ///
    /// Current configuration:
    /// - Pinning is effectively disabled (empty configuration)
    /// - HTTPS is still enforced via ATS (App Transport Security)
    /// - System CA validation is performed
    ///
    /// To enable certificate pinning:
    /// 1. Configure a custom domain (e.g., api.vettid.dev) in API Gateway with ACM certificate
    /// 2. Generate SPKI hashes using:
    ///    openssl s_client -connect api.vettid.dev:443 </dev/null 2>/dev/null | \
    ///    openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | \
    ///    openssl dgst -sha256 -binary | base64
    /// 3. Add the hash to the configuration below
    /// 4. Include backup pins from the CA chain for rotation resilience
    private static let pinnedConfigurations: [PinConfiguration] = [
        // Custom domain configuration - uncomment and configure when custom domain is deployed
        // PinConfiguration(
        //     domain: "api.vettid.dev",
        //     publicKeyHashes: [
        //         "YOUR_PRIMARY_SPKI_HASH_BASE64=",  // Primary certificate hash
        //         "YOUR_BACKUP_SPKI_HASH_BASE64="    // Backup CA hash for rotation
        //     ]
        // )
    ]

    /// Callback for pin validation failures
    var onPinValidationFailed: ((String, String) -> Void)?

    // MARK: - Initialization

    /// Certificate pinning is ALWAYS enforced regardless of build configuration.
    /// For local development with proxy tools (Charles, Proxyman):
    /// - Install the proxy CA certificate on the device/simulator
    /// - The proxy will present a valid certificate chain
    /// DO NOT add parameters to disable pinning - this is a security risk.
    override init() {
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
            // No pin configured for this host - use default handling (system CA validation)
            // Note: Default handling still validates against system trusted CAs
            #if DEBUG
            print("[CertificatePinning] No pin configured for \(host), using system CA validation")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // SECURITY: Certificate pinning is ALWAYS enforced when configured.
        // There is no bypass mechanism - this is intentional.

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
