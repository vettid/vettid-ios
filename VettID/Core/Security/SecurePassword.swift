import Foundation

/// A wipe-able container for password / PIN / seed-phrase material.
///
/// Why not just use a `String`?
/// Swift strings are immutable and bridge to NSString on Apple platforms;
/// once a password lands in one, the underlying bytes can't be overwritten
/// — they sit in heap pages until ARC happens to free them, often well
/// after you'd want the material gone. Forensic tools and heap-dump
/// analysis recover them readily.
///
/// `SecurePassword` wraps the credential as a mutable UTF-8 byte buffer and
/// exposes `wipe()`, which zeroes it via `memset_s` (guaranteed not to be
/// elided by the optimizer). After `wipe()` the instance is single-use;
/// further reads throw `SecurePasswordError.wiped`.
///
/// Ownership contract: a function that **takes** a `SecurePassword` either
///   - calls `wipe()` on it (directly or via `use { }`) before returning
///     (it's "consumed"), OR
///   - documents that ownership is passed onward to a downstream function
///     that will consume it.
///
/// Recommended call shape:
///
/// ```swift
/// SecurePassword(string: input).use { pw in
///     try cryptoManager.hashPasswordPHC(pw, salt: salt)
///     // pw is wiped automatically when the closure returns or throws.
/// }
/// ```
///
/// Boundary truth: passwords still appear briefly as `String` at the
/// SwiftUI `TextField` boundary because the framework hands `String` back
/// from text input. We can't avoid that. The point of this class is to
/// bound the in-memory window to that one frame, then carry the material
/// through the rest of the app as wipeable bytes.
///
/// SECURITY (auth-A9, parity with Android `SecurePassword`).
final class SecurePassword {

    private var buffer: [UInt8]
    private var wiped: Bool = false

    /// Number of UTF-8 bytes; after `wipe()` returns 0.
    var byteCount: Int { wiped ? 0 : buffer.count }

    var isEmpty: Bool { byteCount == 0 }

    /// Build a SecurePassword by copying the UTF-8 bytes out of a String.
    /// The caller should drop their `String` reference immediately after
    /// (e.g. clear the SwiftUI state binding) so ARC is free to release it.
    convenience init(string: String) {
        self.init(bytes: Array(string.utf8))
    }

    /// Adopt an existing byte array as the SecurePassword's buffer. The
    /// caller MUST NOT retain or reuse the array after handing it over —
    /// the SecurePassword owns it and will wipe it.
    init(bytes: [UInt8]) {
        self.buffer = bytes
    }

    /// Empty / sentinel password. Safe to use without wiping.
    static let empty: SecurePassword = SecurePassword(bytes: [])

    /// Run `body` with a transient view of the UTF-8 bytes. The view is
    /// valid only inside the closure; the bytes are NOT retained by the
    /// caller after return. Throws `SecurePasswordError.wiped` if the
    /// SecurePassword has already been wiped.
    func withUTF8Bytes<R>(_ body: ([UInt8]) throws -> R) throws -> R {
        guard !wiped else { throw SecurePasswordError.wiped }
        return try body(buffer)
    }

    /// Returns a fresh UTF-8 byte copy. The caller owns the new buffer
    /// and is responsible for wiping it (e.g. `bytes.secureWipe()`).
    /// Prefer `withUTF8Bytes` unless you must hand bytes to an async
    /// boundary.
    func copyUTF8Bytes() throws -> [UInt8] {
        guard !wiped else { throw SecurePasswordError.wiped }
        return Array(buffer)
    }

    /// UTF-8 length without revealing or copying the bytes.
    func utf8Length() -> Int { byteCount }

    /// Run `body` then guarantee `wipe()`, even if `body` throws.
    /// Mirrors Android `SecurePassword.use {}`.
    @discardableResult
    func use<R>(_ body: (SecurePassword) throws -> R) rethrows -> R {
        defer { wipe() }
        return try body(self)
    }

    /// Async-throwing variant of `use`.
    @discardableResult
    func use<R>(_ body: (SecurePassword) async throws -> R) async rethrows -> R {
        defer { wipe() }
        return try await body(self)
    }

    /// Overwrite the underlying buffer with zeros via `memset_s`. Idempotent;
    /// safe to call multiple times.
    func wipe() {
        if wiped { return }
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
        wiped = true
    }

    deinit { wipe() }
}

enum SecurePasswordError: Error, LocalizedError {
    case wiped

    var errorDescription: String? {
        switch self {
        case .wiped: return "SecurePassword has been wiped"
        }
    }
}

extension Array where Element == UInt8 {
    /// Zero the array's storage via `memset_s` (not elided by the optimizer).
    /// Use after consuming bytes copied out of a `SecurePassword`.
    mutating func secureWipe() {
        withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}
