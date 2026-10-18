import Foundation
import VettIDCrypto

/// Token failures (the relay's `token_invalid` and `token_expired`).
public enum TokenError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid
    case expired

    public var description: String {
        switch self {
        case .invalid: "token invalid"
        case .expired: "token expired"
        }
    }
}

/// PASETO v4.public with an empty footer and an empty implicit assertion (RELAY-PROTOCOL §5.1), as vettid-relay's
/// `relayauth` implements it. Ed25519 is deterministic, so the same key and message bytes always give the same token
/// (§9.2). Mirrors vettid-android `Paseto`.
public enum Paseto {
    public static let header = "v4.public."
    public static let maxTokenLength = 4096

    /// Pre-Authentication Encoding: the piece count and each piece's length as 64-bit little-endian (top bit clear).
    static func pae(_ pieces: [UInt8]...) -> [UInt8] {
        func le64(_ n: Int) -> [UInt8] {
            let v = UInt64(n) & UInt64(Int64.max)
            return (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
        }
        return le64(pieces.count) + pieces.flatMap { le64($0.count) + $0 }
    }

    private static func preAuth(_ m: [UInt8]) -> [UInt8] { pae(Array(header.utf8), m, [], []) }

    /// One spelling per token: only the base64url alphabet (no CR/LF, padding or footers).
    private static func isBase64URL(_ c: UInt8) -> Bool {
        (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2D || c == 0x5F
    }

    /// Signs the exact message bytes [m].
    public static func sign(_ key: Ed25519PrivateKey, _ m: [UInt8]) throws -> String {
        header + Base64s.encodeRawUrl(m + (try key.signRaw(preAuth(m))))
    }

    /// Checks the form and signature against [pub]; returns the signed message bytes.
    public static func verify(_ token: String, pub: [UInt8]) throws -> [UInt8] {
        guard token.utf8.count <= maxTokenLength, token.hasPrefix(header), pub.count == Suite.ed25519PublicSize else {
            throw TokenError.invalid
        }
        let rest = String(token.dropFirst(header.count))
        guard rest.utf8.allSatisfy(isBase64URL), let raw = try? Base64s.decodeRawUrl(rest), raw.count >= Suite.ed25519SignatureSize else {
            throw TokenError.invalid
        }
        let m = Array(raw[..<(raw.count - Suite.ed25519SignatureSize)])
        let sig = Array(raw[(raw.count - Suite.ed25519SignatureSize)...])
        guard Ed25519.verifyRaw(pub, preAuth(m), sig) else { throw TokenError.invalid }
        return m
    }
}
