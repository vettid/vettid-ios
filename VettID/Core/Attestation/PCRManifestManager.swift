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
        /// Manifest version is older than the highest version ever seen (attestation-F4).
        case versionRollback(found: Int, expected: Int)
        /// The manifest's designated-current PCR set has already expired (attestation-F4).
        case currentSetExpired(setId: String)

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
            case .versionRollback(let found, let expected):
                return "PCR manifest version \(found) is older than the highest version seen (\(expected)); refusing to roll back"
            case .currentSetExpired(let setId):
                return "Current PCR set \(setId) has expired; refusing to adopt the manifest"
            }
        }
    }

    // MARK: - Configuration

    /// CloudFront URL for the PCR manifest
    private static let manifestURL = "https://pcr-manifest.vettid.dev/pcr-manifest.json"

    /// VettID PCR signing public key (P-256, DER-encoded, base64).
    /// Matches Android's `VETTID_SIGNING_KEY_BASE64` (PcrConfigManager.kt).
    /// Updated: 2026-05-26 after KMS rotation — the prior key
    /// (`zSr2U/RxJRP7…`) no longer verifies live manifests and was
    /// silently routing every release-build manifest fetch into the
    /// stale bundled fallback (PCR0 9b03797f…).
    private static let signingPublicKeyBase64 = """
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEW4IZe5nk/Rf7eyf9/PT2HCM5v22m2p1VURccr/D/LXUBJGRK8lliecP7F01f6ILhvrkCg3fwm2UlLls0S97Arw==
    """

    /// Cache duration for the manifest (5 minutes)
    private static let cacheDuration: TimeInterval = 300

    /// Bundled PCRs file name
    private static let bundledPCRsFileName = "expected_pcrs"

    /// UserDefaults key for the persisted monotonic manifest-version high-water mark.
    private static let maxVersionDefaultsKey = "pcr_max_manifest_version"

    // MARK: - Properties

    /// Shared instance
    static let shared = PCRManifestManager()

    /// Cached manifest
    private var cachedManifest: PCRManifest?
    private var cacheTimestamp: Date?

    /// URL session for network requests
    private let session: URLSession

    /// SPKI pinning delegate — pins pcr-manifest.vettid.dev to the Amazon CA chain.
    private let pinningDelegate: CertificatePinningDelegate

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
        self.pinningDelegate = CertificatePinningDelegate()
        self.session = URLSession(
            configuration: config,
            delegate: pinningDelegate,
            delegateQueue: nil
        )

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
    ///
    /// SECURITY (Area E #234): force-refresh the manifest and retry
    /// ONCE on a clean PCR-mismatch sweep across the cached sets.
    /// Without this, an enclave that's been redeployed past the cached
    /// manifest is unreachable until the next cacheDuration tick — a
    /// user who tries to PIN-unlock during that window gets locked out
    /// even though a fresh manifest is one network call away. Sig /
    /// nonce failures aren't retried; they wouldn't be cured by a
    /// fresh manifest. Mirrors Android AttestationRetryingVerifier
    /// (commit ea00e46).
    func verifyAttestation(
        _ attestationDocument: Data,
        nonce: Data? = nil
    ) async throws -> NitroAttestationVerifier.AttestationResult {
        do {
            return try await verifyAttestationOnce(
                attestationDocument,
                nonce: nonce,
                forceRefresh: false
            )
        } catch let error as NitroAttestationError {
            // Only retry when the failure is a PCR mismatch. Signature
            // or nonce failures aren't a manifest-staleness problem
            // and we don't want to mask them with a second round-trip.
            if case .pcrMismatch = error {
                #if DEBUG
                print("[PCRManifestManager] PCR mismatch on cached manifest; force-refreshing and retrying once")
                #endif
                return try await verifyAttestationOnce(
                    attestationDocument,
                    nonce: nonce,
                    forceRefresh: true
                )
            }
            throw error
        } catch let error as PCRManifestError {
            if case .noValidPCRSets = error {
                #if DEBUG
                print("[PCRManifestManager] No valid PCR sets matched cached manifest; force-refreshing and retrying once")
                #endif
                return try await verifyAttestationOnce(
                    attestationDocument,
                    nonce: nonce,
                    forceRefresh: true
                )
            }
            throw error
        }
    }

    /// Single attestation-verify sweep across whatever PCR sets the
    /// cached (or force-refreshed) manifest currently exposes.
    private func verifyAttestationOnce(
        _ attestationDocument: Data,
        nonce: Data?,
        forceRefresh: Bool
    ) async throws -> NitroAttestationVerifier.AttestationResult {
        let verifier = NitroAttestationVerifier()
        let validSets = try await getAllValidPCRSets(forceRefresh: forceRefresh)

        // SECURITY (Area E #53): refuse to verify against the all-
        // zeros bootstrap PCRs (the "development-placeholder" set the
        // bundled fallback exposes when no real manifest has been
        // fetched yet). Without this guard, a hostile attestation
        // doc with all-zero PCRs would silently match the placeholder
        // and bridge into the attestation path. Mirrors Android
        // 4fa73fa. Filtered here rather than in getAllValidPCRSets so
        // unrelated callers (e.g. UI badge "we have real PCRs") can
        // still see the placeholder.
        let filteredSets = validSets.filter { !Self.isAllZerosPlaceholder($0) }
        if filteredSets.isEmpty {
            #if DEBUG
            print("[PCRManifestManager] verifyAttestation called before real PCRs fetched — failing closed")
            #endif
            throw PCRManifestError.noValidPCRSets
        }

        // SPEED (#attestation-stall): parse + verify cert chain +
        // verify COSE signature ONCE and only iterate the PCR
        // comparison against each candidate set. The previous form
        // (call full `verify()` per set in a Swift loop) re-parsed
        // 6 KB of CBOR + re-validated the AWS cert chain + re-
        // verified the ES384 signature for every one of the ~205
        // sets in the manifest, blocking the actor ~40 s before the
        // user got past "Verifying enclave".
        do {
            let result = try verifier.verify(
                attestationDocument: attestationDocument,
                candidatePCRs: filteredSets.map { $0.toExpectedPCRs() },
                nonce: nonce
            )
            return result
        } catch let error as NitroAttestationError {
            // Hand back PCR-mismatch errors so `verifyAttestation`'s
            // refresh-on-mismatch retry path triggers.
            throw error
        }
    }

    /// SECURITY (Area E #53): true when the PCR set is the all-zeros
    /// bootstrap placeholder. The bundled fallback exposes one such
    /// set with id "development-placeholder"; treating it as a real
    /// verification candidate would silently pass any attestation
    /// document carrying all-zero PCRs. Defence-in-depth — the id
    /// match is the primary signal; the all-zeros byte check guards
    /// against the placeholder being renamed.
    private static func isAllZerosPlaceholder(_ set: PCRSet) -> Bool {
        if set.id == "development-placeholder" { return true }
        return Self.isAllZerosHex(set.pcr0)
            && Self.isAllZerosHex(set.pcr1)
            && Self.isAllZerosHex(set.pcr2)
    }

    private static func isAllZerosHex(_ hex: String) -> Bool {
        !hex.isEmpty && hex.allSatisfy { $0 == "0" }
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
        try enforceManifestSecurityChecks(manifest)
        return manifest
    }

    /// Persisted monotonic high-water mark of the highest manifest version
    /// ever adopted. Survives launches; resets only on app uninstall.
    private var storedMaxManifestVersion: Int {
        get { UserDefaults.standard.integer(forKey: Self.maxVersionDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.maxVersionDefaultsKey) }
    }

    /// SECURITY (attestation-F4): enforce manifest-level monotonic version +
    /// per-set `valid_until`. The signature check alone is insufficient — a
    /// previously-valid manifest stays cryptographically valid forever, so an
    /// attacker who can substitute the signed-but-stale manifest the client
    /// fetches from the CDN could otherwise roll us back to a retired PCR
    /// baseline. Not applied to the bundled-defaults fallback.
    private func enforceManifestSecurityChecks(_ manifest: PCRManifest) throws {
        let seenVersion = storedMaxManifestVersion
        if manifest.version < seenVersion {
            throw PCRManifestError.versionRollback(found: manifest.version, expected: seenVersion)
        }

        if let currentSet = manifest.pcrSets.first(where: { $0.isCurrent }),
           let until = currentSet.validUntil,
           Date() > until {
            throw PCRManifestError.currentSetExpired(setId: currentSet.id)
        }

        // Pin the new high-water mark only after the rollback check passes.
        if manifest.version > seenVersion {
            storedMaxManifestVersion = manifest.version
        }
    }

    /// Parse manifest JSON and verify signature
    private func parseAndVerifyManifest(_ data: Data) throws -> PCRManifest {
        // First parse as dictionary to extract signature separately
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signatureBase64 = json["signature"] as? String else {
            throw PCRManifestError.invalidManifest("Missing signature")
        }

        // Build the data that was signed (manifest without signature field).
        var signedData = json
        signedData.removeValue(forKey: "signature")
        signedData.removeValue(forKey: "public_key")

        let signedJSON = try Self.canonicalJSONBytes(from: signedData)

        // Verify signature
        try verifySignature(signatureBase64, for: signedJSON)

        // Now decode the full manifest
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(PCRManifest.self, from: data)
        return manifest
    }

    /// Produce canonical JSON bytes that match the form the backend
    /// signs: keys recursively sorted, no whitespace, forward slashes
    /// LEFT UNESCAPED. `JSONSerialization.data(.. .sortedKeys)` is
    /// almost right but emits `\/` inside strings (RFC 8259 lets it,
    /// but the server uses Node's `JSON.stringify`, which doesn't), so
    /// the SHA-256 over Apple's raw output never matched what KMS had
    /// signed — every release-build manifest fetch failed verification
    /// and silently fell back to the bundled stale PCRs. Mirrors
    /// Android's `canonicalizeJson` (which never escapes `/` to begin
    /// with).
    private static func canonicalJSONBytes(from object: Any) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        guard let s = String(data: raw, encoding: .utf8) else {
            throw PCRManifestError.invalidManifest("Non-UTF8 canonical JSON")
        }
        return Data(s.replacingOccurrences(of: "\\/", with: "/").utf8)
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

            // SECURITY (attestation-F4): a disk-cached manifest can be stale —
            // reject it if it's below the version high-water mark or its
            // current set has expired, rather than trusting it indefinitely.
            try enforceManifestSecurityChecks(cached.manifest)

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
