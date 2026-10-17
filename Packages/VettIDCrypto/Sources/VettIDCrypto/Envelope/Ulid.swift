import Foundation

/// ULIDs (§5.3): 26 upper-case Crockford base32 characters, the first in 0–7. Mirrors vettid-android `Ulid`.
public enum Ulid {
    public static let length = 26
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    public static func isValid(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == length && b[0] <= UInt8(ascii: "7") && b.allSatisfy(crockford.contains)
    }

    /// A ULID for [t]: 48 bits of milliseconds and 80 random bits.
    public static func new(_ t: Date = Date()) -> String {
        let ms = UInt64(max(0, (t.timeIntervalSince1970 * 1000).rounded(.down)))
        var b = (0..<6).map { UInt8(truncatingIfNeeded: ms >> (40 - 8 * UInt64($0))) }
        b.append(contentsOf: Randomness.bytes(10))
        return encode(b)
    }

    private static func encode(_ b: [UInt8]) -> String {
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for i in 0..<8 { hi = hi << 8 | UInt64(b[i]) }
        for i in 8..<16 { lo = lo << 8 | UInt64(b[i]) }
        var out = [UInt8](repeating: 0, count: length)
        for i in stride(from: length - 1, through: 0, by: -1) {
            out[i] = crockford[Int(lo & 31)]
            lo = lo >> 5 | hi << 59
            hi >>= 5
        }
        return String(out.map { Character(Unicode.Scalar($0)) }) // ASCII letters and digits
    }
}

/// Timestamps. Inner `ts`/`exp` are `YYYY-MM-DDTHH:MM:SS.mmmZ` (§5.3); bundles, manifests and descriptors use whole
/// seconds `YYYY-MM-DDTHH:MM:SSZ`. Parsing is strict: the string must round-trip exactly. ASCII digits in every locale
/// (no formatter or locale is involved). Mirrors vettid-android `Timestamps`.
public enum Timestamps {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Milliseconds since the epoch, truncated. `Date` holds seconds as a `Double`, in which a parsed `.123` can be
    /// `.122999…`: a tolerance of one microsecond keeps such values on their millisecond.
    private static func epochMillis(_ t: Date) -> Int64 { Int64((t.timeIntervalSince1970 * 1000 + 0.001).rounded(.down)) }

    /// Formats [t] in the inner format, truncating to milliseconds.
    public static func formatMillis(_ t: Date) -> String {
        let ms = epochMillis(t)
        let secs = Int64((Double(ms) / 1000).rounded(.down))
        return formatSecondsValue(secs) + "." + pad(Int(ms - secs * 1000), 3) + "Z"
    }

    /// Formats [t] in whole seconds (truncating).
    public static func formatSeconds(_ t: Date) -> String {
        formatSecondsValue(Int64(t.timeIntervalSince1970.rounded(.down))) + "Z"
    }

    public static func parseMillis(_ s: String) throws -> Date { try parse(s, millis: true) }
    public static func parseSeconds(_ s: String) throws -> Date { try parse(s, millis: false) }

    /// `YYYY-MM-DDTHH:MM:SS` of [secs] since the epoch, UTC.
    private static func formatSecondsValue(_ secs: Int64) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(secs)))
        return pad(c.year!, 4) + "-" + pad(c.month!, 2) + "-" + pad(c.day!, 2) + "T" +
            pad(c.hour!, 2) + ":" + pad(c.minute!, 2) + ":" + pad(c.second!, 2)
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private static func parse(_ s: String, millis: Bool) throws -> Date {
        let b = Array(s.utf8)
        guard b.count == (millis ? 24 : 20) else { throw CryptoError.format("timestamp") }
        func number(_ from: Int, _ count: Int) throws -> Int {
            var v = 0
            for k in from..<from + count {
                guard (0x30...0x39).contains(b[k]) else { throw CryptoError.format("timestamp") }
                v = v * 10 + Int(b[k] - 0x30)
            }
            return v
        }
        func expect(_ at: Int, _ c: Character) throws {
            guard b[at] == c.asciiValue else { throw CryptoError.format("timestamp") }
        }
        try expect(4, "-")
        try expect(7, "-")
        try expect(10, "T")
        try expect(13, ":")
        try expect(16, ":")
        var comps = DateComponents()
        comps.year = try number(0, 4)
        comps.month = try number(5, 2)
        comps.day = try number(8, 2)
        comps.hour = try number(11, 2)
        comps.minute = try number(14, 2)
        comps.second = try number(17, 2)
        var ms = 0
        if millis {
            try expect(19, ".")
            ms = try number(20, 3)
            try expect(23, "Z")
        } else {
            try expect(19, "Z")
        }
        guard let date = utc.date(from: comps) else { throw CryptoError.format("timestamp") }
        let t = Date(timeIntervalSince1970: date.timeIntervalSince1970 + Double(ms) / 1000)
        // Round trip: refuses out-of-range fields (February 30, hour 24) that the calendar would roll over.
        guard (millis ? formatMillis(t) : formatSeconds(t)) == s else { throw CryptoError.format("timestamp") }
        return t
    }
}
