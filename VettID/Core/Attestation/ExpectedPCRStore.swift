import Foundation
import CryptoKit

// MARK: - Expected PCR Store

/// Manages expected PCR values for Nitro Enclave attestation verification
///
/// PCR values are cryptographic hashes that identify the code running in an enclave:
/// - PCR0: Hash of the enclave image
/// - PCR1: Hash of the Linux kernel and bootstrap
/// - PCR2: Hash of the application
///
/// When VettID updates enclave software, new PCR values are published.
/// This store handles bundled PCRs and fetched updates.
final class ExpectedPCRStore {

    // MARK: - Types

    /// A set of expected PCR values with validity period
    struct PCRSet: Codable, Equatable {
        let id: String
        let pcr0: String
        let pcr1: String
        let pcr2: String
        let validFrom: Date
        let validUntil: Date?
        let isCurrent: Bool

        enum CodingKeys: String, CodingKey {
            case id, pcr0, pcr1, pcr2
            case validFrom = "valid_from"
            case validUntil = "valid_until"
            case isCurrent = "is_current"
        }

        /// Convert to ExpectedPCRs for verification
        func toExpectedPCRs() -> NitroAttestationVerifier.ExpectedPCRs {
            NitroAttestationVerifier.ExpectedPCRs(
                pcr0: pcr0,
                pcr1: pcr1,
                pcr2: pcr2,
                validFrom: validFrom,
                validUntil: validUntil
            )
        }

        /// Check if this PCR set is currently valid
        var isValid: Bool {
            let now = Date()
            if now < validFrom { return false }
            if let until = validUntil, now > until { return false }
            return true
        }
    }

    /// Response from PCR update endpoint (converted from API format)
    struct PCRUpdateResponse: Codable {
        let pcrSets: [PCRSet]
        let signature: String
        let signedAt: Date
        let signedPayload: Data?  // The exact bytes that were signed (for verification)

        enum CodingKeys: String, CodingKey {
            case pcrSets = "pcr_sets"
            case signature
            case signedAt = "signed_at"
            case signedPayload = "signed_payload"
        }
    }

    // MARK: - Properties

    /// Keychain key for stored PCR sets
    private let keychainKey = "com.vettid.pcr.sets"

    /// Keychain key for last update timestamp
    private let lastUpdateKey = "com.vettid.pcr.lastUpdate"

    /// Public key for verifying PCR update signatures (Ed25519)
    /// This is bundled with the app and cannot be updated remotely
    private let signingPublicKey: Data?

    /// Bundled PCR sets (fallback if no updates available)
    private let bundledPCRSets: [PCRSet]

    /// Cached PCR sets from storage
    private var cachedPCRSets: [PCRSet]?

    // MARK: - Initialization

    init() {
        self.signingPublicKey = Self.loadSigningPublicKey()
        self.bundledPCRSets = Self.loadBundledPCRSets()
    }

    // MARK: - Public API

    /// Get all currently valid PCR sets
    /// Returns stored sets if available, otherwise bundled sets
    func getValidPCRSets() -> [PCRSet] {
        let sets = cachedPCRSets ?? loadStoredPCRSets() ?? bundledPCRSets
        return sets.filter { $0.isValid }
    }

    /// Get the current (primary) PCR set
    func getCurrentPCRSet() -> PCRSet? {
        return getValidPCRSets().first { $0.isCurrent } ?? getValidPCRSets().first
    }

    /// Check if any valid PCR set matches the given PCR values
    func hasMatchingPCRSet(pcr0: String, pcr1: String, pcr2: String) -> Bool {
        return getValidPCRSets().contains { set in
            set.pcr0.lowercased() == pcr0.lowercased() &&
            set.pcr1.lowercased() == pcr1.lowercased() &&
            set.pcr2.lowercased() == pcr2.lowercased()
        }
    }

    /// Find a matching PCR set for the given values
    func findMatchingPCRSet(pcr0: String, pcr1: String, pcr2: String) -> PCRSet? {
        return getValidPCRSets().first { set in
            set.pcr0.lowercased() == pcr0.lowercased() &&
            set.pcr1.lowercased() == pcr1.lowercased() &&
            set.pcr2.lowercased() == pcr2.lowercased()
        }
    }

    /// Store updated PCR sets after verifying signature
    func storeUpdatedPCRSets(_ response: PCRUpdateResponse) throws {
        // Verify signature
        try verifyUpdateSignature(response)

        // Check for downgrade attack (new update must be newer than stored)
        if let lastUpdate = getLastUpdateTimestamp(), response.signedAt <= lastUpdate {
            throw PCRStoreError.downgradeAttempt
        }

        // Store the new PCR sets
        try storePCRSets(response.pcrSets)
        try storeLastUpdateTimestamp(response.signedAt)

        // Update cache
        cachedPCRSets = response.pcrSets

        #if DEBUG
        print("[PCRStore] Updated with \(response.pcrSets.count) PCR sets")
        #endif
    }

    /// Clear stored PCR sets (revert to bundled)
    func clearStoredPCRSets() {
        deleteFromKeychain(key: keychainKey)
        deleteFromKeychain(key: lastUpdateKey)
        cachedPCRSets = nil
    }

    /// Get the timestamp of the last PCR update
    func getLastUpdateTimestamp() -> Date? {
        guard let data = loadFromKeychain(key: lastUpdateKey),
              let timestamp = try? JSONDecoder().decode(Date.self, from: data) else {
            return nil
        }
        return timestamp
    }

    // MARK: - Signature Verification

    /// Verify Ed25519 signature on PCR update
    private func verifyUpdateSignature(_ response: PCRUpdateResponse) throws {
        guard let publicKey = signingPublicKey else {
            throw PCRStoreError.signingKeyNotAvailable
        }

        guard let signatureData = Data(base64Encoded: response.signature) else {
            throw PCRStoreError.invalidSignature
        }

        // Use the pre-computed signed payload if available, otherwise reconstruct
        let messageData: Data
        if let payload = response.signedPayload {
            messageData = payload
        } else {
            // Fallback: reconstruct the signed message from PCR sets
            messageData = try createSignatureMessage(pcrSets: response.pcrSets)
        }

        // Verify using CryptoKit Ed25519
        do {
            let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            guard verifyingKey.isValidSignature(signatureData, for: messageData) else {
                throw PCRStoreError.signatureVerificationFailed
            }
        } catch let error as PCRStoreError {
            throw error
        } catch {
            throw PCRStoreError.signatureVerificationFailed
        }
    }

    /// Create the message bytes that should be signed
    /// Backend signs: JSON.stringify({ PCR0, PCR1, PCR2, [PCR3 if present] })
    private func createSignatureMessage(pcrSets: [PCRSet]) throws -> Data {
        guard let pcrSet = pcrSets.first else {
            throw PCRStoreError.noPCRSetsAvailable
        }

        // Backend signs the pcrs object with uppercase keys, sorted
        // The format is: {"PCR0":"...","PCR1":"...","PCR2":"..."}
        var dict: [String: String] = [
            "PCR0": pcrSet.pcr0,
            "PCR1": pcrSet.pcr1,
            "PCR2": pcrSet.pcr2
        ]

        // PCR3 is optional - only include if non-empty
        // (Backend doesn't include null values)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        return try encoder.encode(dict)
    }

    // MARK: - Storage

    private func loadStoredPCRSets() -> [PCRSet]? {
        guard let data = loadFromKeychain(key: keychainKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([PCRSet].self, from: data)
    }

    private func storePCRSets(_ sets: [PCRSet]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sets)
        try storeInKeychain(data: data, key: keychainKey)
    }

    private func storeLastUpdateTimestamp(_ date: Date) throws {
        let data = try JSONEncoder().encode(date)
        try storeInKeychain(data: data, key: lastUpdateKey)
    }

    // MARK: - Keychain Helpers

    private func storeInKeychain(data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PCRStoreError.storageFailed(status)
        }
    }

    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Bundled Resources

    /// VettID's Ed25519 public key for verifying PCR signatures (X.509 SubjectPublicKeyInfo DER, Base64)
    /// Generated: 2026-01-03, Key ID: vettid-pcr-signing-key-v1
    private static let signingPublicKeyBase64 = "MCowBQYDK2VwAyEA+1FRzTi+cZ1BIuBzNjnarDkN4T+gxNnDi4BCS7tbwX0="

    /// Load the Ed25519 public key for verifying PCR updates
    private static func loadSigningPublicKey() -> Data? {
        // First try embedded key (preferred)
        if let keyData = Data(base64Encoded: signingPublicKeyBase64) {
            // Extract raw 32-byte public key from X.509 SubjectPublicKeyInfo DER format
            // Format: 30 2a (SEQUENCE) 30 05 (SEQUENCE) 06 03 2b6570 (OID for Ed25519) 03 21 00 <32 bytes>
            // The raw key starts at offset 12
            if keyData.count == 44 {
                return keyData.suffix(32)
            }
            return keyData
        }

        // Fallback: look for the signing key in the app bundle
        guard let keyURL = Bundle.main.url(forResource: "pcr_signing_key", withExtension: "pub"),
              let keyBase64 = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let keyData = Data(base64Encoded: keyBase64) else {
            #if DEBUG
            print("[PCRStore] PCR signing public key not found in bundle")
            #endif
            return nil
        }
        return keyData
    }

    /// Load bundled PCR sets from app bundle
    private static func loadBundledPCRSets() -> [PCRSet] {
        guard let url = Bundle.main.url(forResource: "expected_pcrs", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            #if DEBUG
            print("[PCRStore] Bundled PCR sets not found, using placeholder")
            #endif
            // Return placeholder PCR set for development
            return [
                PCRSet(
                    id: "development-placeholder",
                    pcr0: String(repeating: "0", count: 96),
                    pcr1: String(repeating: "0", count: 96),
                    pcr2: String(repeating: "0", count: 96),
                    validFrom: Date.distantPast,
                    validUntil: nil,
                    isCurrent: true
                )
            ]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let response = try decoder.decode(BundledPCRResponse.self, from: data)
            return response.pcrSets
        } catch {
            #if DEBUG
            print("[PCRStore] Failed to decode bundled PCR sets: \(error)")
            #endif
            return []
        }
    }
}

// MARK: - Supporting Types

private struct BundledPCRResponse: Codable {
    let pcrSets: [ExpectedPCRStore.PCRSet]

    enum CodingKeys: String, CodingKey {
        case pcrSets = "pcr_sets"
    }
}

// MARK: - Errors

enum PCRStoreError: Error, LocalizedError {
    case signingKeyNotAvailable
    case invalidSignature
    case signatureVerificationFailed
    case downgradeAttempt
    case storageFailed(OSStatus)
    case noPCRSetsAvailable

    var errorDescription: String? {
        switch self {
        case .signingKeyNotAvailable:
            return "PCR signing public key not available"
        case .invalidSignature:
            return "Invalid PCR update signature format"
        case .signatureVerificationFailed:
            return "PCR update signature verification failed"
        case .downgradeAttempt:
            return "PCR update is older than current version (potential downgrade attack)"
        case .storageFailed(let status):
            return "Failed to store PCR sets: \(status)"
        case .noPCRSetsAvailable:
            return "No valid PCR sets available"
        }
    }
}
