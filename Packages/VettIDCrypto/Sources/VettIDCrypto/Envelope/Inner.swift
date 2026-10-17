import Foundation

/// Envelope modes (§5.2).
public enum Mode: UInt8, Sendable {
    case session = 0x01
    case sealed = 0x02
}

/// The `error` member of a response.
public struct InnerError: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

/// The inner plaintext (§5.3). Marshalling writes members in the order v, id, type, ts, seq, re, exp, status, error,
/// body, exactly as the Go reference does; parsing is strict (unknown members ignored, known members exactly typed,
/// duplicate names rejected at any depth). Mirrors vettid-android `Inner`.
public struct Inner: Sendable, CustomStringConvertible {
    public let id: String
    public let type: String
    public let ts: Date
    /// Session mode only (≥ 1); 0 means absent.
    public let seq: UInt64
    /// Responses: the id of the request answered.
    public let re: String?
    public let exp: Date?
    /// Responses: `ok` or `error`.
    public let status: String?
    public let error: InnerError?
    /// The body object's JSON (`{}` when empty).
    public let body: [UInt8]

    public static let version: UInt64 = 1
    public static let statusOK = "ok"
    public static let statusError = "error"
    public static let maxTypeLen = 64
    public static let maxErrorCodeLen = 64
    public static let maxErrorMessageLen = 1024
    public static let maxClockSkewFuture: TimeInterval = 5 * 60
    public static let maxDurableAge: TimeInterval = 16 * 86_400
    public static let emptyBody = Array("{}".utf8)

    public init(
        id: String,
        type: String,
        ts: Date,
        seq: UInt64 = 0,
        re: String? = nil,
        exp: Date? = nil,
        status: String? = nil,
        error: InnerError? = nil,
        body: [UInt8] = Inner.emptyBody
    ) {
        self.id = id
        self.type = type
        self.ts = ts
        self.seq = seq
        self.re = re
        self.exp = exp
        self.status = status
        self.error = error
        self.body = body
    }

    /// A copy with [seq] set (sealing in an epoch assigns it).
    public func withSeq(_ seq: UInt64) -> Inner {
        Inner(id: id, type: type, ts: ts, seq: seq, re: re, exp: exp, status: status, error: error, body: body)
    }

    func validate(_ mode: Mode) throws { // swiftlint:disable:this cyclomatic_complexity
        guard Ulid.isValid(id), Self.validType(type) else { throw CryptoError.format("inner") }
        switch mode {
        case .session: guard (1...StrictJson.maxSafeInteger).contains(seq) else { throw CryptoError.format("inner seq") }
        case .sealed: guard seq == 0 else { throw CryptoError.format("inner seq") }
        }
        if let re, !Ulid.isValid(re) { throw CryptoError.format("inner re") }
        guard (re == nil) == (status == nil) else { throw CryptoError.format("inner re/status") }
        switch status {
        case nil: break
        case Self.statusOK?: if error != nil { throw CryptoError.format("inner error") }
        case Self.statusError?: if error == nil { throw CryptoError.format("inner error") }
        default: throw CryptoError.format("inner status")
        }
        if status != Self.statusError, error != nil { throw CryptoError.format("inner error") }
        if let error, !Self.validErrorCode(error.code) || error.message.utf8.count > Self.maxErrorMessageLen {
            throw CryptoError.format("inner error")
        }
    }

    /// Encodes the inner plaintext as compact JSON.
    public func marshal(_ mode: Mode) throws -> [UInt8] {
        try validate(mode)
        let b = try StrictJson.compactObject(body)
        let jb = JsonBuilder()
            .uint("v", Self.version)
            .string("id", id)
            .string("type", type)
            .string("ts", Timestamps.formatMillis(ts))
        if mode == .session { jb.uint("seq", seq) }
        if let re { jb.string("re", re) }
        if let exp { jb.string("exp", Timestamps.formatMillis(exp)) }
        if let status { jb.string("status", status) }
        if let error {
            let eb = JsonBuilder().string("code", error.code)
            if !error.message.isEmpty { eb.string("message", error.message) }
            jb.raw("error", eb.build())
        }
        jb.raw("body", b)
        return jb.bytes()
    }

    /// Freshness (§8.4, §5.3): `ts` at most 5 minutes in the future; for durable types at most 16 days old; `exp`,
    /// if present, not passed.
    public func checkTime(now: Date, durable: Bool) throws {
        if ts.timeIntervalSince(now) > Self.maxClockSkewFuture { throw CryptoError.time("timestamp in the future") }
        if durable, now.timeIntervalSince(ts) > Self.maxDurableAge { throw CryptoError.time("timestamp too old") }
        if let exp, now > exp { throw CryptoError.time("expired") }
    }

    public var description: String { "Inner(id=\(id), type=\(type))" }

    /// `[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)*`, at most 64 bytes.
    public static func validType(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard !b.isEmpty, b.count <= maxTypeLen else { return false }
        var start = true
        for (i, c) in b.enumerated() {
            switch c {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): start = false
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): if start { return false }
            case UInt8(ascii: "."):
                if start || i == b.count - 1 { return false }
                start = true
            default: return false
            }
        }
        return true
    }

    private static func validErrorCode(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard !b.isEmpty, b.count <= maxErrorCodeLen else { return false }
        return b.enumerated().allSatisfy { i, c in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || c == UInt8(ascii: "_") ||
                (i > 0 && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c))
        }
    }

    /// Parses an unpadded inner plaintext strictly.
    public static func parse(_ b: [UInt8], _ mode: Mode) throws -> Inner {
        let o = try StrictJson.parseObject(b)
        guard try o.uint("v", min: version, max: version) == version else { throw CryptoError.format("inner v") }
        let id = try o.string("id")
        let type = try o.string("type")
        let ts = try Timestamps.parseMillis(o.string("ts"))
        let seq = try o.optUint("seq", min: 1, max: StrictJson.maxSafeInteger)
        guard (seq != nil) == (mode == .session) else { throw CryptoError.format("inner seq") }
        let re = try o.optString("re")
        if let re, re.isEmpty { throw CryptoError.format("inner re") }
        let exp = try o.optString("exp").map(Timestamps.parseMillis)
        let status = try o.optString("status")
        if let status, status.isEmpty { throw CryptoError.format("inner status") }
        let error = try o.optObj("error").map { InnerError(try $0.string("code"), try $0.optString("message") ?? "") }
        let body = try o.obj("body").rawBytes
        let inner = Inner(id: id, type: type, ts: ts, seq: seq ?? 0, re: re, exp: exp, status: status, error: error, body: body)
        try inner.validate(mode)
        return inner
    }

    /// Marshals and bucket-pads.
    public static func encode(_ inner: Inner, _ mode: Mode) throws -> [UInt8] { try Padding.pad(inner.marshal(mode)) }

    /// Strictly unpads and parses.
    public static func decode(_ padded: [UInt8], _ mode: Mode) throws -> Inner { try parse(Padding.unpad(padded), mode) }
}

private extension JsonObject {
    var rawBytes: [UInt8] { Array(raw.utf8) }
}
