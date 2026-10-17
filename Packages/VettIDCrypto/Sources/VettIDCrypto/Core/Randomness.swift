import Foundation
import Security

/// The one randomness source of the protocol code: key seeds, nonces, ULID entropy and HPKE encapsulation randomness
/// all come from here.
///
/// Production code always draws from the system's CSPRNG (`SecRandomCopyBytes`). The §16 test vectors need
/// deterministic draws ("Implementations supply it through a deterministic test hook"): ``withDeterministic(_:_:)``
/// substitutes a source for the duration of a block, for the current task only. The hook is compiled into debug
/// builds only (`#if DEBUG`): Staging and Release builds do not contain it, which the release check verifies through
/// ``testHookMarker``. Mirrors vettid-android `Randomness`.
public enum Randomness {
    /// Returns [n] random bytes.
    public static func bytes(_ n: Int) -> [UInt8] {
        #if DEBUG
        if let source = override {
            let b = source(n)
            precondition(b.count == n, testHookMarker)
            return b
        }
        #endif
        var b = [UInt8](repeating: 0, count: n)
        guard n > 0 else { return b }
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(status == errSecSuccess, "system randomness unavailable")
        return b
    }

    #if DEBUG
    /// TEST VECTORS ONLY: the source of the current task's draws inside ``withDeterministic(_:_:)``.
    @TaskLocal static var override: (@Sendable (Int) -> [UInt8])?

    /// A string only the debug-only hook contains; `scripts/release-check.sh` refuses it in Release and Staging.
    static let testHookMarker = "VETTID TEST ONLY: deterministic randomness drew the wrong size"

    /// TEST VECTORS ONLY: every draw inside [body] comes from [source].
    static func withDeterministic<T>(_ source: @escaping @Sendable (Int) -> [UInt8], _ body: () throws -> T) rethrows -> T {
        try $override.withValue(source, operation: body)
    }
    #endif
}
