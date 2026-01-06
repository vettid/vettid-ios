import Foundation
import CryptoKit

// MARK: - PCR Manifest Manager

/// Manages PCR values for Nitro Enclave attestation verification
///
/// This manager fetches signed PCR manifests from VettID's CDN, verifies the signature
/// using an embedded public key, and provides valid PCR sets for attestation verification.
///
/// Key security properties:
/// - The signing public key is embedded in the app (trust anchor)
/// - Manifests are signed with ECDSA P-256 (KMS)
/// - Cached manifests are re-verified on load
/// - Falls back to bundled PCRs if network unavailable
final class PCRManifestManager {

    // MARK: - Types

    /// A set of PCR values with validity period
    struct PCRSet: Codable {
        let id: String
        let pcr0: String
        let pcr1: String
        let pcr2: String
        let validFrom: Date
        let validUntil: Date?
        let isCurrent: Bool
        let description: String?

        enum CodingKeys: String, CodingKey {
            case id
            case pcr0
            case pcr1
            case pcr2
            case validFrom = "valid_from"
            case validUntil = "valid_until"
            case isCurrent = "is_current"
            case description
        }

        /// Check if this PCR set is currently valid
        var isValid: Bool {
            let now = Date()
            if now < validFrom { return false }
            if let until = validUntil, now > until { return false }
            return true
        }

        /// Convert to NitroAttestationVerifier.ExpectedPCRs
        func toExpectedPCRs() -> NitroAttestationVerifier.ExpectedPCRs {
            return NitroAttestationVerifier.ExpectedPCRs(
                pcr0: pcr0,
                pcr1: pcr1,
                pcr2: pcr2,
                validFrom: validFrom,
                validUntil: validUntil
            )
        }
    }

    /// The signed PCR manifest from the server
    struct PCRManifest: Codable {
        let version: Int
        let timestamp: Date
        let pcrSets: [PCRSet]
        let signature: String
        let publicKey: String?

        enum CodingKeys: String, CodingKey {
            case version
            case timestamp
            case pcrSets = "pcr_sets"
            case signature
            case publicKey = "public_key"
        }
    }

    enum PCRManifestError: Error, LocalizedError {
        case networkError(Error)
        case invalidManifest(String)
        case signatureVerificationFailed
        case noValidPCRSets
        case cacheCorrupted

        var errorDescription: String? {
            switch self {
            case .networkError(let error):
                return "Failed to fetch PCR manifest: \(error.localizedDescription)"
            case .invalidManifest(let detail):
                return "Invalid PCR manifest: \(detail)"
            case .signatureVerificationFailed:
                return "PCR manifest signature verification failed"
            case .noValidPCRSets:
                return "No valid PCR sets available"
            case .cacheCorrupted:
                return "Cached PCR manifest is corrupted"
            }
        }
    }

    // MARK: - Configuration

    /// CloudFront URL for the PCR manifest
    private static let manifestURL = "https://pcr-manifest.vettid.dev/pcr-manifest.json"

    /// VettID PCR signing public key (P-256, DER-encoded, base64)
    /// Key ID: a5e30b97-89da-41e9-b447-c759a9f9c801 (alias/vettid-pcr-signing)
    /// Updated: 2026-01-06
    private static let signingPublicKeyBase64 = """
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzSr2U/RxJRP7dWKMASJSs6fURsEzdn59XSvp3TitMaw3bMBIj8slPXJhJF7d2/DS4UnzMhxEdQHLq2NdoKaVUw==
    """

    /// Cache duration for the manifest (5 minutes)
    private static let cacheDuration: TimeInterval = 300

    /// Bundled PCRs file name
    private static let bundledPCRsFileName = "expected_pcrs"

    // MARK: - Properties

    /// Shared instance
    static let shared = PCRManifestManager()

    /// Cached manifest
    private var cachedManifest: PCRManifest?
    private var cacheTimestamp: Date?

    /// URL session for network requests
    private let session: URLSession

    /// File manager for cache persistence
    private let fileManager = FileManager.default

    /// Cache file URL
    private var cacheFileURL: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("pcr-manifest-cache.json")
    }

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)

        // Load cached manifest on init
        loadCachedManifest()
    }

    // MARK: - Public API

    /// Get the current valid PCR set for attestation verification
    /// - Parameter forceRefresh: If true, fetch fresh manifest from server
    /// - Returns: The current valid PCR set
    func getCurrentPCRSet(forceRefresh: Bool = false) async throws -> PCRSet {
        // Try to get manifest (from cache or network)
        let manifest = try await getManifest(forceRefresh: forceRefresh)

        // Find the current PCR set
        if let currentSet = manifest.pcrSets.first(where: { $0.isCurrent && $0.isValid }) {
            return currentSet
        }

        // Fall back to any valid PCR set
        if let validSet = manifest.pcrSets.first(where: { $0.isValid }) {
            return validSet
        }

        throw PCRManifestError.noValidPCRSets
    }

    /// Get all valid PCR sets (for verifying against any valid enclave version)
    /// - Parameter forceRefresh: If true, fetch fresh manifest from server
    /// - Returns: Array of valid PCR sets
    func getAllValidPCRSets(forceRefresh: Bool = false) async throws -> [PCRSet] {
        let manifest = try await getManifest(forceRefresh: forceRefresh)
        let validSets = manifest.pcrSets.filter { $0.isValid }

        if validSets.isEmpty {
            throw PCRManifestError.noValidPCRSets
        }

        return validSets
    }

    /// Verify attestation against any valid PCR set
    /// - Parameters:
    ///   - attestationDocument: The attestation document to verify
    ///   - nonce: Optional nonce for freshness
    /// - Returns: Verification result if any PCR set matches
    func verifyAttestation(
        _ attestationDocument: Data,
        nonce: Data? = nil
    ) async throws -> NitroAttestationVerifier.AttestationResult {
        let verifier = NitroAttestationVerifier()
        let validSets = try await getAllValidPCRSets()

        var lastError: Error?

        // Try each valid PCR set
        for pcrSet in validSets {
            do {
                let result = try verifier.verify(
                    attestationDocument: attestationDocument,
                    expectedPCRs: pcrSet.toExpectedPCRs(),
                    nonce: nonce
                )
                return result
            } catch let error as NitroAttestationError {
                // PCR mismatch - try next set
                if case .pcrMismatch = error {
                    lastError = error
                    continue
                }
                // Other errors are fatal
                throw error
            }
        }

        // No PCR set matched
        throw lastError ?? PCRManifestError.noValidPCRSets
    }

    // MARK: - Manifest Fetching

    /// Get the manifest, using cache if valid
    private func getManifest(forceRefresh: Bool) async throws -> PCRManifest {
        // Check cache first (unless force refresh)
        if !forceRefresh,
           let cached = cachedManifest,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < Self.cacheDuration {
            return cached
        }

        // Try to fetch from network
        do {
            let manifest = try await fetchManifest()
            cachedManifest = manifest
            cacheTimestamp = Date()
            persistCache(manifest)
            return manifest
        } catch {
            // If network fails, try cached manifest (even if expired)
            if let cached = cachedManifest {
                print("PCRManifestManager: Network failed, using cached manifest")
                return cached
            }

            // Fall back to bundled PCRs
            return try loadBundledPCRs()
        }
    }

    /// Fetch manifest from server and verify signature
    private func fetchManifest() async throws -> PCRManifest {
        guard let url = URL(string: Self.manifestURL) else {
            throw PCRManifestError.invalidManifest("Invalid manifest URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PCRManifestError.networkError(
                NSError(domain: "PCRManifest", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "Server returned error"])
            )
        }

        // Parse manifest
        let manifest = try parseAndVerifyManifest(data)
        return manifest
    }

    /// Parse manifest JSON and verify signature
    private func parseAndVerifyManifest(_ data: Data) throws -> PCRManifest {
        // First parse as dictionary to extract signature separately
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signatureBase64 = json["signature"] as? String else {
            throw PCRManifestError.invalidManifest("Missing signature")
        }

        // Build the data that was signed (manifest without signature field)
        var signedData = json
        signedData.removeValue(forKey: "signature")
        signedData.removeValue(forKey: "public_key")

        let signedJSON = try JSONSerialization.data(withJSONObject: signedData, options: .sortedKeys)

        // Verify signature
        try verifySignature(signatureBase64, for: signedJSON)

        // Now decode the full manifest
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(PCRManifest.self, from: data)
        return manifest
    }

    /// Verify ECDSA-P256 signature using embedded public key
    private func verifySignature(_ signatureBase64: String, for data: Data) throws {
        // Decode signature
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            throw PCRManifestError.signatureVerificationFailed
        }

        // Get the signing public key
        guard let publicKeyData = Data(base64Encoded: Self.signingPublicKeyBase64),
              !Self.signingPublicKeyBase64.contains("PLACEHOLDER") else {
            // Public key not yet configured - skip verification in development
            print("PCRManifestManager: WARNING - Signing public key not configured, skipping verification")
            return
        }

        // Parse the DER-encoded public key
        // KMS returns SubjectPublicKeyInfo format, we need to extract the raw key
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyData) else {
            throw PCRManifestError.invalidManifest("Invalid signing public key")
        }

        // Hash the data (signature was created with SHA-256)
        let hash = SHA256.hash(data: data)

        // Parse ECDSA signature (DER format from KMS)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            throw PCRManifestError.signatureVerificationFailed
        }

        // Verify
        guard publicKey.isValidSignature(signature, for: hash) else {
            throw PCRManifestError.signatureVerificationFailed
        }
    }

    // MARK: - Caching

    /// Load cached manifest from disk
    private func loadCachedManifest() {
        guard let cacheURL = cacheFileURL,
              let data = try? Data(contentsOf: cacheURL) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let cached = try decoder.decode(CachedManifest.self, from: data)

            // Verify signature before using
            let manifestData = try JSONEncoder().encode(cached.manifest)
            try verifySignature(cached.manifest.signature, for: manifestData)

            cachedManifest = cached.manifest
            cacheTimestamp = cached.timestamp
        } catch {
            // Cache corrupted, delete it
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    /// Persist manifest to disk cache
    private func persistCache(_ manifest: PCRManifest) {
        guard let cacheURL = cacheFileURL else { return }

        let cached = CachedManifest(manifest: manifest, timestamp: Date())

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cached)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            print("PCRManifestManager: Failed to persist cache: \(error)")
        }
    }

    /// Wrapper for cached manifest with timestamp
    private struct CachedManifest: Codable {
        let manifest: PCRManifest
        let timestamp: Date
    }

    // MARK: - Bundled Fallback

    /// Load PCRs from bundled JSON file (fallback when network unavailable)
    private func loadBundledPCRs() throws -> PCRManifest {
        guard let url = Bundle.main.url(forResource: Self.bundledPCRsFileName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw PCRManifestError.invalidManifest("Bundled PCRs file not found")
        }

        // Parse the bundled format
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct BundledPCRs: Codable {
            let pcrSets: [PCRSet]

            enum CodingKeys: String, CodingKey {
                case pcrSets = "pcr_sets"
            }
        }

        let bundled = try decoder.decode(BundledPCRs.self, from: data)

        // Create a pseudo-manifest from bundled PCRs
        return PCRManifest(
            version: 0,
            timestamp: Date(),
            pcrSets: bundled.pcrSets,
            signature: "",
            publicKey: nil
        )
    }
}
