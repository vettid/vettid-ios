import Foundation
import VettIDCrypto

/// Secret bytes held by reference, so that the one who wipes them wipes the only copy: a critical item's opened values
/// (`values_sealed`'s plaintext, VAULT-MESSAGING §10.7) on their way from the vault client to ``ItemsManager``, which wipes
/// them once parsed. Never printed or reflected.
public final class SecretBytes: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Runs [body] over the bytes.
    public func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T {
        try lock.withLock { try body(bytes) }
    }

    /// Zeroes the bytes in place.
    public func wipe() { lock.withLock { Bytes.wipe(&bytes) } }

    /// Whether every byte is zero (wiped, or never anything else).
    public var isWiped: Bool { lock.withLock { bytes.allSatisfy { $0 == 0 } } }

    public var description: String { "SecretBytes(…)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
