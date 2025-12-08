import Foundation
import CryptoKit

/// Manager for BIP-39 recovery phrase generation, validation, and key derivation
final class RecoveryPhraseManager {

    // MARK: - Errors

    enum RecoveryPhraseError: Error, LocalizedError {
        case invalidPhraseLength
        case invalidWord(String)
        case invalidChecksum
        case keyDerivationFailed
        case encryptionFailed
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .invalidPhraseLength:
                return "Recovery phrase must be exactly 24 words"
            case .invalidWord(let word):
                return "Invalid word: \(word)"
            case .invalidChecksum:
                return "Invalid recovery phrase checksum"
            case .keyDerivationFailed:
                return "Failed to derive key from phrase"
            case .encryptionFailed:
                return "Failed to encrypt credential backup"
            case .decryptionFailed:
                return "Failed to decrypt credential backup"
            }
        }
    }

    // MARK: - Constants

    private let phraseWordCount = 24
    private let saltPrefix = "VettID-Recovery-v1"

    // MARK: - Initialization

    init() {}

    // MARK: - Phrase Generation

    /// Generate a 24-word recovery phrase using BIP-39 standard
    func generateRecoveryPhrase() -> [String] {
        // Generate 256 bits of entropy for 24 words
        var entropy = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy)

        // Calculate checksum (SHA-256 hash, take first 8 bits for 256-bit entropy)
        let hash = SHA256.hash(data: Data(entropy))
        let hashBytes = Array(hash)
        let checksumByte = hashBytes[0]

        // Combine entropy + checksum (264 bits total = 24 words × 11 bits)
        var entropyWithChecksum = entropy
        entropyWithChecksum.append(checksumByte)

        // Convert to 24 word indices (11 bits each)
        let words = convertToWordIndices(entropyWithChecksum, wordCount: phraseWordCount)

        return words.map { BIP39WordList.words[$0] }
    }

    // MARK: - Validation

    /// Validate a recovery phrase
    func validatePhrase(_ phrase: [String]) -> Bool {
        guard phrase.count == phraseWordCount else {
            return false
        }

        // Check all words are valid BIP-39 words
        for word in phrase {
            if !BIP39WordList.isValidWord(word) {
                return false
            }
        }

        // Verify checksum
        return verifyChecksum(phrase)
    }

    /// Check if a single word is valid
    func isValidWord(_ word: String) -> Bool {
        BIP39WordList.isValidWord(word)
    }

    /// Get autocomplete suggestions for a prefix
    func getSuggestions(for prefix: String) -> [String] {
        BIP39WordList.getSuggestions(for: prefix)
    }

    // MARK: - Key Derivation

    /// Derive an encryption key from a recovery phrase using Argon2id (via PBKDF2 fallback)
    func deriveKeyFromPhrase(_ phrase: [String], salt: Data) throws -> Data {
        guard phrase.count == phraseWordCount else {
            throw RecoveryPhraseError.invalidPhraseLength
        }

        // Convert phrase to seed
        let phraseString = phrase.joined(separator: " ")
        guard let phraseData = phraseString.data(using: .utf8) else {
            throw RecoveryPhraseError.keyDerivationFailed
        }

        // Use PBKDF2 with high iteration count (CryptoKit doesn't have Argon2)
        // In production, use Argon2id via the PasswordHasher
        let derivedKey = try deriveKeyPBKDF2(
            password: phraseData,
            salt: salt,
            iterations: 600_000,
            keyLength: 32
        )

        return derivedKey
    }

    // MARK: - Encryption

    /// Encrypt credential blob for backup
    func encryptCredentialBackup(
        _ credentialBlob: Data,
        phrase: [String]
    ) throws -> EncryptedCredentialBackup {
        // Generate random salt and nonce
        var salt = [UInt8](repeating: 0, count: 32)
        var nonce = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)

        let saltData = Data(salt)
        let nonceData = Data(nonce)

        // Derive key from phrase
        let key = try deriveKeyFromPhrase(phrase, salt: saltData)

        // Encrypt with ChaCha20-Poly1305
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try ChaChaPoly.seal(
            credentialBlob,
            using: symmetricKey,
            nonce: ChaChaPoly.Nonce(data: nonceData)
        )

        return EncryptedCredentialBackup(
            ciphertext: sealedBox.ciphertext + sealedBox.tag,
            salt: saltData,
            nonce: nonceData
        )
    }

    /// Decrypt credential backup
    func decryptCredentialBackup(
        _ encryptedBackup: EncryptedCredentialBackup,
        phrase: [String]
    ) throws -> Data {
        // Derive key from phrase
        let key = try deriveKeyFromPhrase(phrase, salt: encryptedBackup.salt)

        // Split ciphertext and tag
        let ciphertext = encryptedBackup.ciphertext
        guard ciphertext.count > 16 else {
            throw RecoveryPhraseError.decryptionFailed
        }

        let actualCiphertext = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        // Decrypt with ChaCha20-Poly1305
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: encryptedBackup.nonce),
            ciphertext: actualCiphertext,
            tag: tag
        )

        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Private Helpers

    /// Convert entropy bytes to word indices (11 bits each)
    private func convertToWordIndices(_ bytes: [UInt8], wordCount: Int) -> [Int] {
        var indices: [Int] = []
        var bitBuffer: UInt32 = 0
        var bitsInBuffer = 0

        for byte in bytes {
            bitBuffer = (bitBuffer << 8) | UInt32(byte)
            bitsInBuffer += 8

            while bitsInBuffer >= 11 && indices.count < wordCount {
                bitsInBuffer -= 11
                let index = Int((bitBuffer >> bitsInBuffer) & 0x7FF)
                indices.append(index)
            }
        }

        return indices
    }

    /// Verify BIP-39 checksum
    private func verifyChecksum(_ phrase: [String]) -> Bool {
        // Convert words to indices
        var indices: [Int] = []
        for word in phrase {
            guard let index = BIP39WordList.index(of: word) else {
                return false
            }
            indices.append(index)
        }

        // Convert indices back to entropy + checksum bits
        var bits: [Bool] = []
        for index in indices {
            for i in (0..<11).reversed() {
                bits.append((index >> i) & 1 == 1)
            }
        }

        // For 24 words: 264 bits = 256 entropy + 8 checksum
        let entropyBits = 256
        let checksumBits = 8

        guard bits.count == entropyBits + checksumBits else {
            return false
        }

        // Extract entropy
        var entropy: [UInt8] = []
        for i in stride(from: 0, to: entropyBits, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 {
                if bits[i + j] {
                    byte |= 1 << (7 - j)
                }
            }
            entropy.append(byte)
        }

        // Calculate expected checksum
        let hash = SHA256.hash(data: Data(entropy))
        let hashBytes = Array(hash)
        let expectedChecksum = hashBytes[0]

        // Extract provided checksum
        var providedChecksum: UInt8 = 0
        for i in 0..<checksumBits {
            if bits[entropyBits + i] {
                providedChecksum |= 1 << (7 - i)
            }
        }

        return expectedChecksum == providedChecksum
    }

    /// PBKDF2 key derivation
    private func deriveKeyPBKDF2(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        var derivedKey = [UInt8](repeating: 0, count: keyLength)

        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    UInt32(iterations),
                    &derivedKey,
                    keyLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw RecoveryPhraseError.keyDerivationFailed
        }

        return Data(derivedKey)
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto
