#if os(iOS)
import Foundation
import Testing
@testable import VettIDOnboardingUI

// The expected texts stay on one line each.
// swiftlint:disable line_length

/// Every text of the recovery's outcomes is vettid-android's `strings.xml` word for word (arguments here: 7 and 3 for the
/// numbers, "S1" and "S2" for the words), and resolves in the built bundle to its own entry of the table.
@Suite struct RecoveryStringsTests {
    struct Row {
        let key: String
        let actual: String
        let expected: String

        init(_ key: String, _ actual: String, _ expected: String) {
            self.key = key
            self.actual = actual
            self.expected = expected
        }
    }

    static let table: [Row] = [
        Row("recover_scan_not_code", RecoveryStrings.recoverScanNotCode, "That is not a VettID recovery code."),
        Row("recover_scan_other_environment", RecoveryStrings.recoverScanOtherEnvironment("S1"), "That code is from another VettID environment (S1), not the one this app uses."),
        Row("recover_scan_no_api", RecoveryStrings.recoverScanNoApi, "That recovery code is from an older account site. Reload the recovery page on the account site and scan the new code."),
        Row("recover_not_available", RecoveryStrings.recoverNotAvailable("S1"), "This recovery is not available: its code may not be ready yet (S1 after the request), or the recovery was cancelled, used or has expired. Check the account site."),
        Row("recover_not_offered", RecoveryStrings.recoverNotOffered, "This vault's release does not offer recovery."),
        Row("recover_bad_code", RecoveryStrings.recoverBadCode(7), "That code is not right. After 5 wrong codes the recovery is cancelled. Wrong codes from this phone: 7 of 5."),
        Row("recover_voided", RecoveryStrings.recoverVoided, "That was the fifth wrong code, so the recovery was cancelled. Start a new recovery on the account site."),
        Row("recover_code_expired", RecoveryStrings.recoverCodeExpired, "This code has expired. Start a new recovery on the account site."),
        Row("recover_code_early_unknown", RecoveryStrings.recoverCodeEarlyUnknown, "This code is not valid yet. Try again later."),
        Row("recover_code_gone", RecoveryStrings.recoverCodeGone, "This recovery is no longer active: it was cancelled, already used, or voided after wrong codes. Start a new recovery on the account site."),
        Row("recover_code_attestation", RecoveryStrings.recoverCodeAttestation, "Your vault could not verify this phone (device attestation). The code is still valid; this phone may not be supported."),
        Row("recover_code_retry", RecoveryStrings.recoverCodeRetry, "Your vault could not answer just now. Try again."),
        Row("recover_type_letter_u", RecoveryStrings.recoverTypeLetterU, "The code has no letter U. Check whether it is a V."),
        Row("recover_type_other_character", RecoveryStrings.recoverTypeOtherCharacter, "The code uses only digits and letters."),
        Row("recover_type_in_group", RecoveryStrings.recoverTypeInGroup("S1", 7), "S1 Look at group 7."),
        Row("recover_type_bad_check", RecoveryStrings.recoverTypeBadCheck("S1"), "That code doesn't match. Compare it with the account site group by group, and check that the site is S1."),
        Row("recover_type_short_code", RecoveryStrings.recoverTypeShortCode, "That is the short code of an older page. Reload the recovery page on the account site: it shows 12 groups."),
        Row("recover_type_incomplete", RecoveryStrings.recoverTypeIncomplete, "The code has 12 groups of four characters. Type them all."),
        Row("recover_could_not_tell", RecoveryStrings.recoverCouldNotTell, "We could not tell whether your last attempt recovered the vault. You can start a new recovery on the account site and use this phone for it; nothing on this phone is deleted."),
        Row("recover_could_not_recover", RecoveryStrings.recoverCouldNotRecover, "This phone could not recover your vault. Nothing on this phone is deleted. Contact VettID at support@vettid.org."),
        Row("onboarding_open_contact_support", RecoveryStrings.onboardingOpenContactSupport("support@vettid.org"), "Email support@vettid.org"),
        Row("recover_other_vault", RecoveryStrings.recoverOtherVault, "This recovery code is for a different vault than the one this phone is recovering. Nothing was registered, and nothing on this phone is deleted."),
        Row("recover_undecided_new_code", RecoveryStrings.recoverUndecidedNewCode, "Use a new recovery code"),
        Row("onboarding_open_took_phone", RecoveryStrings.onboardingOpenTookPhone, "Your vault took this phone, but it cannot be unlocked right now. Contact VettID."),
        Row("recover_rate_limited_wait", RecoveryStrings.recoverRateLimitedWait("S1"), "Too many attempts. Try again in S1."),
        Row("onboarding_open_answer_title", RecoveryOpenStrings.onboardingOpenAnswerTitle, "Recovery"),
        Row("onboarding_open_ok", RecoveryOpenStrings.onboardingOpenOk(7), "The vault is recovered. You used 7 of your 10 attempts. They do not come back. Change your PIN or your password now to get 10 new ones."),
        Row("onboarding_open_ok_plain", RecoveryOpenStrings.onboardingOpenOkPlain, "The vault is recovered. The attempts you used do not come back. Change your PIN or your password now to get 10 new ones."),
        Row("onboarding_open_wrong", RecoveryOpenStrings.onboardingOpenWrong(7), "PIN or password is wrong. The vault does not tell us which. 7 of 10 attempts left."),
        Row("onboarding_open_wrong_wait", RecoveryOpenStrings.onboardingOpenWrongWait(7, "S1"), "PIN or password is wrong. The vault does not tell us which. 7 of 10 attempts left. Your next attempt is possible on S1."),
        Row("onboarding_open_wrong_again", RecoveryOpenStrings.onboardingOpenWrongAgain, "That is the same PIN and password as your last attempt, and they are still wrong. This was not counted. Change one of them before you try again."),
        Row("onboarding_open_attempt_lost", RecoveryOpenStrings.onboardingOpenAttemptLost(7), "Something went wrong on the way and one attempt was used without being tested. 7 of 10 left. Your PIN and password were not judged wrong. A slow or interrupted service can cause this."),
        Row("onboarding_open_quiet", RecoveryOpenStrings.onboardingOpenQuiet("S1"), "This vault's app was used with its PIN and password recently. A vault can be recovered only some time after that: from S1 at the earliest."),
        Row("onboarding_open_quiet_nodate", RecoveryOpenStrings.onboardingOpenQuietNodate, "This vault cannot be recovered yet: it has no record of when its app was last used with its PIN and password. Try again later."),
        Row("onboarding_open_quiet_nothing", RecoveryOpenStrings.onboardingOpenQuietNothing("S1"), "This vault's app was used with its PIN and password recently. A vault can be recovered only some time after that: from S1 at the earliest. Nothing was used."),
        Row("onboarding_open_quiet_used", RecoveryOpenStrings.onboardingOpenQuietUsed(7), "The vault's app was used with its PIN and password while this attempt was on its way, or the service recorded that it was. One attempt was used without being tested. 7 left."),
        Row("onboarding_open_wait", RecoveryOpenStrings.onboardingOpenWait("S1"), "You can try again on S1."),
        Row("onboarding_open_wait_nodate", RecoveryOpenStrings.onboardingOpenWaitNodate, "You cannot try again yet. Try again later."),
        Row("onboarding_open_wait_nothing", RecoveryOpenStrings.onboardingOpenWaitNothing("S1"), "You can try again on S1. Nothing was used."),
        Row("onboarding_open_retry", RecoveryOpenStrings.onboardingOpenRetry, "The service was too slow just now. Nothing was used. Try again."),
        Row("onboarding_open_retry_used", RecoveryOpenStrings.onboardingOpenRetryUsed(7), "Something went wrong on the way. One attempt was used, and your PIN and password were not judged wrong. 7 of 10 left. Try again."),
        Row("onboarding_open_busy", RecoveryOpenStrings.onboardingOpenBusy, "The service is busy right now. Nothing was used. Try again in a minute."),
        Row("onboarding_open_stored_mismatch", RecoveryOpenStrings.onboardingOpenStoredMismatch, "The vault's stored data could not be opened. Nothing was used. Contact VettID."),
        Row("onboarding_open_stored_mismatch_right", RecoveryOpenStrings.onboardingOpenStoredMismatchRight, "Your entry was right, but the vault's stored data could not be opened. Contact VettID."),
        Row("onboarding_open_exhausted", RecoveryOpenStrings.onboardingOpenExhausted, "All 10 attempts for this vault have been used. It cannot be recovered. You can delete it on the account site and start over."),
        Row("onboarding_open_closed", RecoveryOpenStrings.onboardingOpenClosed, "The PIN or the password of this vault was changed, or its recovery was turned off, after this recovery began. This recovery cannot continue."),
        Row("onboarding_open_not_armed", RecoveryOpenStrings.onboardingOpenNotArmed, "Recovery was not set up for this vault."),
        Row("onboarding_open_counter_unavailable", RecoveryOpenStrings.onboardingOpenCounterUnavailable, "We cannot check the attempt record now. Nothing was used. Try again later."),
        Row("onboarding_open_right_incomplete", RecoveryOpenStrings.onboardingOpenRightIncomplete(7, "S1"), "The last attempt was right but could not be completed. 7 of 10 left. You can try again on S1."),
        Row("onboarding_open_other", RecoveryOpenStrings.onboardingOpenOther("S1"), "The vault answered S1."),
        Row("onboarding_open_no_recovery", RecoveryOpenStrings.onboardingOpenNoRecovery, "This recovery has ended: it was cancelled, it expired or it was completed. Nothing was used. To go on, start a new recovery on the account site."),
        Row("onboarding_open_no_recovery_unanswered", RecoveryOpenStrings.onboardingOpenNoRecoveryUnanswered, "This recovery has ended. Your last attempt got no answer, and it may have recovered your vault on the way: your PIN finishes it on this phone. Do this before you start a new recovery."),
        Row("onboarding_open_expired", RecoveryOpenStrings.onboardingOpenExpired, "This recovery has expired. Nothing was used. To go on, start a new recovery on the account site."),
        Row("onboarding_open_attestation", RecoveryOpenStrings.onboardingOpenAttestation, "The vault did not accept this phone's app. Nothing was used. Update VettID to continue."),
        Row("onboarding_open_manifest", RecoveryOpenStrings.onboardingOpenManifest, "The vault's list of releases could not be checked. Nothing was used. Try again later."),
        Row("onboarding_open_wrong_release", RecoveryOpenStrings.onboardingOpenWrongRelease, "The vault is being updated right now. Nothing was used. Try again in a few minutes."),
        Row("onboarding_open_bad_request", RecoveryOpenStrings.onboardingOpenBadRequest, "The vault could not read this phone's request. Nothing was used. Update VettID to continue."),
        Row("onboarding_open_finish_bad_pin", RecoveryOpenStrings.onboardingOpenFinishBadPin, "That PIN is wrong. This did not use any of your recovery attempts."),
        Row("onboarding_open_finish_backoff", RecoveryOpenStrings.onboardingOpenFinishBackoff, "Too many wrong PINs. Wait a little, then try again. This did not use any of your recovery attempts."),
        Row("onboarding_open_lost_not_here", RecoveryOpenStrings.onboardingOpenLostNotHere, "Your vault was not recovered onto this phone by the last attempt. Go back and try again."),
        Row("onboarding_open_finish_failed", RecoveryOpenStrings.onboardingOpenFinishFailed, "Your vault could not be opened from this phone just now. Try again. This did not use any of your recovery attempts."),
        Row("onboarding_open_unreadable", RecoveryOpenStrings.onboardingOpenUnreadable, "We could not read the vault's answer. This attempt may have been used. If it recovered your vault, your PIN finishes it."),
        Row("onboarding_open_attempts_left", RecoveryOpenStrings.onboardingOpenAttemptsLeft(7), "Attempts left: 7 of 10."),
        Row("onboarding_open_countdown", RecoveryOpenStrings.onboardingOpenCountdown("S1"), "Next attempt possible in S1"),
        Row("onboarding_open_second", RecoveryOpenStrings.onboardingOpenSecond, "This is your second attempt. If it is wrong too, you can try again in 24 hours, and the wait gets longer after every further wrong attempt."),
        Row("onboarding_open_second_scaled", RecoveryOpenStrings.onboardingOpenSecondScaled("S1"), "This is your second attempt. If it is wrong too, you can try again in S1, and the wait gets longer after every further wrong attempt."),
        Row("onboarding_open_few_left", RecoveryOpenStrings.onboardingOpenFewLeft(7), "You have 7 attempts left. If they are all wrong, this vault cannot be recovered and you would have to start over with an empty one. Check both entries before you go on."),
    ]

    @Test func theTextsAreAndroids() {
        #expect(Self.table.count == 67)
        for row in Self.table { #expect(row.actual == row.expected, "\(row.key)") }
    }

    /// Every key of the recovery's outcomes is in the package's table, with the text the code has.
    @Test func everyKeyIsInTheTable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDOnboardingUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(doc["strings"] as? [String: Any])
        for row in Self.table {
            let entry = try #require(strings[row.key] as? [String: Any], "\(row.key)")
            let en = (((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"]
            let value = try #require(en as? String, "\(row.key)")
            #expect(!value.isEmpty, "\(row.key)")
            let resolved = Bundle.module.localizedString(forKey: row.key, value: "\u{0}missing", table: nil)
            #expect(resolved == value, "\(row.key)")
        }
    }
}

// swiftlint:enable line_length
#endif
