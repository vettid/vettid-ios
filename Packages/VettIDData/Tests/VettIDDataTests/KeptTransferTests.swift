import Foundation
import Testing
import VettIDData
import VettIDVault

/// The old phone's keys after a transfer it approved (VAULT-MESSAGING §11.14.10; owner decisions of 2026-10-15 and
/// 2026-10-16). Mirrors vettid-android `PhoneSecretsTest`'s `KeptTransfer` and `FinishMoveProof` cases.
@Suite struct KeptTransferTests {
    let day: Int64 = 86_400_000

    @Test func theKeepIsSevenDaysAndShortenedByTheTimeScale() {
        #expect(KeptTransfer.keepPeriodMs == 7 * day)
        #expect(KeptTransfer.keepMs(timeScale: 1) == 7 * day)
        // STAGING-TIME-SCALE S10: staging runs 24 times faster, 7 days are 7 hours.
        #expect(KeptTransfer.keepMs(timeScale: 24) == 7 * 3_600_000)
    }

    @Test func theKeepEndsAtSevenDaysAndNotBefore() {
        let t0: Int64 = 1_000_000
        #expect(KeptTransfer.decide(approvedAtMs: t0, nowMs: t0) == .keep(remainingMs: 7 * day))
        #expect(KeptTransfer.decide(approvedAtMs: t0, nowMs: t0 + day) == .keep(remainingMs: 6 * day))
        #expect(KeptTransfer.decide(approvedAtMs: t0, nowMs: t0 + 7 * day - 1) == .keep(remainingMs: 1))
        #expect(KeptTransfer.decide(approvedAtMs: t0, nowMs: t0 + 7 * day) == .erase)
        #expect(KeptTransfer.decide(approvedAtMs: t0, nowMs: t0 + 30 * day) == .erase)
    }

    @Test func aScaledKeepIsDecidedWithTheScaleItWasStartedWith() {
        let keep = KeptTransfer.keepMs(timeScale: 24)
        #expect(KeptTransfer.decide(approvedAtMs: 0, nowMs: keep - 1, keepMs: keep) == .keep(remainingMs: 1))
        #expect(KeptTransfer.decide(approvedAtMs: 0, nowMs: keep, keepMs: keep) == .erase)
    }

    /// A clock set before the approval counts from now: it never lengthens the keep beyond the period from the moment it
    /// is noticed, and the start is stored so that later checks do not extend it again.
    @Test func aClockBehindTheApprovalCountsFromNow() {
        #expect(KeptTransfer.start(approvedAtMs: 5_000, nowMs: 9_000) == 5_000)
        #expect(KeptTransfer.start(approvedAtMs: 9_000, nowMs: 5_000) == 5_000)
        #expect(KeptTransfer.decide(approvedAtMs: 9_000, nowMs: 5_000) == .keep(remainingMs: 7 * day))
    }

    @Test func onlyAMissingAnswerMayHaveReachedTheVault() {
        #expect(KeptTransfer.mayHaveReached(.noResponse))
        for kind in [FailureKind.badPin, .badPassword, .backoff, .network, .other, .rejected] {
            #expect(!KeptTransfer.mayHaveReached(kind), "\(kind)")
        }
    }

    private func device(_ id: String, _ kind: String) throws -> DeviceEntry {
        let json = #"{"id":"\#(id)","kind":"\#(kind)","state":"active"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DeviceEntry.self, from: Data(json.utf8))
    }

    /// The end-of-keep check: this phone is still the vault's app only when the list names it as an `app`.
    @Test func aPhoneStillTheAppKeepsItsKeysAnythingElseErases() throws {
        let list = [try device("d-1", "desktop"), try device("d-2", "app")]
        #expect(KeptTransfer.stillTheApp(deviceList: list, deviceID: "d-2"))
        #expect(!KeptTransfer.stillTheApp(deviceList: list, deviceID: "d-1"), "a desktop is not the app")
        #expect(!KeptTransfer.stillTheApp(deviceList: list, deviceID: "d-9"), "not listed")
        #expect(!KeptTransfer.stillTheApp(deviceList: [], deviceID: "d-2"))
        #expect(!KeptTransfer.stillTheApp(deviceList: nil, deviceID: "d-2"), "no answer erases")
        #expect(!KeptTransfer.stillTheApp(deviceList: list, deviceID: nil))
    }

    @Test func aSuccessOvertakenByALockOrAWipeProvesNothing() {
        #expect(FinishMoveProof.provedBy(resultOk: true, overtaken: false))
        #expect(!FinishMoveProof.provedBy(resultOk: true, overtaken: true))
        #expect(!FinishMoveProof.provedBy(resultOk: false, overtaken: false))
        #expect(!FinishMoveProof.provedBy(resultOk: false, overtaken: true))
    }
}
