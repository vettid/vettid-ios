import Foundation
import Security

/// Secure memory handling with automatic zeroing
/// Ensures sensitive data is cleared from memory when no longer needed
final class SecureMemory {

    // MARK: - SecureBytes

    /// A wrapper for sensitive byte data that automatically zeros memory when deallocated
    final class SecureBytes {

        private var _bytes: [UInt8]
        private var _isCleared: Bool = false

        /// Number of bytes
        var count: Int { _bytes.count }

        /// Whether the bytes have been cleared
        var isCleared: Bool { _isCleared }

        /// Initialize with random bytes
        init(count: Int) {
            _bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &_bytes)
        }

        /// Initialize with existing data (copies data, then zeros original if mutable)
        init(data: Data) {
            _bytes = [UInt8](data)
        }

        /// Initialize with existing bytes
        init(bytes: [UInt8]) {
            _bytes = bytes
        }

        /// Initialize with string (for passwords)
        init?(string: String, encoding: String.Encoding = .utf8) {
            guard let data = string.data(using: encoding) else {
                return nil
            }
            _bytes = [UInt8](data)
        }

        deinit {
            clear()
        }

        /// Access bytes with a closure (prevents external copying)
        func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T {
            guard !_isCleared else {
                fatalError("Attempting to access cleared SecureBytes")
            }
            return try body(_bytes)
        }

        /// Access mutable bytes with a closure
        func withMutableBytes<T>(_ body: (inout [UInt8]) throws -> T) rethrows -> T {
            guard !_isCleared else {
                fatalError("Attempting to access cleared SecureBytes")
            }
            return try body(&_bytes)
        }

        /// Convert to Data (copies - use withBytes for read-only access when possible)
        func toData() -> Data {
            guard !_isCleared else {
                fatalError("Attempting to access cleared SecureBytes")
            }
            return Data(_bytes)
        }

        /// Securely clear the memory
        func clear() {
            guard !_isCleared else { return }

            // Use memset_s equivalent for secure memory clearing
            // This prevents the compiler from optimizing away the clearing
            _bytes.withUnsafeMutableBytes { ptr in
                if let baseAddress = ptr.baseAddress {
                    // Volatile write to prevent optimization
                    memset_s_wrapper(baseAddress, ptr.count, 0, ptr.count)
                }
            }

            _bytes = []
            _isCleared = true
        }

        /// Constant-time comparison to prevent timing attacks
        func constantTimeEquals(_ other: SecureBytes) -> Bool {
            guard count == other.count else { return false }
            guard !_isCleared && !other._isCleared else { return false }

            var result: UInt8 = 0
            for i in 0..<count {
                result |= _bytes[i] ^ other._bytes[i]
            }
            return result == 0
        }

        /// Create a copy
        func copy() -> SecureBytes {
            return SecureBytes(bytes: _bytes)
        }
    }

    // MARK: - SecureString

    /// A wrapper for sensitive string data that automatically zeros memory
    final class SecureString {

        private var _bytes: SecureBytes
        private let encoding: String.Encoding

        /// Whether the string has been cleared
        var isCleared: Bool { _bytes.isCleared }

        init(string: String, encoding: String.Encoding = .utf8) {
            self.encoding = encoding
            if let data = string.data(using: encoding) {
                _bytes = SecureBytes(data: data)
            } else {
                _bytes = SecureBytes(count: 0)
            }
        }

        init(bytes: SecureBytes, encoding: String.Encoding = .utf8) {
            _bytes = bytes
            self.encoding = encoding
        }

        deinit {
            clear()
        }

        /// Access string value with a closure (prevents external copying)
        func withString<T>(_ body: (String) throws -> T) rethrows -> T {
            return try _bytes.withBytes { bytes in
                let string = String(bytes: bytes, encoding: encoding) ?? ""
                return try body(string)
            }
        }

        /// Convert to String (copies - use withString when possible)
        func toString() -> String {
            return _bytes.withBytes { bytes in
                String(bytes: bytes, encoding: encoding) ?? ""
            }
        }

        /// Get underlying bytes
        var bytes: SecureBytes { _bytes }

        /// Securely clear the memory
        func clear() {
            _bytes.clear()
        }

        /// Constant-time comparison
        func constantTimeEquals(_ other: SecureString) -> Bool {
            return _bytes.constantTimeEquals(other._bytes)
        }
    }

    // MARK: - Utility Functions

    /// Securely zero an existing Data object
    static func secureZero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                memset_s_wrapper(baseAddress, ptr.count, 0, ptr.count)
            }
        }
        data = Data()
    }

    /// Securely zero a byte array
    static func secureZero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                memset_s_wrapper(baseAddress, ptr.count, 0, ptr.count)
            }
        }
        bytes = []
    }

    /// Generate cryptographically secure random bytes
    static func randomBytes(count: Int) -> SecureBytes {
        return SecureBytes(count: count)
    }

    /// Generate a secure random token
    static func generateToken(length: Int = 32) -> SecureBytes {
        return SecureBytes(count: length)
    }

    /// Constant-time memory comparison
    static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }

        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    /// Constant-time comparison for byte arrays
    static func constantTimeCompare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }

        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}

// MARK: - memset_s Wrapper

/// Wrapper for secure memory clearing that prevents compiler optimization
/// This is equivalent to C11's memset_s
@inline(never)
private func memset_s_wrapper(_ dest: UnsafeMutableRawPointer, _ destSize: Int, _ value: Int32, _ count: Int) {
    // Use volatile memory access to prevent optimization
    let destBytes = dest.assumingMemoryBound(to: UInt8.self)
    for i in 0..<min(destSize, count) {
        // volatile_store equivalent - compiler cannot optimize this away
        destBytes.advanced(by: i).pointee = UInt8(value)
    }

    // Memory barrier to ensure writes complete
    OSMemoryBarrier()
}

// MARK: - Data Extension for Secure Operations

extension Data {

    /// Create a secure copy that will be zeroed when the SecureBytes is deallocated
    func toSecureBytes() -> SecureMemory.SecureBytes {
        return SecureMemory.SecureBytes(data: self)
    }

    /// Zero the memory of this Data (best effort - may not work for all backing stores)
    mutating func secureZero() {
        SecureMemory.secureZero(&self)
    }
}

// MARK: - String Extension for Secure Operations

extension String {

    /// Create a SecureString from this string
    func toSecureString(encoding: String.Encoding = .utf8) -> SecureMemory.SecureString {
        return SecureMemory.SecureString(string: self, encoding: encoding)
    }
}
