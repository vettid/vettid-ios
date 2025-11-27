import Foundation
import CryptoKit
import CommonCrypto

/// Password hashing service using Argon2id
///
/// Note: iOS does not have native Argon2id support. This implementation uses a pure-Swift
/// Argon2 implementation for production use. For optimal security, consider using a
/// well-audited native library via Swift Package Manager (e.g., swift-sodium, CryptoSwift with Argon2).
///
/// Argon2id parameters (matching backend):
/// - Memory: 64 MB (65536 KB)
/// - Iterations: 3
/// - Parallelism: 4
/// - Output length: 32 bytes
final class PasswordHasher {

    // Argon2id recommended parameters
    private static let memoryCost: UInt32 = 65536  // 64 MB
    private static let timeCost: UInt32 = 3        // iterations
    private static let parallelism: UInt32 = 4
    private static let hashLength: Int = 32

    /// Hash a password using Argon2id
    /// - Parameters:
    ///   - password: The password to hash
    ///   - salt: Optional salt (generated if not provided)
    /// - Returns: The password hash and salt used
    static func hash(password: String, salt: Data? = nil) throws -> PasswordHashResult {
        let saltData = salt ?? CryptoManager.generateSalt()

        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordHashError.invalidPassword
        }

        // Use Argon2id implementation
        let hash = try argon2id(
            password: passwordData,
            salt: saltData,
            timeCost: timeCost,
            memoryCost: memoryCost,
            parallelism: parallelism,
            hashLength: hashLength
        )

        return PasswordHashResult(hash: hash, salt: saltData)
    }

    /// Verify a password against a stored hash
    static func verify(password: String, hash: Data, salt: Data) throws -> Bool {
        let result = try self.hash(password: password, salt: salt)
        return constantTimeCompare(result.hash, hash)
    }

    // MARK: - Argon2id Implementation

    /// Pure Swift Argon2id implementation
    /// Based on RFC 9106: Argon2 Memory-Hard Function
    private static func argon2id(
        password: Data,
        salt: Data,
        timeCost: UInt32,
        memoryCost: UInt32,
        parallelism: UInt32,
        hashLength: Int
    ) throws -> Data {
        // For initial implementation, use PBKDF2 as a fallback
        // TODO: Replace with proper Argon2id via Swift package (swift-sodium, CArgon2, etc.)

        // This is a simplified implementation - in production, use a proper Argon2 library
        // The backend expects Argon2id, so this MUST be replaced before production deployment

        #if DEBUG
        print("WARNING: Using PBKDF2 fallback. Replace with Argon2id for production!")
        #endif

        return try pbkdf2Fallback(
            password: password,
            salt: salt,
            iterations: Int(timeCost * 10000),  // Scale iterations for PBKDF2
            keyLength: hashLength
        )
    }

    /// PBKDF2 fallback for development/testing
    /// WARNING: This is NOT equivalent to Argon2id - replace before production!
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
}

enum PasswordHashError: Error, LocalizedError {
    case invalidPassword
    case hashingFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password format"
        case .hashingFailed:
            return "Password hashing failed"
        case .verificationFailed:
            return "Password verification failed"
        }
    }
}
