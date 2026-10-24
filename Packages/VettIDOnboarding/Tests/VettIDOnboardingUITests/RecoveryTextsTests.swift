#if os(iOS)
import Foundation
import Testing
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI

// The expected texts stay on one line each.
// swiftlint:disable line_length

/// The recovery's outcomes as the screens say them: a state's refusal, a typed entry's problem, an answer of the open and its
/// warning (vettid-android `RecoveryOpenTextTest`, `RecoveryWaitTextTest`).
@Suite struct RecoveryTextsTests {
    @Test func theRefusalsOfACode() {
        var s = RecoverState()
        s.wrongCodes = 2
        s.otherApi = "https://account.staging.vettid.org"
        #expect(RecoveryTexts.refusal(.badCode, s, timeScale: 1) == "That code is not right. After 5 wrong codes the recovery is cancelled. Wrong codes from this phone: 2 of 5.")
        #expect(RecoveryTexts.refusal(.otherEnvironment, s, timeScale: 1) == "That code is from another VettID environment (https://account.staging.vettid.org), not the one this app uses.")
        #expect(RecoveryTexts.refusal(.notAvailable, s, timeScale: 1) == "This recovery is not available: its code may not be ready yet (24 hours after the request), or the recovery was cancelled, used or has expired. Check the account site.")
        #expect(RecoveryTexts.refusal(.notAvailable, s, timeScale: 24).contains("(1 hour after the request)"))
        #expect(RecoveryTexts.refusal(.notOffered, s, timeScale: 1) == "This vault's release does not offer recovery.")
        let all = CodeRefusal.allCases.map { RecoveryTexts.refusal($0, s, timeScale: 1) }
        #expect(Set(all).count == CodeRefusal.allCases.count && all.allSatisfy { !$0.isEmpty })
    }

    @Test func theTypedProblemsNameTheGroupOfARefusedCharacter() {
        var s = RecoverState()
        s.accountHost = "account.vettid.org"
        #expect(RecoveryTexts.typedProblem(s) == nil)
        s.typedProblem = .letterU
        s.typedGroup = 3
        #expect(RecoveryTexts.typedProblem(s) == "The code has no letter U. Check whether it is a V. Look at group 3.")
        s.typedProblem = .otherCharacter
        #expect(RecoveryTexts.typedProblem(s) == "The code uses only digits and letters. Look at group 3.")
        s.typedGroup = 0
        #expect(RecoveryTexts.typedProblem(s) == "The code uses only digits and letters.")
        s.typedProblem = .badCheck
        #expect(RecoveryTexts.typedProblem(s) == "That code doesn't match. Compare it with the account site group by group, and check that the site is account.vettid.org.")
        s.typedProblem = .shortCode
        #expect(RecoveryTexts.typedProblem(s) == "That is the short code of an older page. Reload the recovery page on the account site: it shows 12 groups.")
        s.typedProblem = .incomplete
        #expect(RecoveryTexts.typedProblem(s) == "The code has 12 groups of four characters. Type them all.")
    }

    @Test func theAnswersWithADate() {
        let at = Date(timeIntervalSince1970: 1_792_497_600)
        let when = RecoveryTexts.retryAt(at, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        #expect(when.contains("Oct") && when.contains("20") && when.contains("2026"))
        #expect(RecoveryTexts.retryAt(nil) == "")
        let wrong = openAnswerText(RecoveryOpenOutcome("wrong", used: 2, retryAt: at), rightButIncomplete: false)
        #expect(RecoveryTexts.openAnswer(wrong, retryAt: when) == "PIN or password is wrong. The vault does not tell us which. 8 of 10 attempts left. Your next attempt is possible on \(when).")
        let ok = openAnswerText(RecoveryOpenOutcome("ok", used: 3), rightButIncomplete: false)
        #expect(RecoveryTexts.openAnswer(ok, retryAt: "") == "The vault is recovered. You used 3 of your 10 attempts. They do not come back. Change your PIN or your password now to get 10 new ones.")
        let incomplete = openAnswerText(RecoveryOpenOutcome("wait", used: 3, retryAt: at), rightButIncomplete: true)
        #expect(RecoveryTexts.openAnswer(incomplete, retryAt: when) == "The last attempt was right but could not be completed. 7 of 10 left. You can try again on \(when).")
        let other = openAnswerText(RecoveryOpenOutcome("something_new"), rightButIncomplete: false)
        #expect(RecoveryTexts.openAnswer(other, retryAt: "") == "The vault answered something_new.")
    }

    @Test func everyKeyOfTheTableHasAText() {
        for key in OpenAnswerKey.allCases {
            let text = RecoveryTexts.openAnswer(OpenAnswerText(key, number: 4, code: "c"), retryAt: "D")
            #expect(!text.isEmpty, "\(key)")
        }
    }

    /// (Owner decision 2026-10-19; STAGING-TIME-SCALE §5.2) The second attempt's warning: in real time the text as approved,
    /// word for word; on a vault with a time scale the wait as a staging vault runs it, with the staging note.
    @Test func theSecondAttemptsWarning() {
        #expect(RecoveryTexts.openWarning(.second, used: 1, timeScale: 1) == "This is your second attempt. If it is wrong too, you can try again in 24 hours, and the wait gets longer after every further wrong attempt.")
        let staging = RecoveryTexts.openWarning(.second, used: 1, timeScale: 24)
        #expect(staging.contains("If it is wrong too, you can try again in 10 minutes, and the wait gets longer"))
        #expect(staging.hasSuffix("Staging: 1 day = 1 hour") && !staging.contains("24 hours"))
        // A vault at a scale the note does not describe: the wait as it runs there, without the note.
        #expect(!RecoveryTexts.openWarning(.second, used: 1, timeScale: 5).contains("Staging:"))
        #expect(RecoveryTexts.openWarning(.fewLeft, used: 7, timeScale: 1) == "You have 3 attempts left. If they are all wrong, this vault cannot be recovered and you would have to start over with an empty one. Check both entries before you go on.")
    }
}

// swiftlint:enable line_length
#endif
