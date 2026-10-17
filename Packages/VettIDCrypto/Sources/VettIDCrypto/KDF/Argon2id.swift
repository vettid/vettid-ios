import Clibsodium

/// Argon2id (RFC 9106, version 0x13) with the parameter rules of VAULT-MESSAGING §3.3.1 and §3.5.1: new derivations use
/// t = 3, m = 64 MiB, p = 1; parameters below t = 1 or m = 8 MiB are refused. The vault runs the PIN and password KDFs
/// itself; the app uses this for local derivations and to check parameters. Mirrors vettid-android `Argon2id`.
///
/// libsodium's `crypto_pwhash` (IOS-PLAN ID6) takes a 16-byte salt and one lane, which is what §3.3.1 and §3.5.1 use;
/// other salt sizes and p > 1 are refused (Android's Bouncy Castle accepts them; nothing in the app uses them).
public enum Argon2id {
    public static let defaultT = 3
    public static let defaultMKiB = 64 * 1024
    public static let defaultP = 1
    public static let minT = 1
    public static let minMKiB = 8 * 1024
    public static let saltSize = 16

    /// Argon2id(password, salt, t, m KiB, p) → [length] bytes.
    public static func derive(
        password: [UInt8],
        salt: [UInt8],
        t: Int = defaultT,
        mKiB: Int = defaultMKiB,
        p: Int = defaultP,
        length: Int = 32
    ) throws -> [UInt8] {
        try checkParams(t: t, mKiB: mKiB, p: p)
        guard salt.count == Int(crypto_pwhash_SALTBYTES) else { throw CryptoError.key("argon2 salt") }
        guard p == 1 else { throw CryptoError.key("argon2 parallelism") }
        guard length >= Int(crypto_pwhash_BYTES_MIN) else { throw CryptoError.key("argon2 length") }
        Sodium.require()
        var out = [UInt8](repeating: 0, count: length)
        // A one-byte buffer stands in for an empty password (its length stays 0), so the pointer is never null.
        let buffer = password.isEmpty ? [0] : password
        let status = buffer.map { CChar(bitPattern: $0) }.withUnsafeBufferPointer { chars in
            crypto_pwhash(
                &out, UInt64(length),
                chars.baseAddress!, UInt64(password.count), // never empty: see above
                salt,
                UInt64(t), mKiB * 1024,
                crypto_pwhash_ALG_ARGON2ID13
            )
        }
        guard status == 0 else { throw CryptoError.key("argon2 failed") }
        return out
    }

    /// Refuses parameters below the floors of §3.3.1 / §3.5.1.
    public static func checkParams(t: Int, mKiB: Int, p: Int) throws {
        if t < minT || mKiB < minMKiB || p < 1 || mKiB < 8 * p { throw CryptoError.key("argon2 parameters") }
    }
}
