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

    /// Pinned certificates for VettID API domains.
    /// Values are base64-encoded SHA-256 hashes of the DER-encoded Subject
    /// Public Key Info (SPKI) — the same pin set okhttp's `CertificatePinner`
    /// uses on Android (`sha256/...`), so the two platforms stay in lockstep.
    ///
    /// SECURITY (manifest-F6): pinned to the Amazon RSA 2048 M04 intermediate
    /// (the current api.vettid.dev issuer) plus Amazon Root CA 1 as backup.
    /// We pin CA certs in the chain rather than the leaf because AWS-managed
    /// leaf certificates rotate automatically; the chain check in
    /// `validateCertificateChain` matches a pin against ANY cert in the chain.
    ///
    /// Refresh procedure if Amazon publishes a new intermediate:
    ///   echo | openssl s_client -servername api.vettid.dev \
    ///       -showcerts -connect api.vettid.dev:443 2>/dev/null \
    ///     | openssl x509 -pubkey -noout \
    ///     | openssl pkey -pubin -outform der \
    ///     | openssl dgst -sha256 -binary | base64
    ///
    /// Amazon RSA 2048 M04 — intermediate that signs api.vettid.dev today.
    private static let amazonRSAM04Pin = "G9LNNAql897egYsabashkzUCTEJkWBzgoEtk8X/678c="
    /// Amazon Root CA 1 — backup; would have to replace M04 entirely if M04 is retired.
    private static let amazonRootCA1Pin = "++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI="

    private static let pinnedConfigurations: [PinConfiguration] = [
        PinConfiguration(
            domain: "api.vettid.dev",
            publicKeyHashes: [amazonRSAM04Pin, amazonRootCA1Pin]
        ),
        PinConfiguration(
            domain: "vettid.dev",
            publicKeyHashes: [amazonRSAM04Pin, amazonRootCA1Pin]
        ),
        PinConfiguration(
            domain: "pcr-manifest.vettid.dev",
            publicKeyHashes: [amazonRSAM04Pin, amazonRootCA1Pin]
        )
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

    /// Extract base64(SHA-256(DER-encoded SPKI)) for a certificate.
    private func extractPublicKeyHash(from certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }
        return Self.spkiSHA256Base64(for: publicKey)
    }

    /// Compute base64(SHA-256(SubjectPublicKeyInfo)) for a public key.
    ///
    /// `SecKeyCopyExternalRepresentation` returns the *raw* key (PKCS#1
    /// `RSAPublicKey` for RSA, ANSI X9.63 for EC) — NOT the DER-encoded
    /// SubjectPublicKeyInfo that okhttp / OpenSSL hash. To produce a pin that
    /// matches the Android pin set we must prepend the fixed ASN.1 SPKI
    /// header for the key's type and size before hashing.
    ///
    /// Exposed as `internal static` so `AppleNatsClient`'s TLS verify block
    /// can reuse the same SPKI-pin computation as the HTTPS surface.
    static func spkiSHA256Base64(for publicKey: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let rawKey = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String,
              let keySize = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue,
              let header = asn1SPKIHeader(keyType: keyType, keySizeInBits: keySize) else {
            return nil
        }

        var spki = Data(header)
        spki.append(rawKey)
        let hash = SHA256.hash(data: spki)
        return Data(hash).base64EncodedString()
    }

    /// Fixed ASN.1 SubjectPublicKeyInfo headers, keyed by algorithm + key size.
    /// These prefix the raw key bytes to reconstruct the full DER SPKI.
    /// Internal so `AppleNatsClient` can share the table.
    static func asn1SPKIHeader(keyType: String, keySizeInBits: Int) -> [UInt8]? {
        switch (keyType, keySizeInBits) {
        case (String(kSecAttrKeyTypeRSA), 2048):
            return [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
            ]
        case (String(kSecAttrKeyTypeRSA), 3072):
            return [
                0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x8f, 0x00
            ]
        case (String(kSecAttrKeyTypeRSA), 4096):
            return [
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
            ]
        case (String(kSecAttrKeyTypeECSECPrimeRandom), 256):
            return [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00
            ]
        case (String(kSecAttrKeyTypeECSECPrimeRandom), 384):
            return [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
            ]
        default:
            #if DEBUG
            print("[CertificatePinning] No ASN.1 SPKI header for keyType=\(keyType) size=\(keySizeInBits)")
            #endif
            return nil
        }
    }

    // MARK: - Utility

    /// Generate the SPKI pin for a certificate file (for initial setup / pin refresh).
    static func generateSPKIHash(fromDERFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }
        return spkiSHA256Base64(for: publicKey)
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
