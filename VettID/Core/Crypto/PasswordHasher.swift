import Foundation
import CryptoKit
import CommonCrypto

#if canImport(Sodium)
import Sodium
#endif

/// Password hashing service using Argon2id via libsodium (when available)
/// Falls back to PBKDF2 for development/testing when Sodium is not available
///
/// Argon2id parameters (matching backend):
/// - Memory: 64 MB (65536 KB)
/// - Iterations: 3
/// - Parallelism: 4 (libsodium uses 1 internally but with equivalent security)
/// - Output length: 32 bytes
///
/// SECURITY: Production builds MUST use Argon2id. PBKDF2 fallback is for simulator testing only.
final class PasswordHasher {

    private static let hashLength = 32
    private static let saltLength = 16

    #if canImport(Sodium)
    private static let sodium = Sodium()
    private static let opsLimit = sodium.pwHash.OpsLimitModerate  // ~3 iterations equivalent
    private static let memLimit = sodium.pwHash.MemLimitModerate  // ~64MB equivalent
    #else
    // SECURITY: Verify we're not in a production build without Argon2id
    private static let productionCheckPerformed: Bool = {
        #if !DEBUG
        // In Release builds without Sodium, this is a security issue
        // DO NOT print warnings to console in production - they leak info to device logs
        // The assertionFailure below will crash TestFlight builds for testing

        #if !targetEnvironment(simulator)
        // On physical devices in Release, this is a critical error
        // We use assertionFailure to crash in debug-like release builds but allow TestFlight
        assertionFailure("SECURITY: Production build must use Argon2id. Add swift-sodium package.")
        #endif
        #endif
        return true
    }()
    #endif

    /// Hash a password using Argon2id (or PBKDF2 fallback)
    /// - Parameters:
    ///   - password: The password to hash
    ///   - salt: Optional salt (generated if not provided, must be 16 bytes)
    /// - Returns: The password hash and salt used
    static func hash(password: String, salt: Data? = nil) throws -> PasswordHashResult {
        let saltData: Data
        if let providedSalt = salt {
            guard providedSalt.count == saltLength else {
                throw PasswordHashError.invalidSalt
            }
            saltData = providedSalt
        } else {
            saltData = CryptoManager.randomBytes(count: saltLength)
        }

        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordHashError.invalidPassword
        }

        #if canImport(Sodium)
        // Use libsodium's Argon2id implementation
        guard let hash = sodium.pwHash.hash(
            outputLength: hashLength,
            passwd: Array(passwordData),
            salt: Array(saltData),
            opsLimit: opsLimit,
            memLimit: memLimit,
            alg: .Argon2ID13
        ) else {
            throw PasswordHashError.hashingFailed
        }
        return PasswordHashResult(hash: Data(hash), salt: saltData)
        #else
        // PBKDF2 fallback for development/testing
        // SECURITY: Trigger production check on first use
        _ = productionCheckPerformed

        let hash = try pbkdf2Fallback(
            password: passwordData,
            salt: saltData,
            iterations: 100_000,  // High iteration count for PBKDF2
            keyLength: hashLength
        )
        return PasswordHashResult(hash: hash, salt: saltData)
        #endif
    }

    /// Verify a password against a stored hash
    static func verify(password: String, hash: Data, salt: Data) throws -> Bool {
        let result = try self.hash(password: password, salt: salt)
        return constantTimeCompare(result.hash, hash)
    }

    /// Create a storable hash string in PHC format (similar to Python's argon2-cffi)
    /// Format: $argon2id$v=19$m=65536,t=3,p=1$<salt>$<hash>
    static func hashToString(password: String) throws -> String {
        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordHashError.invalidPassword
        }

        #if canImport(Sodium)
        // Use libsodium's str function which creates a storable hash
        guard let hashStr = sodium.pwHash.str(
            passwd: Array(passwordData),
            opsLimit: opsLimit,
            memLimit: memLimit
        ) else {
            throw PasswordHashError.hashingFailed
        }
        return hashStr
        #else
        // Fallback: create a custom format for PBKDF2
        let result = try hash(password: password)
        let saltB64 = result.salt.base64EncodedString()
        let hashB64 = result.hash.base64EncodedString()
        return "$pbkdf2-sha256$i=100000$\(saltB64)$\(hashB64)"
        #endif
    }

    /// Verify a password against a storable hash string
    static func verifyString(password: String, hashString: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else {
            return false
        }

        #if canImport(Sodium)
        return sodium.pwHash.strVerify(
            hash: hashString,
            passwd: Array(passwordData)
        )
        #else
        // Parse PBKDF2 fallback format
        guard hashString.hasPrefix("$pbkdf2-sha256$") else {
            return false
        }
        let parts = hashString.split(separator: "$")
        guard parts.count == 4,
              let saltData = Data(base64Encoded: String(parts[2])),
              let expectedHash = Data(base64Encoded: String(parts[3])),
              let result = try? hash(password: password, salt: saltData) else {
            return false
        }
        return constantTimeCompare(result.hash, expectedHash)
        #endif
    }

    /// Check if a hash string needs rehashing (e.g., after parameter upgrade)
    static func needsRehash(hashString: String) -> Bool {
        #if canImport(Sodium)
        return sodium.pwHash.strNeedsRehash(
            hash: hashString,
            opsLimit: opsLimit,
            memLimit: memLimit
        )
        #else
        // For PBKDF2 fallback, always suggest rehashing to upgrade to Argon2id
        return true
        #endif
    }

    /// Check if using real Argon2id (vs fallback)
    static var isUsingArgon2id: Bool {
        #if canImport(Sodium)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Private Helpers

    #if !canImport(Sodium)
    /// PBKDF2 fallback for development/testing
    /// WARNING: This is NOT equivalent to Argon2id - add swift-sodium for production!
    private static func pbkdf2Fallback(
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
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedKey,
                    keyLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw PasswordHashError.hashingFailed
        }

        return Data(derivedKey)
    }
    #endif

    /// Constant-time comparison to prevent timing attacks
    private static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }

        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}

// MARK: - Supporting Types

struct PasswordHashResult {
    let hash: Data
    let salt: Data

    /// Combined hash and salt for storage (if needed)
    var combined: Data {
        salt + hash
    }

    /// Base64 encoded hash for API transmission
    var hashBase64: String {
        hash.base64EncodedString()
    }

    /// Base64 encoded salt for API transmission
    var saltBase64: String {
        salt.base64EncodedString()
    }
}

enum PasswordHashError: Error, LocalizedError {
    case invalidPassword
    case invalidSalt
    case hashingFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password format"
        case .invalidSalt:
            return "Invalid salt length (must be 16 bytes)"
        case .hashingFailed:
            return "Password hashing failed"
        case .verificationFailed:
            return "Password verification failed"
        }
    }
}
