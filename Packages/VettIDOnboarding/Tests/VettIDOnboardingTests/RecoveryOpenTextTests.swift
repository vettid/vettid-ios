import Foundation
import Testing
import VettIDData
@testable import VettIDOnboarding

// swiftlint:disable line_length

/// The recovery open's answers (ANDROID-PLAN 0.1.40's table), the countdown and which answers end the recovery. Mirrors
/// vettid-android `RecoveryOpenTextTest`; the words are `RecoveryStrings`'s (their tests are the screens').
@Suite struct RecoveryOpenTextTests {
    let at = Date(timeIntervalSince1970: 1_792_497_600)

    func text(_ o: RecoveryOpenOutcome, _ incomplete: Bool = false) -> OpenAnswerText { openAnswerText(o, rightButIncomplete: incomplete) }

    @Test func theAnswersOfTheTable() {
        #expect(text(RecoveryOpenOutcome("wrong", used: 1)) == OpenAnswerText(.wrong, number: 9))
        #expect(text(RecoveryOpenOutcome("wrong", used: 2, retryAt: at)) == OpenAnswerText(.wrongWait, number: 8, withRetryAt: true))
        #expect(text(RecoveryOpenOutcome("wrong_again", used: 2)).key == .wrongAgain)
        #expect(text(RecoveryOpenOutcome("attempt_lost", used: 3)) == OpenAnswerText(.attemptLost, number: 7))
        // quiet and wait say how many attempts are left, never whether this request used one (the result does not tell).
        #expect(text(RecoveryOpenOutcome("quiet", retryAt: at)) == OpenAnswerText(.quiet, withRetryAt: true, attemptsLeft: nil))
        #expect(text(RecoveryOpenOutcome("quiet", used: 4, retryAt: at)) == OpenAnswerText(.quiet, withRetryAt: true, attemptsLeft: 6))
        #expect(text(RecoveryOpenOutcome("quiet", used: 4)) == OpenAnswerText(.quietNoDate, attemptsLeft: 6))
        #expect(text(RecoveryOpenOutcome("wait", used: 2, retryAt: at)) == OpenAnswerText(.wait, withRetryAt: true, attemptsLeft: 8))
        #expect(text(RecoveryOpenOutcome("wait", used: 2)) == OpenAnswerText(.waitNoDate, attemptsLeft: 8))
        let keys: [(String, OpenAnswerKey)] = [
            ("busy", .busy), ("retry", .retry), ("stored_mismatch", .storedMismatch), ("closed", .closed), ("not_armed", .notArmed),
            ("counter_unavailable", .counterUnavailable), ("no_recovery", .noRecovery), ("expired", .expired),
            ("attestation", .attestation), ("manifest", .manifest), ("wrong_release", .wrongRelease), ("bad_request", .badRequest),
        ]
        for (code, key) in keys { #expect(text(RecoveryOpenOutcome(code)).key == key, "\(code)") }
        #expect(text(RecoveryOpenOutcome("stored_mismatch", used: 3)).key == .storedMismatchRight)
        #expect(text(RecoveryOpenOutcome("exhausted", used: 10)).key == .exhausted)
        #expect(text(RecoveryOpenOutcome("ok", used: 3)) == OpenAnswerText(.ok, number: 3))
        #expect(text(RecoveryOpenOutcome("ok")).key == .okPlain)
        #expect(text(RecoveryOpenOutcome("something_new")) == OpenAnswerText(.other, code: "something_new"))
        // After an open that got no answer the recovery may have completed on the way.
        #expect(text(RecoveryOpenOutcome("no_recovery", afterUnanswered: true)).key == .noRecoveryUnanswered)
        // This phone's own unlock while it finishes an ok recovery.
        #expect(text(RecoveryOpenOutcome("bad_pin", opened: true)).key == .finishBadPin)
        #expect(text(RecoveryOpenOutcome("backoff", opened: true)).key == .finishBackoff)
        #expect(text(RecoveryOpenOutcome("device_secret", opened: true)).key == .finishFailed)
        // A right entry that could not be completed, then answered wait.
        #expect(text(RecoveryOpenOutcome("wait", used: 3, retryAt: at), true) == OpenAnswerText(.rightIncomplete, number: 7, withRetryAt: true))
        // Without a date it is an ordinary wait answer.
        #expect(text(RecoveryOpenOutcome("wait", used: 3), true).key == .waitNoDate)
    }

    /// (0.34.0) Whether this request used an attempt comes only from attempt_used (ANDROID-PLAN 0.1.41's table).
    @Test func theAttemptTextsFollowAttemptUsed() {
        // quiet: nothing used (with the date), one used, unknown (neutral).
        #expect(text(RecoveryOpenOutcome("quiet", used: 3, retryAt: at, attemptUsed: false)) == OpenAnswerText(.quietNothing, withRetryAt: true))
        #expect(text(RecoveryOpenOutcome("quiet", used: 4, retryAt: at, attemptUsed: true)) == OpenAnswerText(.quietUsed, number: 6))
        #expect(text(RecoveryOpenOutcome("quiet", used: 4, retryAt: at)).key == .quiet)
        // wait: nothing used; one used is shown as attempt_lost.
        #expect(text(RecoveryOpenOutcome("wait", used: 2, retryAt: at, attemptUsed: false)) == OpenAnswerText(.waitNothing, withRetryAt: true))
        #expect(text(RecoveryOpenOutcome("wait", used: 3, retryAt: at, attemptUsed: true)) == OpenAnswerText(.attemptLost, number: 7))
        // retry after the spend.
        #expect(text(RecoveryOpenOutcome("retry", used: 5, attemptUsed: true)) == OpenAnswerText(.retryUsed, number: 5))
        #expect(text(RecoveryOpenOutcome("retry", used: 5, attemptUsed: false)).key == .retry)
        // stored_mismatch and vault_missing: before or after the spend, by attempt_used, not by attempts.
        #expect(text(RecoveryOpenOutcome("stored_mismatch", used: 3, attemptUsed: false)).key == .storedMismatch)
        #expect(text(RecoveryOpenOutcome("vault_missing", used: 4, attemptUsed: true)).key == .storedMismatchRight)
        // The resume of a lost ok that found no recovery here.
        #expect(text(RecoveryOpenOutcome("no_bundle", opened: true)).key == .lostNotHere)
    }

    @Test func whichAnswersEndTheRecovery() {
        for code in ["wrong", "busy", "manifest", "wrong_release"] { #expect(openCanTryAgain(code), "\(code)") }
        for code in ["exhausted", "closed", "not_armed", "stored_mismatch", "no_recovery", "expired", "attestation", "bad_request"] {
            #expect(!openCanTryAgain(code), "\(code)")
        }
        #expect(openNeedsNewRecovery("no_recovery") && openNeedsNewRecovery("expired") && !openNeedsNewRecovery("exhausted"))
    }

    @Test func warningsBeforeTheSecondAttemptAndFromThreeLeft() {
        #expect(RecoveryOpenState(used: nil).warning == nil && RecoveryOpenState(used: 0).warning == nil)
        #expect(RecoveryOpenState(used: 1).warning == .second)
        #expect(RecoveryOpenState(used: 6).warning == nil)
        #expect(RecoveryOpenState(used: 7).warning == .fewLeft)
    }

    @Test func theCountdownReads() {
        #expect(openCountdown(until: Date(timeIntervalSince1970: 90_061), now: Date(timeIntervalSince1970: 0)) == "1 d 01:01:01")
        #expect(openCountdown(until: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 5)) == "00:00:00")
        #expect(recoveryWaitUnitScaledSeconds == 600)
    }

    @Test func everyAnswerKeyIsAnAndroidStringName() {
        for key in OpenAnswerKey.allCases { #expect(key.rawValue.hasPrefix("onboarding_open_")) }
    }
}

// swiftlint:enable line_length
