import Foundation

/// The texts of the recovery open's answers (vettid-android `feature/onboarding` `strings.xml`, word for word; ANDROID-PLAN
/// 0.1.41's table), its warnings and its countdown. The screens' own labels come with I3.4b.
enum RecoveryOpenStrings {
    static var onboardingOpenAnswerTitle: String {
        String(localized: "onboarding_open_answer_title", defaultValue: "Recovery", bundle: .module)
    }

    static func onboardingOpenOk(_ used: Int) -> String {
        String(
            localized: "onboarding_open_ok",
            defaultValue: """
                The vault is recovered. You used \(used) of your 10 attempts. They do not come back. Change your PIN or your\
                 password now to get 10 new ones.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenOkPlain: String {
        String(
            localized: "onboarding_open_ok_plain",
            defaultValue: """
                The vault is recovered. The attempts you used do not come back. Change your PIN or your password now to get \
                10 new ones.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenWrong(_ left: Int) -> String {
        String(
            localized: "onboarding_open_wrong",
            defaultValue: """
                PIN or password is wrong. The vault does not tell us which. \(left) of 10 attempts left.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenWrongWait(_ left: Int, _ date: String) -> String {
        String(
            localized: "onboarding_open_wrong_wait",
            defaultValue: """
                PIN or password is wrong. The vault does not tell us which. \(left) of 10 attempts left. Your next attempt \
                is possible on \(date).
                """,
            bundle: .module
        )
    }

    static var onboardingOpenWrongAgain: String {
        String(
            localized: "onboarding_open_wrong_again",
            defaultValue: """
                That is the same PIN and password as your last attempt, and they are still wrong. This was not counted. \
                Change one of them before you try again.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenAttemptLost(_ left: Int) -> String {
        String(
            localized: "onboarding_open_attempt_lost",
            defaultValue: """
                Something went wrong on the way and one attempt was used without being tested. \(left) of 10 left. Your PIN \
                and password were not judged wrong. A slow or interrupted service can cause this.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenQuiet(_ date: String) -> String {
        String(
            localized: "onboarding_open_quiet",
            defaultValue: """
                This vault's app was used with its PIN and password recently. A vault can be recovered only some time after \
                that: from \(date) at the earliest.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenQuietNodate: String {
        String(
            localized: "onboarding_open_quiet_nodate",
            defaultValue: """
                This vault cannot be recovered yet: it has no record of when its app was last used with its PIN and \
                password. Try again later.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenQuietNothing(_ date: String) -> String {
        String(
            localized: "onboarding_open_quiet_nothing",
            defaultValue: """
                This vault's app was used with its PIN and password recently. A vault can be recovered only some time after \
                that: from \(date) at the earliest. Nothing was used.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenQuietUsed(_ left: Int) -> String {
        String(
            localized: "onboarding_open_quiet_used",
            defaultValue: """
                The vault's app was used with its PIN and password while this attempt was on its way, or the service \
                recorded that it was. One attempt was used without being tested. \(left) left.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenWait(_ date: String) -> String {
        String(localized: "onboarding_open_wait", defaultValue: "You can try again on \(date).", bundle: .module)
    }

    static var onboardingOpenWaitNodate: String {
        String(localized: "onboarding_open_wait_nodate", defaultValue: "You cannot try again yet. Try again later.", bundle: .module)
    }

    static func onboardingOpenWaitNothing(_ date: String) -> String {
        String(localized: "onboarding_open_wait_nothing", defaultValue: "You can try again on \(date). Nothing was used.", bundle: .module)
    }

    static var onboardingOpenRetry: String {
        String(
            localized: "onboarding_open_retry",
            defaultValue: """
                The service was too slow just now. Nothing was used. Try again.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenRetryUsed(_ left: Int) -> String {
        String(
            localized: "onboarding_open_retry_used",
            defaultValue: """
                Something went wrong on the way. One attempt was used, and your PIN and password were not judged wrong. \
                \(left) of 10 left. Try again.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenBusy: String {
        String(
            localized: "onboarding_open_busy",
            defaultValue: """
                The service is busy right now. Nothing was used. Try again in a minute.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenStoredMismatch: String {
        String(
            localized: "onboarding_open_stored_mismatch",
            defaultValue: """
                The vault's stored data could not be opened. Nothing was used. Contact VettID.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenStoredMismatchRight: String {
        String(
            localized: "onboarding_open_stored_mismatch_right",
            defaultValue: """
                Your entry was right, but the vault's stored data could not be opened. Contact VettID.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenExhausted: String {
        String(
            localized: "onboarding_open_exhausted",
            defaultValue: """
                All 10 attempts for this vault have been used. It cannot be recovered. You can delete it on the account site\
                 and start over.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenClosed: String {
        String(
            localized: "onboarding_open_closed",
            defaultValue: """
                The PIN or the password of this vault was changed, or its recovery was turned off, after this recovery \
                began. This recovery cannot continue.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenNotArmed: String {
        String(localized: "onboarding_open_not_armed", defaultValue: "Recovery was not set up for this vault.", bundle: .module)
    }

    static var onboardingOpenCounterUnavailable: String {
        String(
            localized: "onboarding_open_counter_unavailable",
            defaultValue: """
                We cannot check the attempt record now. Nothing was used. Try again later.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenRightIncomplete(_ left: Int, _ date: String) -> String {
        String(
            localized: "onboarding_open_right_incomplete",
            defaultValue: """
                The last attempt was right but could not be completed. \(left) of 10 left. You can try again on \(date).
                """,
            bundle: .module
        )
    }

    static func onboardingOpenOther(_ code: String) -> String {
        String(localized: "onboarding_open_other", defaultValue: "The vault answered \(code).", bundle: .module)
    }

    static var onboardingOpenNoRecovery: String {
        String(
            localized: "onboarding_open_no_recovery",
            defaultValue: """
                This recovery has ended: it was cancelled, it expired or it was completed. Nothing was used. To go on, start\
                 a new recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenNoRecoveryUnanswered: String {
        String(
            localized: "onboarding_open_no_recovery_unanswered",
            defaultValue: """
                This recovery has ended. Your last attempt got no answer, and it may have recovered your vault on the way: \
                your PIN finishes it on this phone. Do this before you start a new recovery.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenExpired: String {
        String(
            localized: "onboarding_open_expired",
            defaultValue: """
                This recovery has expired. Nothing was used. To go on, start a new recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenAttestation: String {
        String(
            localized: "onboarding_open_attestation",
            defaultValue: """
                The vault did not accept this phone's app. Nothing was used. Update VettID to continue.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenManifest: String {
        String(
            localized: "onboarding_open_manifest",
            defaultValue: """
                The vault's list of releases could not be checked. Nothing was used. Try again later.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenWrongRelease: String {
        String(
            localized: "onboarding_open_wrong_release",
            defaultValue: """
                The vault is being updated right now. Nothing was used. Try again in a few minutes.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenBadRequest: String {
        String(
            localized: "onboarding_open_bad_request",
            defaultValue: """
                The vault could not read this phone's request. Nothing was used. Update VettID to continue.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenFinishBadPin: String {
        String(
            localized: "onboarding_open_finish_bad_pin",
            defaultValue: """
                That PIN is wrong. This did not use any of your recovery attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenFinishBackoff: String {
        String(
            localized: "onboarding_open_finish_backoff",
            defaultValue: """
                Too many wrong PINs. Wait a little, then try again. This did not use any of your recovery attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenLostNotHere: String {
        String(
            localized: "onboarding_open_lost_not_here",
            defaultValue: """
                Your vault was not recovered onto this phone by the last attempt. Go back and try again.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenFinishFailed: String {
        String(
            localized: "onboarding_open_finish_failed",
            defaultValue: """
                Your vault could not be opened from this phone just now. Try again. This did not use any of your recovery \
                attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenUnreadable: String {
        String(
            localized: "onboarding_open_unreadable",
            defaultValue: """
                We could not read the vault's answer. This attempt may have been used. If it recovered your vault, your PIN \
                finishes it.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenAttemptsLeft(_ left: Int) -> String {
        String(localized: "onboarding_open_attempts_left", defaultValue: "Attempts left: \(left) of 10.", bundle: .module)
    }

    static func onboardingOpenCountdown(_ time: String) -> String {
        String(localized: "onboarding_open_countdown", defaultValue: "Next attempt possible in \(time)", bundle: .module)
    }

    static var onboardingOpenSecond: String {
        String(
            localized: "onboarding_open_second",
            defaultValue: """
                This is your second attempt. If it is wrong too, you can try again in 24 hours, and the wait gets longer \
                after every further wrong attempt.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenSecondScaled(_ wait: String) -> String {
        String(
            localized: "onboarding_open_second_scaled",
            defaultValue: """
                This is your second attempt. If it is wrong too, you can try again in \(wait), and the wait gets longer \
                after every further wrong attempt.
                """,
            bundle: .module
        )
    }

    static func onboardingOpenFewLeft(_ left: Int) -> String {
        String(
            localized: "onboarding_open_few_left",
            defaultValue: """
                You have \(left) attempts left. If they are all wrong, this vault cannot be recovered and you would have to \
                start over with an empty one. Check both entries before you go on.
                """,
            bundle: .module
        )
    }

}
