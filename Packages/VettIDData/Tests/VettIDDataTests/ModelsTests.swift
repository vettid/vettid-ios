import Foundation
import Testing
import VettIDData

/// The display models' derived values (vettid-android `vault/Models.kt`, `AccountEmailTest`'s last case).
@Suite struct ModelsTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theAddressToShow() {
        #expect(AccountInfo(emailHint: "").displayEmail == nil)
        #expect(AccountInfo(emailHint: "m***@example.com").displayEmail == "m***@example.com")
        #expect(AccountInfo(emailHint: "a***@example.org", email: "ada@example.org").displayEmail == "ada@example.org")
        #expect(AccountInfo(emailHint: "a***@example.org", email: "  ").displayEmail == "a***@example.org")
    }

    @Test func theAccount() {
        let a = AccountInfo(emailHint: "", state: "member", accountStatus: "canceled", firstName: "Ada", lastName: "King")
        #expect(a.hasSnapshot && a.canceled)
        #expect(a.fullName == "Ada King")
        #expect(!AccountInfo(emailHint: "").hasSnapshot)
        let later = AccountInfo(emailHint: "", nameAllowedAfter: t0)
        #expect(later.nameChangeTooSoon(now: t0 - 1))
        #expect(!later.nameChangeTooSoon(now: t0))
        #expect(!AccountInfo(emailHint: "").nameChangeTooSoon(now: t0))
    }

    @Test func anExpiredSubscriptionReadsExpired() {
        let trial = SubscriptionInfo(typeName: "Trial", status: "trial", paid: false, expiresAt: t0)
        #expect(trial.status(at: t0 - 1) == "trial")
        #expect(trial.status(at: t0) == "expired")
        let canceled = SubscriptionInfo(typeName: nil, status: "canceled", paid: true, expiresAt: t0)
        #expect(canceled.status(at: t0 + 1) == "canceled")
        #expect(SubscriptionInfo(typeName: nil, status: "active", paid: true, expiresAt: nil).status(at: t0) == "active")
    }

    @Test func aReleaseFingerprintIsTheFirstSixteenHexDigits() {
        let r = ReleaseView(number: 3, pcr0: "0123456789abcdef0123", status: "active", endsAt: nil, notes: "")
        #expect(r.fingerprint == "0123 4567 89ab cdef")
        #expect(ReleaseView(number: 3, pcr0: "abcdef", status: "active", endsAt: nil, notes: "").fingerprint == "abcd ef")
    }

    @Test func recoveryOpenOutcome() {
        #expect(RecoveryOpenOutcome("ok").ok)
        #expect(RecoveryOpenOutcome("wrong", used: 3).left == 7)
        #expect(RecoveryOpenOutcome("exhausted", used: 12).left == 0)
        #expect(RecoveryOpenOutcome("busy").left == nil)
    }

    @Test func deletionIsCancellableOnlyWithItsIDAndBeforeItRuns() {
        #expect(DeletionView(deletesAt: t0, executing: false, deletionID: "d").cancellable)
        #expect(!DeletionView(deletesAt: t0, executing: true, deletionID: "d").cancellable)
        #expect(!DeletionView(deletesAt: t0, executing: false, deletionID: nil).cancellable)
    }

    @Test func aSetupCodeOrTypedRecoveryCodeIsNeverPrinted() {
        let s = SetupCodeInput.secret("SECRET-123")
        let t = SetupCodeInput.typed(email: "ada@example.org", code: "ABCD2345")
        for text in ["\(s)", String(reflecting: s), "\(t)", String(reflecting: t)] {
            #expect(!text.contains("SECRET") && !text.contains("ada@") && !text.contains("ABCD"))
        }
    }

    @Test func theSmallerModels() {
        #expect(LockNotice.unconfirmed(askedAt: t0, attempts: 1).inDoubt)
        #expect(!LockNotice.unconfirmed(askedAt: t0, attempts: 0).inDoubt)
        #expect(!LockNotice.confirmedLate.inDoubt)
        #expect(CredentialAlarm(alarmID: "a", state: "frozen", at: nil).frozen)
        #expect(CredentialAlarm(alarmID: "a", state: "rotation_required", at: nil).rotationRequired)
        #expect(SignerClass.of("google_play") == .googlePlay)
        #expect(SignerClass.of("apple") == nil && SignerClass.of(nil) == nil)
        #expect(NameRequestState.of("refused") == .refused && NameRequestState.of("x") == nil)
        #expect(AppPhase.unreachable(.network) == .unreachable(.network, longUnreachable: false))
    }
}
