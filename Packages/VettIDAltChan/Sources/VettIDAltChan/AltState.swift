import Foundation
import VettIDCrypto

/// What the app keeps per vault for the alternate channel (VAULT-MESSAGING §11.3 "App state", §11.10.6, §13.2): the
/// release it last unlocked into, the previous release of an unconfirmed move, the highest manifest serial, `state_seq`
/// and the highest `header_seq` per release (rollback floors), and a pending enrollment's nonce and measurements.
/// Immutable; the device replaces it under its lock. Mirrors vettid-android `AltState`.
public struct AltState: Equatable, Sendable, CustomStringConvertible {
    /// One enrollment request this device built: the nonce its `vault.enrolled` attestation must carry and the
    /// measurements and release number of the enclave it was sealed to (§11.3).
    public struct EnrollAttempt: Equatable, Sendable {
        public let nonce: [UInt8]
        public let pcrs: String
        public let number: UInt64
        /// The vault the request enrolled (the redeem's `vault_id`): only its `vault.enrolled` answers it.
        public let vaultID: String
        /// (iOS) The App Attest key id the request attested: the key the vault binds if this request made it (IOS-PLAN
        /// §6.2; chosen; not in the spec).
        public let attestKeyID: [UInt8]?

        public init(nonce: [UInt8], pcrs: String, number: UInt64, vaultID: String, attestKeyID: [UInt8]? = nil) {
            self.nonce = nonce
            self.pcrs = pcrs
            self.number = number
            self.vaultID = vaultID
            self.attestKeyID = attestKeyID
        }
    }

    /// How many earlier requests of one enrollment are kept besides the newest (chosen; not in the spec: the
    /// alternate channel's four attempts).
    public static let maxPriorEnrolls = 4

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
    /// The vault the pending enrollment's newest request enrolled.
    public var enrollVaultID = ""
    /// (iOS) The App Attest key id the pending enrollment's newest request attested.
    public var enrollAttestKeyID: [UInt8]?
    /// (iOS) The App Attest key id of the request whose `vault.enrolled` arrived: the key the vault bound, which the app
    /// confirms (IOS-PLAN §6.2; chosen; not in the spec).
    public var enrolledAttestKeyID: [UInt8]?
    /// Earlier requests of the same enrollment, oldest first (at most ``maxPriorEnrolls``): a request whose answer was
    /// lost may still have made the vault, and its `vault.enrolled` arrives after a retry replaced the newest nonce.
    public var enrollPrior: [EnrollAttempt] = []

    public init() {}

    public func marshal() -> String {
        let hs = JsonBuilder()
        for k in headerSeq.keys.sorted() { hs.uint(k, headerSeq[k] ?? 0) }
        let b = JsonBuilder().string("release", release).uint("release_number", releaseNumber)
            .string("previous_release", previousRelease).uint("previous_release_number", previousReleaseNumber)
            .uint("manifest_serial", manifestSerial).uint("state_seq", stateSeq).raw("header_seq", hs.build())
        if let n = enrollNonce { b.base64("enroll_nonce", n) }
        b.string("enroll_pcrs", enrollPcrs).uint("enroll_number", enrollNumber)
        if !enrollVaultID.isEmpty { b.string("enroll_vault_id", enrollVaultID) }
        if let k = enrollAttestKeyID { b.base64("enroll_attest_key_id", k) }
        if let k = enrolledAttestKeyID { b.base64("enrolled_attest_key_id", k) }
        if !enrollPrior.isEmpty {
            b.raw("enroll_prior", JsonBuilder.array(enrollPrior.map(Self.priorJSON)))
        }
        return b.build()
    }

    private static func priorJSON(_ a: EnrollAttempt) -> String {
        let o = JsonBuilder().base64("nonce", a.nonce).string("pcrs", a.pcrs).uint("number", a.number).string("vault_id", a.vaultID)
        if let k = a.attestKeyID { o.base64("attest_key_id", k) }
        return o.build()
    }

    /// Applies vault.enrolled to the app state (§11.3 "App state"): the release the enrollment was sealed to, and its
    /// state_seq; the pending enrollment's nonce and measurements are dropped.
    public func applyingEnrolled(stateSeq: UInt64?) -> AltState { applyingEnrolled(stateSeq: stateSeq, attempt: currentEnroll) }

    /// As ``applyingEnrolled(stateSeq:)`` for the request [attempt] (the newest or an earlier one of this enrollment)
    /// whose `vault.enrolled` arrived.
    public func applyingEnrolled(stateSeq: UInt64?, attempt: EnrollAttempt?) -> AltState {
        var s = self
        if let a = attempt, a.pcrs.utf8.count >= 96 {
            s.release = String(a.pcrs.prefix(96))
            s.releaseNumber = a.number
        }
        if let n = stateSeq, n > s.stateSeq { s.stateSeq = n }
        s = s.withoutEnrollment()
        if let k = attempt?.attestKeyID { s.enrolledAttestKeyID = k }
        return s
    }

    /// The pending enrollment, newest request first then the earlier ones, newest first.
    public var enrollAttempts: [EnrollAttempt] { (currentEnroll.map { [$0] } ?? []) + enrollPrior.reversed() }

    /// The newest request of the pending enrollment.
    public var currentEnroll: EnrollAttempt? {
        enrollNonce.map {
            EnrollAttempt(nonce: $0, pcrs: enrollPcrs, number: enrollNumber, vaultID: enrollVaultID, attestKeyID: enrollAttestKeyID)
        }
    }

    /// Without a pending enrollment: nothing of it is accepted any more (a refused or abandoned enrollment).
    public func withoutEnrollment() -> AltState {
        var s = self
        s.enrollNonce = nil
        s.enrollPcrs = ""
        s.enrollNumber = 0
        s.enrollVaultID = ""
        s.enrollAttestKeyID = nil
        s.enrollPrior = []
        return s
    }

    /// A new request of the enrollment of [vaultID]: the newest one is kept among the earlier ones (bounded); the
    /// requests of an enrollment of another vault are dropped (the app refuses a new vault while one of them may have
    /// made a vault).
    func startingEnrollRequest(
        nonce: [UInt8], pcrs: String, number: UInt64, vaultID: String, attestKeyID: [UInt8]? = nil
    ) -> AltState {
        var s = enrollAttempts.contains(where: { $0.vaultID != vaultID }) ? withoutEnrollment() : self
        if let cur = s.currentEnroll { s.enrollPrior = Array((s.enrollPrior + [cur]).suffix(Self.maxPriorEnrolls)) }
        s.enrollNonce = nonce
        s.enrollPcrs = pcrs
        s.enrollNumber = number
        s.enrollVaultID = vaultID
        s.enrollAttestKeyID = attestKeyID
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
        a.enrollVaultID = try o.optString("enroll_vault_id") ?? ""
        a.enrollAttestKeyID = try o.optString("enroll_attest_key_id").map { try Base64s.decodeStd($0) }
        a.enrolledAttestKeyID = try o.optString("enrolled_attest_key_id").map { try Base64s.decodeStd($0) }
        for v in try o.optArray("enroll_prior") ?? [] {
            let e = try v.asObject()
            a.enrollPrior.append(EnrollAttempt(
                nonce: try e.base64("nonce"), pcrs: try e.string("pcrs"), number: try e.uint("number", min: 0, max: max),
                vaultID: try e.optString("vault_id") ?? "",
                attestKeyID: try e.optString("attest_key_id").map { try Base64s.decodeStd($0) }
            ))
        }
        a.enrollPrior = Array(a.enrollPrior.suffix(maxPriorEnrolls))
        return a
    }
}
