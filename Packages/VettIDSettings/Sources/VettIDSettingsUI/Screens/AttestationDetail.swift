#if os(iOS)
import Foundation
import VettIDAttestation

/// What the attestation screen shows of a record (ANDROID-PLAN 0.1.124 §4 "Attestation in detail"), decided here, without
/// SwiftUI, so that the rules are tested directly: which values are shown, which are "Not verified", whether the Release
/// section exists, the notice, and the text of "Copy all". Mirrors vettid-android `AttestationDetail`.
enum AttestationDetail {
    /// The repository the signed release tags are in (VAULT-RELEASES §5.2). Built into the app.
    static let repository = "https://github.com/vettid/vettid-vault"

    /// The PCRs and "Attested at" rest on the chain and the hardware signature.
    static func documentVerified(_ r: EnclaveRecord) -> Bool { r.verified(.chain, .signature) }

    /// "Valid until" also rests on "Covers the key this phone encrypts to".
    static func notAfterVerified(_ r: EnclaveRecord) -> Bool { r.verified(.chain, .signature, .key) }

    /// "Release" (in the Enclave section) and the Release section: only once "Measurements match a signed release" passed.
    static func releaseShown(_ r: EnclaveRecord) -> Bool { r.verified(.match) && r.releaseNumber != nil }

    /// The manifest's key id and serial under line 1: only once it passed.
    static func manifestShown(_ r: EnclaveRecord) -> Bool {
        r.verified(.manifest) && r.manifestKeyID != nil && r.manifestSerial != nil
    }

    /// The release's signed tag, `release/prod/N` or `release/staging/N`; nil without a release or a channel.
    static func tag(_ r: EnclaveRecord, prefix: String?) -> String? {
        guard releaseShown(r), let prefix, let n = r.releaseNumber else { return nil }
        return "\(prefix)\(n)"
    }

    static func tagURL(_ tag: String) -> String { "\(repository)/releases/tag/\(tag)" }

    static func rebuildURL(_ tag: String) -> String { "\(repository)/blob/\(tag)/docs/RELEASING.md" }

    /// The failure notice: the check that failed, or a refusal after every check passed.
    enum Notice: Equatable {
        case failed
        case refused(EnclaveRefusal)
    }

    static func notice(_ r: EnclaveRecord) -> Notice? {
        if r.failed != nil { return .failed }
        if let why = r.refusal, r.allPassed { return .refused(why) }
        return nil
    }

    // MARK: - On screen (the member's language)

    static func checkLabel(_ c: AttestationCheck) -> String {
        switch c {
        case .manifest: AttestationStrings.checkManifest
        case .chain: AttestationStrings.checkChain
        case .signature: AttestationStrings.checkSignature
        case .key: AttestationStrings.checkKey
        case .recent: AttestationStrings.checkRecent
        case .notDebug: AttestationStrings.checkNotDebug
        case .ownRelease: AttestationStrings.checkOwnRelease
        case .validity: AttestationStrings.checkValidity
        case .match: AttestationStrings.checkMatch
        }
    }

    static func resultLabel(_ r: CheckResult) -> String {
        switch r {
        case .passed: AttestationStrings.checkPassed
        case .failed: AttestationStrings.checkFailed
        case .notRun: AttestationStrings.checkNotRun
        }
    }

    static func statusLabel(_ s: ReleaseStatus?) -> String {
        switch s {
        case .active?: AttestationStrings.statusActive
        case .deprecated?: AttestationStrings.statusDeprecated
        case .retired?: AttestationStrings.statusRetired
        case .removed?: AttestationStrings.statusRemoved
        case nil: ""
        }
    }

    /// Why the release was refused after every check passed (owner-approved, ANDROID-PLAN 0.1.125).
    static func refusalText(_ why: EnclaveRefusal) -> String {
        switch why {
        case .notActive: AttestationStrings.refusedNotActive
        case .olderRelease: AttestationStrings.refusedOlder
        case .otherInstance: AttestationStrings.refusedOtherInstance
        case .timeScale: AttestationStrings.refusedTimeScale
        }
    }

    /// The notice's text, or nil for none.
    static func noticeBody(_ r: EnclaveRecord) -> String? {
        switch notice(r) {
        case nil: nil
        case .failed?: AttestationStrings.failedBody
        case .refused(let why)?: AttestationStrings.refusedBody(refusalText(why))
        }
    }

    /// "Release N · Status", with ", ends <date>" when the entry has an end.
    static func releaseValue(_ r: EnclaveRecord, date: (Date) -> String) -> String {
        let ends = r.releaseEndsAt.map { AttestationStrings.ends(date($0)) } ?? ""
        return SettingsStrings.attestationReleaseValue(Int(clamping: r.releaseNumber ?? 0), statusLabel(r.releaseStatus)) + ends
    }

    // MARK: - "Copy all" (English)

    private static func statusEnglish(_ s: ReleaseStatus) -> String {
        switch s {
        case .active: "Active"
        case .deprecated: "Deprecated"
        case .retired: "Retired"
        case .removed: "Removed"
        }
    }

    private static func checkEnglish(_ c: AttestationCheck) -> String {
        switch c {
        case .manifest: "Release list signed by VettID"
        case .chain: "Certificate chain to the AWS Nitro root"
        case .signature: "Signed by AWS Nitro hardware"
        case .key: "Covers the key this phone encrypts to"
        case .recent: "Recent"
        case .notDebug: "Not a debug enclave"
        case .ownRelease: "Names its own release"
        case .validity: "Within its validity"
        case .match: "Measurements match a signed release"
        }
    }

    private static func resultEnglish(_ r: CheckResult) -> String {
        switch r {
        case .passed: "Passed"
        case .failed: "Failed"
        case .notRun: "Not checked"
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// "Copy all": the Enclave, Checks and Release sections as plain text, as shown, in English, values in full, times in
    /// ISO 8601 UTC. **This iPhone and the check's time are left out** (they identify the phone, IOS-PLAN §4.17): nothing of
    /// the account or the phone, no App Attest state or key id, and nothing secret.
    static func copyAll(_ r: EnclaveRecord, environment: String, tagPrefix: String?, root: String) -> String {
        var lines: [String] = []
        let notVerified = " (Not verified)"
        lines.append("Enclave")
        lines.append("Environment: \(environment)")
        if releaseShown(r), let n = r.releaseNumber {
            let ends = r.releaseEndsAt.map { ", ends \(iso($0))" } ?? ""
            lines.append("Release: Release \(n) · \(r.releaseStatus.map(statusEnglish) ?? "")\(ends)")
        }
        let doc = documentVerified(r) ? "" : notVerified
        for (label, v) in [("PCR0", r.pcr0), ("PCR1", r.pcr1), ("PCR2", r.pcr2)] {
            if let v { lines.append("\(label): \(v)\(doc)") }
        }
        if let t = r.attestedAt { lines.append("Attested at: \(iso(t))\(doc)") }
        if let t = r.notAfter { lines.append("Valid until: \(iso(t))\(notAfterVerified(r) ? "" : notVerified)") }
        lines.append("")
        lines.append("Checks")
        for c in AttestationCheck.allCases {
            lines.append("\(checkEnglish(c)): \(resultEnglish(r.result(c)))")
            if c == .manifest, manifestShown(r), let k = r.manifestKeyID, let s = r.manifestSerial {
                lines.append("  Key \(k) · serial \(s)")
            }
            if c == .chain { lines.append("  Root fingerprint (SHA-256): \(root)") }
        }
        if let t = tag(r, prefix: tagPrefix) {
            lines.append("")
            lines.append("Release")
            lines.append("Source: \(t) \(tagURL(t))")
            lines.append("Reproducible build: Anyone can rebuild this release from its tag and compare the measurements.")
            lines.append("How to rebuild it: \(rebuildURL(t))")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
