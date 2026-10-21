import CryptoKit
import Foundation

/// One-time codes from an `otp` field (VAULT-MESSAGING §10.7: an `otpauth://` URI or a base32 secret; apps show codes):
/// RFC 6238 TOTP over RFC 4226 HOTP. The seed stays the item's value; codes are computed on the phone when shown, and the
/// key is never printed or reflected. Mirrors vettid-android `Totp`.
public struct Totp: Sendable, CustomStringConvertible, CustomReflectable {
    /// The HMAC of RFC 6238 §1.2 (`algorithm` of an `otpauth://` URI).
    public enum Algorithm: String, Sendable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    private let key: [UInt8]
    public let digits: Int
    public let periodSeconds: Int64
    public let algorithm: Algorithm

    static let defaultDigits = 6
    static let defaultPeriod: Int64 = 30
    static let maxDigits = 8
    static let maxPeriod: Int64 = 3_600
    private static let pow10 = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

    private init(key: [UInt8], digits: Int, periodSeconds: Int64, algorithm: Algorithm) {
        self.key = key
        self.digits = digits
        self.periodSeconds = periodSeconds
        self.algorithm = algorithm
    }

    /// The code for the time step that holds [epochSeconds] (RFC 6238 §4: `T = floor(t / X)`, `T0` = 0).
    public func code(_ epochSeconds: Int64) -> String {
        let counter = UInt64(bitPattern: floorDiv(epochSeconds, periodSeconds))
        let message = Data((0..<8).map { UInt8(truncatingIfNeeded: counter >> (56 - 8 * $0)) })
        let k = SymmetricKey(data: key)
        let h: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: k))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: k))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: k))
        }
        // RFC 4226 §5.3, dynamic truncation.
        let off = Int(h[h.count - 1] & 0x0F)
        let bin = (Int(h[off]) & 0x7F) << 24 | Int(h[off + 1]) << 16 | Int(h[off + 2]) << 8 | Int(h[off + 3])
        let s = String(bin % Self.pow10[digits])
        return String(repeating: "0", count: digits - s.count) + s
    }

    /// Seconds until the code of [epochSeconds] changes.
    public func secondsLeft(_ epochSeconds: Int64) -> Int64 {
        periodSeconds - (epochSeconds - floorDiv(epochSeconds, periodSeconds) * periodSeconds)
    }

    private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    public var description: String { "Totp(\(digits) digits, \(periodSeconds)s)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Parses an `otp` value; nil when it is neither a valid `otpauth://totp/` URI nor a base32 secret.
    public static func parse(_ value: String) -> Totp? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.lowercased().hasPrefix("otpauth://") else {
            return base32(v).map { Totp(key: $0, digits: defaultDigits, periodSeconds: defaultPeriod, algorithm: .sha1) }
        }
        guard let u = URLComponents(string: v), u.host?.lowercased() == "totp" else { return nil }
        var q: [String: String] = [:]
        for item in u.queryItems ?? [] where !item.name.isEmpty {
            q[item.name.lowercased()] = item.value ?? ""
        }
        guard let key = q["secret"].flatMap(base32) else { return nil }
        // An unreadable number is the default, as vettid-android's `toIntOrNull() ?: default`.
        let digits = q["digits"].flatMap { Int($0) } ?? defaultDigits
        let period = q["period"].flatMap { Int64($0) } ?? defaultPeriod
        guard let algorithm = Algorithm(rawValue: (q["algorithm"] ?? "SHA1").uppercased()),
              (defaultDigits...maxDigits).contains(digits), (1...maxPeriod).contains(period) else { return nil }
        return Totp(key: key, digits: digits, periodSeconds: period, algorithm: algorithm)
    }

    /// RFC 4648 base32, case-insensitive, padding, spaces and hyphens ignored; nil when empty or not base32.
    public static func base32(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for c in s.uppercased().unicodeScalars where !" =-".unicodeScalars.contains(c) {
            let v: Int
            switch c {
            case "A"..."Z": v = Int(c.value) - 65
            case "2"..."7": v = Int(c.value) - 50 + 26
            default: return nil
            }
            buffer = (buffer << 5 | v) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }
}
