import Foundation
import Security

/// The one randomness source of the protocol code: key seeds, nonces, ULID entropy and HPKE encapsulation randomness
/// all come from here.
///
/// Production code always draws from the system's CSPRNG (`SecRandomCopyBytes`). The §16 test vectors need
/// deterministic draws ("Implementations supply it through a deterministic test hook"): ``withDeterministic(_:_:)``
/// substitutes a source for the duration of a block, for the current task only. It is `internal`, so no other module
/// and no app code can reach it; only this package's tests (`@testable`) use it. Mirrors vettid-android `Randomness`.
public enum Randomness {
    /// TEST VECTORS ONLY: the source of the current task's draws inside ``withDeterministic(_:_:)``.
    @TaskLocal static var override: (@Sendable (Int) -> [UInt8])?

    /// Returns [n] random bytes.
    public static func bytes(_ n: Int) -> [UInt8] {
        if let source = override {
            let b = source(n)
            precondition(b.count == n, "deterministic source returned the wrong size")
            return b
        }
        var b = [UInt8](repeating: 0, count: n)
        guard n > 0 else { return b }
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(status == errSecSuccess, "system randomness unavailable")
        return b
    }

    /// TEST VECTORS ONLY: every draw inside [body] comes from [source].
    static func withDeterministic<T>(_ source: @escaping @Sendable (Int) -> [UInt8], _ body: () throws -> T) rethrows -> T {
        try $override.withValue(source, operation: body)
    }
}
