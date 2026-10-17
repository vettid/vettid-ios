/// Padding of the inner plaintext (§5.4): `json || 0x80 || 0x00*` to the next multiple of 512 bytes up to 16 KiB,
/// above that to the next multiple of 16 KiB; the bucket is computed for len(json) + 1 and over-padding is malformed.
/// The alternate channel pads to fixed sizes. Mirrors vettid-android `Padding`.
public enum Padding {
    public static let minPadded = 512
    public static let smallBucketLimit = 16 * 1024
    public static let maxPadded = 245_760
    /// Fixed padded size of alternate-channel plaintexts.
    public static let altChannel = 4096
    /// Fixed padded size of `vault.enroll` and `vault.unlock`.
    public static let altChannelRequest = 12_288

    /// The bucket for a JSON plaintext of [n] bytes.
    public static func paddedLen(_ n: Int) throws -> Int {
        guard n >= 0 else { throw CryptoError.format("length") }
        let m = n + 1
        let p = m <= smallBucketLimit
            ? (m + minPadded - 1) / minPadded * minPadded
            : (m + smallBucketLimit - 1) / smallBucketLimit * smallBucketLimit
        guard p <= maxPadded else { throw CryptoError.format("padded plaintext too large") }
        return p
    }

    /// Whether [p] is a size some JSON length maps to.
    public static func isValidPaddedLen(_ p: Int) -> Bool {
        if p < minPadded || p > maxPadded { return false }
        return p <= smallBucketLimit ? p % minPadded == 0 : p % smallBucketLimit == 0
    }

    public static func pad(_ json: [UInt8]) throws -> [UInt8] { padTo(json, try paddedLen(json.count)) }

    /// Pads to exactly [n] bytes (a valid padded size that fits the JSON).
    public static func padFixed(_ json: [UInt8], _ n: Int) throws -> [UInt8] {
        guard isValidPaddedLen(n) else { throw CryptoError.format("length") }
        guard json.count + 1 <= n else { throw CryptoError.format("padded plaintext too large") }
        return padTo(json, n)
    }

    private static func padTo(_ json: [UInt8], _ n: Int) -> [UInt8] {
        var out = json
        out.append(0x80)
        out.append(contentsOf: [UInt8](repeating: 0, count: n - out.count))
        return out
    }

    /// Strictly removes bucket padding (no over-padding).
    public static func unpad(_ padded: [UInt8]) throws -> [UInt8] {
        let json = try unpadAny(padded)
        guard try paddedLen(json.count) == padded.count else { throw CryptoError.format("padding") }
        return json
    }

    /// Strictly removes fixed padding of exactly [n] bytes.
    public static func unpadFixed(_ padded: [UInt8], _ n: Int) throws -> [UInt8] {
        guard padded.count == n else { throw CryptoError.format("padding") }
        return try unpadAny(padded)
    }

    /// Finds the 0x80 marker scanning the whole buffer without a data-dependent early exit, as the Go reference does.
    private static func unpadAny(_ padded: [UInt8]) throws -> [UInt8] {
        guard isValidPaddedLen(padded.count) else { throw CryptoError.format("padding") }
        var marker = -1
        var trailingZero = 1
        for i in padded.indices.reversed() {
            let b = padded[i]
            let isZero = b == 0 ? 1 : 0
            let isMarker = b == 0x80 ? 1 : 0
            let first = trailingZero & (1 ^ isZero)
            if first & isMarker == 1 { marker = i }
            if first & (1 ^ isMarker) == 1 { marker = -2 }
            trailingZero &= isZero
        }
        guard marker >= 0 else { throw CryptoError.format("padding") }
        return Array(padded[0..<marker])
    }
}
