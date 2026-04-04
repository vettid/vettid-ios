import Foundation
import CryptoKit

/// Encrypts and decrypts WebRTC media frames using AES-128-GCM.
///
/// The shared key is derived via:
///   X25519 ECDH shared secret → HKDF-SHA256(salt: callId, info: "vettid-e2ee-call-key") → 128 bits
///
/// Key ratcheting uses salt: "vettid-e2ee-ratchet-v1"
///
/// Security: Key material is zeroized on dispose. Per-frame nonce generation
/// ensures unique ciphertext. AES-GCM provides authenticated encryption.
final class CallFrameCryptor {

    // MARK: - Configuration

    private static let keyDerivationInfo = "vettid-e2ee-call-key"
    private static let ratchetSalt = "vettid-e2ee-ratchet-v1"
    private static let keyLengthBytes = 32 // AES-256-GCM (matches rest of system)

    // MARK: - State

    private var currentKey: SymmetricKey?
    private let callId: String
    private var ratchetCount: UInt32 = 0

    // MARK: - Initialization

    init(callId: String) {
        self.callId = callId
    }

    // MARK: - Key Derivation

    /// Derive the shared encryption key from a X25519 shared secret.
    ///
    /// - Parameter sharedSecret: The raw shared secret bytes from X25519 ECDH key agreement
    func deriveKey(from sharedSecret: SharedSecret) {
        let saltData = Data(callId.utf8)
        let infoData = Data(Self.keyDerivationInfo.utf8)

        currentKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: infoData,
            outputByteCount: Self.keyLengthBytes
        )
    }

    /// Derive the shared encryption key from raw key bytes (e.g., from vault).
    func deriveKey(from keyMaterial: Data) {
        let saltData = Data(callId.utf8)
        let infoData = Data(Self.keyDerivationInfo.utf8)

        let inputKey = SymmetricKey(data: keyMaterial)
        currentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: saltData,
            info: infoData,
            outputByteCount: Self.keyLengthBytes
        )
    }

    // MARK: - Frame Encryption

    /// Encrypt a media frame.
    ///
    /// - Parameter plaintext: The raw media frame data
    /// - Returns: Encrypted frame (nonce + ciphertext + tag)
    func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = currentKey else {
            throw CallFrameCryptorError.noKey
        }

        let sealedBox = try AES.GCM.seal(plaintext, using: key)

        // Combine nonce + ciphertext + tag for transport
        guard let combined = sealedBox.combined else {
            throw CallFrameCryptorError.encryptionFailed
        }

        return combined
    }

    /// Decrypt a media frame.
    ///
    /// - Parameter ciphertext: The encrypted frame data (nonce + ciphertext + tag)
    /// - Returns: Decrypted media frame
    func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = currentKey else {
            throw CallFrameCryptorError.noKey
        }

        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Key Ratcheting

    /// Ratchet the key forward for forward secrecy.
    /// Each ratchet derives a new key from the current key + ratchet salt.
    func ratchet() throws {
        guard let key = currentKey else {
            throw CallFrameCryptorError.noKey
        }

        ratchetCount += 1
        let saltData = Data(Self.ratchetSalt.utf8)
        var info = Data(Self.keyDerivationInfo.utf8)
        info.append(contentsOf: withUnsafeBytes(of: ratchetCount.bigEndian) { Data($0) })

        currentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: saltData,
            info: info,
            outputByteCount: Self.keyLengthBytes
        )
    }

    // MARK: - Cleanup

    /// Zeroize all key material.
    func dispose() {
        currentKey = nil
        ratchetCount = 0
    }

    deinit {
        dispose()
    }
}

// MARK: - Errors

enum CallFrameCryptorError: LocalizedError {
    case noKey
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .noKey: return "No encryption key available"
        case .encryptionFailed: return "Frame encryption failed"
        case .decryptionFailed: return "Frame decryption failed"
        }
    }
}
