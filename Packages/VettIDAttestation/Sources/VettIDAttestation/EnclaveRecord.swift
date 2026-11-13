import Foundation

/// The app's checks of an enclave (ANDROID-PLAN 0.1.124 §4 "Attestation in detail"; VAULT-MESSAGING §11.2), in the order the
/// app makes them. Each is one line of the attestation screen. Mirrors vettid-android `EnclaveCheck`.
public enum AttestationCheck: String, CaseIterable, Codable, Sendable {
    /// The release manifest's format, its signature under a pinned key, its serial not going back (§11.10.1).
    case manifest
    /// The document's format (a COSE_Sign1, ES384 only) and its certificate chain to the pinned AWS Nitro root.
    case chain
    /// The document's COSE_Sign1 ES384 signature by the chain's leaf.
    case signature
    /// The descriptor's format, and user_data = SHA-256("vettid/vms/2/etk" ‖ descriptor).
    case key
    /// Less than 26 hours old, at most 5 minutes ahead of the phone's clock.
    case recent
    /// No debug PCRs.
    case notDebug
    /// The descriptor's `release` equals PCR0.
    case ownRelease
    /// `not_after` in the future and at most 24 h + 5 min after the document.
    case validity
    /// PCR0–2 equal to an entry of the manifest.
    case match

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One line's state. "Passed" only with a recorded pass; anything not run is ``notRun``.
public enum CheckResult: String, Codable, Sendable {
    case passed, failed, notRun
}

/// Why a verification whose nine checks all passed was still refused (ANDROID-PLAN 0.1.124: "Every check passed, but…";
/// the reasons 0.1.125). Mirrors vettid-android `EnclaveRefusal`.
public enum EnclaveRefusal: String, Codable, Sendable {
    /// The release is not `active`, and this was an enrollment.
    case notActive
    /// The release is older than one this phone has unlocked into (§11.10.6).
    case olderRelease
    /// The verified descriptor names another instance than the one the request would go to.
    case otherInstance
    /// (STAGING-TIME-SCALE §4 item 4) The release's time scale is one this build does not accept.
    case timeScale
}

/// The record of one verification of the enclave instance the vault runs on (ANDROID-PLAN 0.1.124 §4 "Attestation in
/// detail", IOS-PLAN §6.9): each check's result, the values the attestation screen shows, and when it was made. Public
/// material only: nothing of the account, the phone or a secret.
///
/// A value is in the record only once what carries it has been read; whether it may be shown plainly is
/// ``verified(_:)`` of the checks it rests on (the screen says "Not verified" otherwise). The results can only be made by
/// ``results(passed:failed:)``, so a "Passed" never follows a check that did not pass. Mirrors vettid-android
/// `EnclaveRecord`.
public struct EnclaveRecord: Equatable, Sendable {
    public var at: Date
    public private(set) var results: [AttestationCheck: CheckResult]
    /// The manifest's signing key id and serial: once ``AttestationCheck/manifest`` passed.
    public var manifestKeyID: String?
    public var manifestSerial: UInt64?
    public var pcr0: String?
    public var pcr1: String?
    public var pcr2: String?
    /// The attestation document's timestamp.
    public var attestedAt: Date?
    /// The descriptor's `not_after`.
    public var notAfter: Date?
    /// The matching manifest entry: once ``AttestationCheck/match`` passed.
    public var releaseNumber: UInt64?
    public var releaseStatus: ReleaseStatus?
    public var releaseEndsAt: Date?
    public var refusal: EnclaveRefusal?

    /// [passed] checks passed, in order, and the next one failed when [failed].
    public init(at: Date, passed: Int, failed: Bool) {
        self.at = at
        results = Self.results(passed: passed, failed: failed)
    }

    public func result(_ c: AttestationCheck) -> CheckResult { results[c] ?? .notRun }

    /// Every one of [checks] passed.
    public func verified(_ checks: AttestationCheck...) -> Bool { checks.allSatisfy { result($0) == .passed } }

    /// The check that failed, or nil.
    public var failed: AttestationCheck? { AttestationCheck.allCases.first { result($0) == .failed } }

    /// Every check passed.
    public var allPassed: Bool { AttestationCheck.allCases.allSatisfy { result($0) == .passed } }

    /// How many checks passed, in order (the run so far).
    public var passedCount: Int { AttestationCheck.allCases.prefix { result($0) == .passed }.count }

    /// This record with [passed] checks passed and the next one failed when [failed]; every later one not run.
    func with(passed: Int, failed: Bool) -> EnclaveRecord {
        var r = self
        r.results = Self.results(passed: passed, failed: failed)
        return r
    }

    /// The results when [passed] passed, in order, and the next one failed ([failed]); every later check is
    /// ``CheckResult/notRun``.
    static func results(passed: Int, failed: Bool) -> [AttestationCheck: CheckResult] {
        Dictionary(uniqueKeysWithValues: AttestationCheck.allCases.map { c in
            let i = c.index
            return (c, i < passed ? .passed : failed && i == passed ? .failed : .notRun)
        })
    }

    /// [results] read back (a stored record): only a run, the passes in order followed by at most one failure and nothing
    /// after it; anything else is nil, so the screen never shows a pass that was not recorded in order.
    public static func run(_ results: [AttestationCheck: CheckResult]) -> (passed: Int, failed: Bool)? {
        guard Set(results.keys) == Set(AttestationCheck.allCases) else { return nil }
        let passed = AttestationCheck.allCases.prefix { results[$0] == .passed }.count
        let failed = passed < AttestationCheck.allCases.count && results[AttestationCheck.allCases[passed]] == .failed
        guard Self.results(passed: passed, failed: failed) == results else { return nil }
        return (passed, failed)
    }

    /// A manifest refused (its signature, key, format or serial): line 1 failed, nothing else checked.
    public static func manifestFailed(at: Date) -> EnclaveRecord { EnclaveRecord(at: at, passed: 0, failed: true) }
}

/// Where a verification's record goes: the phone keeps the last one (IOS-PLAN §6.9). Mirrors vettid-android
/// `EnclaveRecords`.
public protocol EnclaveRecords: Sendable {
    func record(_ r: EnclaveRecord)
}

/// A verification: the verified enclave, or the failure; and its record either way. Mirrors vettid-android
/// `EnclaveVerification`.
public struct EnclaveVerification: Sendable {
    public let record: EnclaveRecord
    private let verified: VerifiedEnclave?
    private let failure: AttestationError?

    public init(_ enclave: VerifiedEnclave, record: EnclaveRecord) {
        verified = enclave
        failure = nil
        self.record = record
    }

    public init(failure: AttestationError, record: EnclaveRecord) {
        verified = nil
        self.failure = failure
        self.record = record
    }

    /// The verified enclave, or the failure thrown.
    public func enclave() throws -> VerifiedEnclave {
        if let verified { return verified }
        throw failure ?? AttestationError.format("verification")
    }
}
