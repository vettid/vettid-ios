import Foundation
import VettIDCrypto

/// What the app keeps per vault for the alternate channel (VAULT-MESSAGING §11.3 "App state", §11.10.6, §13.2): the
/// release it last unlocked into, the previous release of an unconfirmed move, the highest manifest serial, `state_seq`
/// and the highest `header_seq` per release (rollback floors), and a pending enrollment's nonce and measurements.
/// Immutable; the device replaces it under its lock. Mirrors vettid-android `AltState`.
public struct AltState: Equatable, Sendable, CustomStringConvertible {
    public var release = ""
    public var releaseNumber: UInt64 = 0
    public var previousRelease = ""
    public var previousReleaseNumber: UInt64 = 0
    public var manifestSerial: UInt64 = 0
    public var stateSeq: UInt64 = 0
    public var headerSeq: [String: UInt64] = [:]
    public var enrollNonce: [UInt8]?
    /// PCR0 || PCR1 || PCR2 of the enclave the enrollment was sealed to.
    public var enrollPcrs = ""
    public var enrollNumber: UInt64 = 0

    public init() {}

    public func marshal() -> String {
        let hs = JsonBuilder()
        for k in headerSeq.keys.sorted() { hs.uint(k, headerSeq[k] ?? 0) }
        let b = JsonBuilder().string("release", release).uint("release_number", releaseNumber)
            .string("previous_release", previousRelease).uint("previous_release_number", previousReleaseNumber)
            .uint("manifest_serial", manifestSerial).uint("state_seq", stateSeq).raw("header_seq", hs.build())
        if let n = enrollNonce { b.base64("enroll_nonce", n) }
        return b.string("enroll_pcrs", enrollPcrs).uint("enroll_number", enrollNumber).build()
    }

    /// Applies vault.enrolled to the app state (§11.3 "App state"): the release the enrollment was sealed to, and its
    /// state_seq; the pending enrollment's nonce and measurements are dropped.
    public func applyingEnrolled(stateSeq: UInt64?) -> AltState {
        var s = self
        if s.enrollPcrs.utf8.count >= 96 {
            s.release = String(s.enrollPcrs.prefix(96))
            s.releaseNumber = s.enrollNumber
        }
        if let n = stateSeq, n > s.stateSeq { s.stateSeq = n }
        s.enrollNonce = nil
        s.enrollPcrs = ""
        s.enrollNumber = 0
        return s
    }

    public var description: String { "AltState(release=\(releaseNumber), stateSeq=\(stateSeq), manifestSerial=\(manifestSerial))" }

    public static func parse(_ o: JsonObject) throws -> AltState {
        let max = StrictJson.maxSafeInteger
        var a = AltState()
        a.release = try o.optString("release") ?? ""
        a.releaseNumber = try o.optUint("release_number", min: 0, max: max) ?? 0
        a.previousRelease = try o.optString("previous_release") ?? ""
        a.previousReleaseNumber = try o.optUint("previous_release_number", min: 0, max: max) ?? 0
        a.manifestSerial = try o.optUint("manifest_serial", min: 0, max: max) ?? 0
        a.stateSeq = try o.optUint("state_seq", min: 0, max: max) ?? 0
        if let hs = try o.optObj("header_seq") {
            for m in hs.members { a.headerSeq[m.name] = try hs.uint(m.name, min: 0, max: max) }
        }
        a.enrollNonce = try o.optString("enroll_nonce").map { try Base64s.decodeStd($0) }
        a.enrollPcrs = try o.optString("enroll_pcrs") ?? ""
        a.enrollNumber = try o.optUint("enroll_number", min: 0, max: max) ?? 0
        return a
    }
}
