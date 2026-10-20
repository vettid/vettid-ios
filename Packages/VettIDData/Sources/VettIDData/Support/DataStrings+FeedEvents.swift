import Foundation

// Release R's event titles (IOS-PLAN §4.1, ANDROID-PLAN §4 "Event titles", approved by the owner): vettid-android
// `core/data` `strings.xml`, word for word, under its string names.
extension DataStrings {
    static var feedPinChanged: String { String(localized: "data_feed_pin_changed", defaultValue: "Your PIN was changed", bundle: .module) }

    static var feedSecretRenewed: String {
        String(
            localized: "data_feed_secret_renewed",
            defaultValue: "Your phone now uses a new secret for your vault",
            bundle: .module
        )
    }

    static var feedCredentialRecovered: String {
        String(
            localized: "data_feed_credential_recovered",
            defaultValue: "Your credential was restored from its backup",
            bundle: .module
        )
    }

    static var feedRecoveryDevicePaired: String {
        String(
            localized: "data_feed_recovery_device_paired",
            defaultValue: "Your new phone was connected to your vault",
            bundle: .module
        )
    }

    static var feedRecoveryCompleted: String {
        String(
            localized: "data_feed_recovery_completed",
            defaultValue: "Recovery finished: your vault is on your new phone",
            bundle: .module
        )
    }

    static func feedRecoveryAttemptSomeone(_ a: Int, _ b: Int) -> String {
        String(
            localized: "data_feed_recovery_attempt_someone",
            defaultValue: "Someone tried to recover your vault (attempt \(a) of \(b))",
            bundle: .module
        )
    }

    static var feedRecoveryAttemptSomeoneAny: String {
        String(
            localized: "data_feed_recovery_attempt_someone_any",
            defaultValue: "Someone tried to recover your vault",
            bundle: .module
        )
    }

    static func feedRecoveryAttemptRecovered(_ a: Int, _ b: Int) -> String {
        String(
            localized: "data_feed_recovery_attempt_recovered",
            defaultValue: "Your vault was recovered (attempt \(a) of \(b))",
            bundle: .module
        )
    }

    static func feedRecoveryAttempt(_ a: Int, _ b: Int) -> String {
        String(
            localized: "data_feed_recovery_attempt",
            defaultValue: "Recovery attempt \(a) of \(b)",
            bundle: .module
        )
    }

    static var feedRecoveryAttemptAny: String {
        String(
            localized: "data_feed_recovery_attempt_any",
            defaultValue: "Recovery attempt",
            bundle: .module
        )
    }

    static var feedChangeRequiredPassword: String {
        String(
            localized: "data_feed_change_required_password",
            defaultValue: "Choose a stronger password to keep recovery on",
            bundle: .module
        )
    }

    static var feedChangeRequiredPasswordBody: String {
        String(
            localized: "data_feed_change_required_password_body",
            defaultValue: "Your password is too weak for recovery. Recovery stays off until you change it.",
            bundle: .module
        )
    }

    static var feedChangeRequired: String {
        String(
            localized: "data_feed_change_required",
            defaultValue: "Change your PIN or password to turn recovery back on",
            bundle: .module
        )
    }

    static var feedChangeRequiredBody: String {
        String(
            localized: "data_feed_change_required_body",
            defaultValue: "Recovery attempts were used. A change gives you 10 new attempts.",
            bundle: .module
        )
    }

    static var feedCounterUnavailable: String {
        String(
            localized: "data_feed_counter_unavailable",
            defaultValue: "Your vault cannot check its recovery attempts",
            bundle: .module
        )
    }

    static var feedRecoveryRollback: String {
        String(
            localized: "data_feed_recovery_rollback",
            defaultValue: "Your vault was given an older recovery record",
            bundle: .module
        )
    }

    static var feedRecoveryRollbackBody: String {
        String(
            localized: "data_feed_recovery_rollback_body",
            defaultValue: """
                A host may have served an older copy of your vault's recovery record, one on which recovery attempts had already \
                been used. Your vault moved past it. If you did not try to recover your vault, change your PIN and your password \
                now, and contact VettID.
                """,
            bundle: .module
        )
    }

    static var feedRotationFailed: String {
        String(
            localized: "data_feed_rotation_failed",
            defaultValue: "Your vault could not update its keys",
            bundle: .module
        )
    }

    static var feedRotationFailedBody: String {
        String(
            localized: "data_feed_rotation_failed_body",
            defaultValue: "Your connections still know your old keys. VettID will offer the update again.",
            bundle: .module
        )
    }

    static func feedRotateConflict(_ value: String) -> String {
        String(
            localized: "data_feed_rotate_conflict",
            defaultValue: "\(value): verify again",
            bundle: .module
        )
    }

    static var feedRotateConflictBody: String {
        String(
            localized: "data_feed_rotate_conflict_body",
            defaultValue: """
                This connection's vault announced two different new keys. That can mean someone holds an old copy of their vault. \
                Nothing is sent or received until you check.
                """,
            bundle: .module
        )
    }

    static func feedLeashItemUsed(_ value: String) -> String {
        String(
            localized: "data_feed_leash_item_used",
            defaultValue: "An agent used \(value)",
            bundle: .module
        )
    }

    static var feedLeashItemUsedAny: String {
        String(
            localized: "data_feed_leash_item_used_any",
            defaultValue: "An agent used an item",
            bundle: .module
        )
    }

    static func feedUnknown(_ value: String) -> String {
        String(
            localized: "data_feed_unknown",
            defaultValue: "Activity: \(value)",
            bundle: .module
        )
    }
}
