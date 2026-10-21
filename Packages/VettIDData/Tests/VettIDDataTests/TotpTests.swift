import Foundation
import Testing
@testable import VettIDData

// The RFC's table: one row per time.
// swiftlint:disable large_tuple

/// One-time codes of `otp` fields (VAULT-MESSAGING §10.7): every value of RFC 6238 Appendix B (the three HMACs at the six
/// times, eight digits, 30-second steps), and the cases of vettid-android's `TotpTest`. The seeds are the RFC's ASCII keys
/// in base32 (RFC 4648).
@Suite struct TotpTests {
    /// "12345678901234567890" (20 bytes, SHA-1).
    static let sha1Seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    /// "12345678901234567890123456789012" (32 bytes, SHA-256).
    static let sha256Seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA===="
    /// "1234567890" × 6 + "1234" (64 bytes, SHA-512).
    static let sha512Seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA="

    /// RFC 6238 Appendix B: time, SHA-1, SHA-256, SHA-512.
    static let table: [(Int64, String, String, String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]

    @Test func everyRfc6238Vector() throws {
        let sha1 = try #require(Totp.parse("otpauth://totp/Example:alice?secret=\(Self.sha1Seed)&digits=8&issuer=Example"))
        let sha256 = try #require(Totp.parse("otpauth://totp/x?secret=\(Self.sha256Seed)&algorithm=SHA256&digits=8"))
        let sha512 = try #require(Totp.parse("otpauth://totp/x?secret=\(Self.sha512Seed)&algorithm=sha512&digits=8&period=30"))
        #expect(sha1.algorithm == .sha1 && sha256.algorithm == .sha256 && sha512.algorithm == .sha512)
        for (t, a, b, c) in Self.table {
            #expect(sha1.code(t) == a, "SHA-1 at \(t)")
            #expect(sha256.code(t) == b, "SHA-256 at \(t)")
            #expect(sha512.code(t) == c, "SHA-512 at \(t)")
        }
    }

    @Test func aBareBase32SecretGivesSixDigitsEveryThirtySeconds() throws {
        let spaced = stride(from: 0, to: Self.sha1Seed.count, by: 4).map { i in
            String(Self.sha1Seed.lowercased().dropFirst(i).prefix(4))
        }.joined(separator: " ")
        let t = try #require(Totp.parse(spaced))
        #expect(t.digits == 6 && t.periodSeconds == 30)
        #expect(t.code(59) == "287082")
        #expect(t.secondsLeft(59) == 1 && t.secondsLeft(60) == 30)
        #expect(t.code(-1) == t.code(-30) && t.secondsLeft(-1) == 1, "before 1970 the steps count down from 0")
    }

    @Test func unreadableSeedsMakeNoCodes() {
        #expect(Totp.parse("not a seed!") == nil)
        #expect(Totp.parse("") == nil)
        #expect(Totp.parse("otpauth://hotp/x?secret=\(Self.sha1Seed)&counter=1") == nil)
        #expect(Totp.parse("otpauth://totp/x?digits=6") == nil)
        #expect(Totp.parse("otpauth://totp/x?secret=\(Self.sha1Seed)&algorithm=MD5") == nil)
        #expect(Totp.parse("otpauth://totp/x?secret=\(Self.sha1Seed)&digits=12") == nil)
        #expect(Totp.parse("otpauth://totp/x?secret=\(Self.sha1Seed)&period=0") == nil)
        #expect(Totp.parse("otpauth://totp/x?secret=\(Self.sha1Seed)&period=60")?.periodSeconds == 60)
        // An unreadable number is the default, as vettid-android reads it.
        #expect(Totp.parse("otpauth://totp/x?secret=\(Self.sha1Seed)&digits=six")?.digits == 6)
    }

    @Test func theKeyIsNeverPrinted() throws {
        let t = try #require(Totp.parse(Self.sha1Seed))
        #expect("\(t)" == "Totp(6 digits, 30s)")
        #expect(String(reflecting: t) == "Totp(6 digits, 30s)" || !String(reflecting: t).contains("key"))
        #expect(Totp.base32("MZXW6===") == Array("foo".utf8) && Totp.base32("mzxw-6") == Array("foo".utf8))
        #expect(Totp.base32("1") == nil && Totp.base32("==") == nil)
    }
}

// swiftlint:enable large_tuple
