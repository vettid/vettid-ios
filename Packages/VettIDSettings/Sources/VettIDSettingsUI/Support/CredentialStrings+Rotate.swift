import Foundation

/// The rotation's, the clone alarm's and a new credential's texts (vettid-android `feature/credential` `strings.xml` and
/// `strings_new_credential.xml`, word for word).
extension CredentialStrings {
    // MARK: - The rotation

    static var rotate: String {
        String(localized: "credential_rotate", defaultValue: "Rotate the credential key", bundle: .module)
    }

    static var rotateSupporting: String {
        String(localized: "credential_rotate_supporting", defaultValue: "Recommended at least once a year", bundle: .module)
    }

    static var rotateTitle: String {
        String(localized: "credential_rotate_title", defaultValue: "Rotate your credential key", bundle: .module)
    }

    static var rotateBody: String {
        String(
            localized: "credential_rotate_body",
            defaultValue: """
                Your vault makes a new credential key, re-keys every critical item and rotates its own identity keys. \
                Connections that know your key receive a signed rotation statement. Every older copy of your credential \
                stops working.
                """,
            bundle: .module
        )
    }

    static var rotateSubmit: String {
        String(localized: "credential_rotate_submit", defaultValue: "Rotate now", bundle: .module)
    }

    static var rotateDone: String {
        String(localized: "credential_rotate_done", defaultValue: "Your credential key was rotated.", bundle: .module)
    }

    // MARK: - The clone alarm

    static var alarmReview: String {
        String(localized: "credential_alarm_review", defaultValue: "Review", bundle: .module)
    }

    static var alarmTitle: String {
        String(localized: "credential_alarm_title", defaultValue: "Was that you?", bundle: .module)
    }

    /// [at]: when the copy was presented; [presenter]: who presented it (``alarmPresenterHolder`` and the others).
    static func alarmBody(_ at: String, _ presenter: String) -> String {
        String(
            localized: "credential_alarm_body",
            defaultValue: """
                At \(at), \(presenter) presented a copy of your Protean Credential. Your vault refused it and froze \
                credential use. Messaging, connections and your other items keep working.
                """,
            bundle: .module
        )
    }

    static var alarmPresenterHolder: String {
        String(localized: "credential_alarm_presenter_holder", defaultValue: "this phone's session", bundle: .module)
    }

    static var alarmPresenterOther: String {
        String(localized: "credential_alarm_presenter_other", defaultValue: "another device", bundle: .module)
    }

    static var alarmPresenterUnknown: String {
        String(localized: "credential_alarm_presenter_unknown", defaultValue: "a device", bundle: .module)
    }

    static var alarmMine: String {
        String(localized: "credential_alarm_mine", defaultValue: "That was me", bundle: .module)
    }

    static var alarmMineBody: String {
        String(
            localized: "credential_alarm_mine_body",
            defaultValue: """
                For example, you restored this phone from a backup. A rotation still follows, so that no second copy stays \
                alive.
                """,
            bundle: .module
        )
    }

    static var alarmNotMine: String {
        String(localized: "credential_alarm_not_mine", defaultValue: "That was not me", bundle: .module)
    }

    static var alarmConfirmMineTitle: String {
        String(localized: "credential_alarm_confirm_mine_title", defaultValue: "Confirm: that was you?", bundle: .module)
    }

    static var alarmConfirmNotMineTitle: String {
        String(localized: "credential_alarm_confirm_not_mine_title", defaultValue: "Confirm: that was not you?", bundle: .module)
    }

    static var alarmConfirmBody: String {
        String(
            localized: "credential_alarm_confirm_body",
            defaultValue: "Either way, you rotate your credential next. Every other copy stops working.",
            bundle: .module
        )
    }

    static var alarmConfirm: String {
        String(localized: "credential_alarm_confirm", defaultValue: "Confirm", bundle: .module)
    }

    static var alarmRotateTitle: String {
        String(localized: "credential_alarm_rotate_title", defaultValue: "Rotate your credential", bundle: .module)
    }

    static var alarmRotateBody: String {
        String(
            localized: "credential_alarm_rotate_body",
            defaultValue: """
                Enter your credential password to make a new credential key. Every other copy, including the one \
                presented, stops working.
                """,
            bundle: .module
        )
    }

    static var alarmNotMineAdviceTitle: String {
        String(localized: "credential_alarm_not_mine_advice_title", defaultValue: "Someone may have your credential", bundle: .module)
    }

    static var alarmNotMineAdvice: String {
        String(
            localized: "credential_alarm_not_mine_advice",
            defaultValue: """
                After the rotation, change your credential password and your vault PIN. If this phone is lost or \
                compromised, start a recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var alarmResolved: String {
        String(localized: "credential_alarm_resolved", defaultValue: "The alert is resolved. Your credential works again.", bundle: .module)
    }

    // MARK: - A new credential

    static var newTitle: String {
        String(localized: "credential_new_title", defaultValue: "New credential", bundle: .module)
    }

    static var newSupporting: String {
        String(
            localized: "credential_new_supporting", defaultValue: "Replaces your credential; every critical item is destroyed",
            bundle: .module
        )
    }

    static var newBody: String {
        String(
            localized: "credential_new_body",
            defaultValue: """
                Your vault PIN and your current credential password confirm it is you; the new password protects the new \
                credential.
                """,
            bundle: .module
        )
    }

    static var newWarningTitle: String {
        String(localized: "credential_new_warning_title", defaultValue: "Every critical item is destroyed", bundle: .module)
    }

    static var newWarning: String {
        String(
            localized: "credential_new_warning",
            defaultValue: """
                A new credential replaces the current one. Every critical item in it is destroyed for good, on every \
                device; nobody, VettID included, can bring them back. Your other items, connections and messages stay.
                """,
            bundle: .module
        )
    }

    static var newPin: String {
        String(localized: "credential_new_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    static var newAck: String {
        String(localized: "credential_new_ack", defaultValue: "I understand that every critical item is destroyed.", bundle: .module)
    }

    static var newSubmit: String {
        String(localized: "credential_new_submit", defaultValue: "Replace credential", bundle: .module)
    }

    static var newConfirmTitle: String {
        String(localized: "credential_new_confirm_title", defaultValue: "Replace your credential?", bundle: .module)
    }

    static var newDone: String {
        String(localized: "credential_new_done", defaultValue: "New credential ready", bundle: .module)
    }

    static var newDoneBody: String {
        String(
            localized: "credential_new_done_body",
            defaultValue: "Use the new password from now on. Your daily check starts again from now.",
            bundle: .module
        )
    }

    // ANDROID-PLAN 0.1.51 "A lost answer to New credential" (VAULT-MESSAGING 0.48.0 §11.14.9), drafts shared with the
    // Android app; the keys are chosen (not in the spec).

    static var newChecking: String {
        String(
            localized: "credential_new_checking",
            defaultValue: """
                Your vault hasn't answered yet, so VettID is checking whether your new credential was made. Keep your new \
                password at hand.
                """,
            bundle: .module
        )
    }

    static var newUnreachable: String {
        String(
            localized: "credential_new_unreachable",
            defaultValue: """
                VettID can't reach your vault right now, so it doesn't know yet whether your new credential was made. It \
                will check as soon as it can. Keep both your old and your new password at hand.
                """,
            bundle: .module
        )
    }

    static var newEnded: String {
        String(
            localized: "credential_new_ended",
            defaultValue: """
                VettID couldn't confirm whether your new credential was made, because something else changed in your vault \
                at the same time. Either your previous or your new password may be the current one.
                """,
            bundle: .module
        )
    }

    static var newApplied: String {
        String(
            localized: "credential_new_applied",
            defaultValue: """
                Your new credential was made. Use your new password from now on. Your critical items were deleted with the \
                old credential.
                """,
            bundle: .module
        )
    }

    static var newNotMade: String {
        String(
            localized: "credential_new_not_made",
            defaultValue: "Your new credential wasn't made. Your credential, its password and your critical items are unchanged.",
            bundle: .module
        )
    }
}
