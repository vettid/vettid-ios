#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDAttestation
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// Settings → Attestation in detail (ANDROID-PLAN 0.1.124 §4 "Attestation in detail", the refusal reasons 0.1.125; IOS-PLAN
/// §4.17): vettid-android's texts, one line per check where a check that did not pass never shows as passed, the values
/// that rest on a check that did not pass marked "Not verified", the notice, and "Copy all" with nothing of This iPhone.
/// Mirrors vettid-android `AttestationDetailTest`.
@MainActor
@Suite struct AttestationDetailTests {
    let at = Date(timeIntervalSince1970: 1_791_384_000)
    let pcr0 = String(repeating: "a3", count: 48)
    let pcr1 = String(repeating: "11", count: 48)
    let pcr2 = String(repeating: "22", count: 48)
    let root = NitroRoot.sha256Hex

    /// A record of [passed] checks passed (and the next failed when [failed]), with the values each step would have read.
    func record(passed: Int = 9, failed: Bool = false) -> EnclaveRecord {
        var r = EnclaveRecord(at: at, passed: passed, failed: failed)
        r.manifestKeyID = "1edbb48b6669decd"
        r.manifestSerial = 7
        if passed >= 3 {
            r.pcr0 = pcr0
            r.pcr1 = pcr1
            r.pcr2 = pcr2
            r.attestedAt = Date(timeIntervalSince1970: 1_791_380_000)
        }
        if passed >= 4 || (passed == 3 && failed) { r.notAfter = Date(timeIntervalSince1970: 1_791_466_400) }
        if passed == 9 {
            r.releaseNumber = 3
            r.releaseStatus = .deprecated
            r.releaseEndsAt = Date(timeIntervalSince1970: 1_793_500_000)
        }
        return r
    }

    @Test func theTextsAreAndroids() {
        #expect(AttestationStrings.none == "This phone hasn't verified your vault's enclave yet. It does at the next unlock.")
        #expect(AttestationStrings.failedTitle == "Verification failed")
        #expect(AttestationStrings.failedBody == "This phone couldn't verify your vault's enclave, so it sent it nothing. The check that failed is marked below.")
        #expect(AttestationStrings.refusedBody(AttestationStrings.refusedNotActive) == "Every check passed, but this phone refused the release: it isn't offered to new phones.")
        #expect(AttestationStrings.refusedOlder == "it's older than a release this phone has already used.")
        #expect(AttestationStrings.refusedOtherInstance == "your vault's address named a different enclave.")
        #expect(AttestationStrings.refusedTimeScale == "its time setting is for test builds, not this app.")
        #expect(SettingsStrings.attestationRelease == "Release")
        #expect(AttestationStrings.ends("x") == ", ends x")
        #expect(AttestationStrings.asOf("x") == "as of x")
        #expect(AttestationStrings.manifestKey("1edbb48b6669decd", 7) == "Key 1edbb48b6669decd · serial 7")
        #expect(AttestationStrings.checkSpoken("Recent", "Passed") == "Recent: Passed")
        #expect(AttestationStrings.rebuildBody == "Anyone can rebuild this release from its tag and compare the measurements.")
        #expect(AttestationStrings.iosVersion == "iOS version")
        #expect(AttestationCheck.allCases.map(AttestationDetail.checkLabel) == [
            "Release list signed by VettID", "Certificate chain to the AWS Nitro root", "Signed by AWS Nitro hardware",
            "Covers the key this phone encrypts to", "Recent", "Not a debug enclave", "Names its own release", "Within its validity",
            "Measurements match a signed release",
        ])
        #expect([CheckResult.passed, .failed, .notRun].map(AttestationDetail.resultLabel) == ["Passed", "Failed", "Not checked"])
    }

    /// Every run the verifier can record: the checks before the failure "Passed", the failure "Failed", every later one
    /// "Not checked", on screen and to VoiceOver; never "Passed" for a check that did not pass.
    @Test func aSkippedOrFailedCheckNeverShowsAsPassed() {
        let n = AttestationCheck.allCases.count
        for passed in 0...n {
            for failed in [false, true] where !(failed && passed == n) {
                let r = EnclaveRecord(at: at, passed: passed, failed: failed)
                for (i, c) in AttestationCheck.allCases.enumerated() {
                    let want = i < passed ? "Passed" : failed && i == passed ? "Failed" : "Not checked"
                    #expect(AttestationDetail.resultLabel(r.result(c)) == want, "\(passed) \(failed) \(c)")
                    #expect(CheckLine.spoken(c, r.result(c)) == "\(AttestationDetail.checkLabel(c)): \(want)")
                }
            }
        }
    }

    @Test func aValueIsPlainOnlyWhenEveryCheckItRestsOnPassed() {
        let all = record()
        #expect(AttestationDetail.documentVerified(all) && AttestationDetail.notAfterVerified(all))
        #expect(AttestationDetail.releaseShown(all) && AttestationDetail.manifestShown(all))
        // "Covers the key" failed: the document's values are verified, "Valid until" is not.
        let key = record(passed: 3, failed: true)
        #expect(AttestationDetail.documentVerified(key) && !AttestationDetail.notAfterVerified(key))
        #expect(!AttestationDetail.releaseShown(key))
        // A record whose chain did not pass shows no value plainly, whatever it holds.
        var chain = EnclaveRecord(at: at, passed: 1, failed: true)
        chain.pcr0 = pcr0
        chain.notAfter = at
        chain.releaseNumber = 3
        #expect(!AttestationDetail.documentVerified(chain) && !AttestationDetail.notAfterVerified(chain) && !AttestationDetail.releaseShown(chain))
        #expect(AttestationDetail.copyAll(chain, environment: "STAGING", tagPrefix: "release/staging/", root: root).contains("PCR0: \(pcr0) (Not verified)"))
        // A refused list: line 1 failed, no key or serial shown, only the environment in the Enclave section.
        let list = EnclaveRecord.manifestFailed(at: at)
        #expect(!AttestationDetail.manifestShown(list))
        #expect(AttestationDetail.copyAll(list, environment: "STAGING", tagPrefix: "release/staging/", root: root).hasPrefix("Enclave\nEnvironment: STAGING\n\nChecks\n"))
    }

    @Test func theReleasesTagAndItsLinks() {
        let all = record()
        #expect(AttestationDetail.tag(all, prefix: "release/prod/") == "release/prod/3")
        #expect(AttestationDetail.tag(all, prefix: nil) == nil)
        #expect(AttestationDetail.tag(record(passed: 8, failed: true), prefix: "release/prod/") == nil)
        #expect(AttestationDetail.tagURL("release/staging/3") == "https://github.com/vettid/vettid-vault/releases/tag/release/staging/3")
        #expect(AttestationDetail.rebuildURL("release/staging/3") == "https://github.com/vettid/vettid-vault/blob/release/staging/3/docs/RELEASING.md")
        #expect(AttestationDetail.releaseValue(all) { _ in "D" } == "Release 3 · Deprecated, ends D")
    }

    @Test func theNotice() {
        #expect(AttestationDetail.notice(record()) == nil)
        #expect(AttestationDetail.notice(record(passed: 4, failed: true)) == .failed)
        #expect(AttestationDetail.noticeBody(record(passed: 4, failed: true)) == AttestationStrings.failedBody)
        for why in [EnclaveRefusal.notActive, .olderRelease, .otherInstance, .timeScale] {
            var r = record()
            r.refusal = why
            #expect(AttestationDetail.notice(r) == .refused(why))
            #expect(AttestationDetail.noticeBody(r) == AttestationStrings.refusedBody(AttestationDetail.refusalText(why)))
            // A refusal with a line that did not pass is the failure's notice, never "Every check passed".
            var partial = record(passed: 8, failed: true)
            partial.refusal = why
            #expect(AttestationDetail.notice(partial) == .failed)
        }
    }

    /// IOS-PLAN §4.17 "Test": "Copy all" holds no This iPhone section, no App Attest state or key id, no attestation object
    /// and no check time; the Enclave, Checks and Release sections in English, values in full, times in ISO 8601 UTC.
    @Test func copyAllHoldsThePublicMaterialOnly() {
        let text = AttestationDetail.copyAll(record(), environment: "STAGING", tagPrefix: "release/staging/", root: root)
        #expect(text == """
            Enclave
            Environment: STAGING
            Release: Release 3 · Deprecated, ends 2026-11-01T02:26:40Z
            PCR0: \(pcr0)
            PCR1: \(pcr1)
            PCR2: \(pcr2)
            Attested at: 2026-10-07T13:33:20Z
            Valid until: 2026-10-08T13:33:20Z

            Checks
            Release list signed by VettID: Passed
              Key 1edbb48b6669decd · serial 7
            Certificate chain to the AWS Nitro root: Passed
              Root fingerprint (SHA-256): \(root)
            Signed by AWS Nitro hardware: Passed
            Covers the key this phone encrypts to: Passed
            Recent: Passed
            Not a debug enclave: Passed
            Names its own release: Passed
            Within its validity: Passed
            Measurements match a signed release: Passed

            Release
            Source: release/staging/3 https://github.com/vettid/vettid-vault/releases/tag/release/staging/3
            Reproducible build: Anyone can rebuild this release from its tag and compare the measurements.
            How to rebuild it: https://github.com/vettid/vettid-vault/blob/release/staging/3/docs/RELEASING.md
            """)
        for leak in ["iPhone", "App Attest", "Accepted", "iOS", "App version", "2026-10-07T14:40", "as of"] {
            #expect(!text.contains(leak), "\(leak)")
        }
    }

    /// Every state draws: none yet, each failure, each refusal, every check passed; an iPhone's and an Android-shaped value.
    @Test func everyStateDraws() {
        var iPhone = AttestationInfo.iPhone(environment: "STAGING", appAttest: AppAttestInfo(accepted: true), lastRelease: 3, lastReleaseFingerprint: nil)
        iPhone.appVersion = "1.0 (7)"
        iPhone.osVersion = "26.1"
        iPhone.releaseTagPrefix = "release/staging/"
        let android = AttestationInfo(
            environment: "PRODUCTION", keyPresent: true, keyLevel: "TEE", strongBoxAvailable: false, attestationVersion: 300,
            verifiedBoot: "Verified", deviceLocked: true, bootKeyFingerprint: nil, lastRelease: 3, lastReleaseFingerprint: "aaaa"
        )
        var records: [EnclaveRecord?] = [nil, record(), EnclaveRecord.manifestFailed(at: at)]
        for p in 1..<9 { records.append(record(passed: p, failed: true)) }
        for why in [EnclaveRefusal.notActive, .olderRelease, .otherInstance, .timeScale] {
            var r = record()
            r.refusal = why
            records.append(r)
        }
        for a in [iPhone, android] {
            for r in records {
                #expect(height(AttestationContent(state: LoadState(loading: false, value: a), record: r, copy: { _ in })) > 0)
            }
        }
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
// swiftlint:enable line_length
#endif
