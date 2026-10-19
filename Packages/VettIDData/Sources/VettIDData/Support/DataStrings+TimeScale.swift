import Foundation

// The staging time scale's texts (STAGING-TIME-SCALE §4 item 4, §5.2; VAULT-MESSAGING 0.43.0 §11.10.9) and the durations
// the screens compute from seconds. vettid-android has no strings for them yet (ANDROID-PLAN §4 "Staging time scale"):
// the keys are chosen here; the English values are the specification's words.
extension DataStrings {
    /// §11.10.9: a production build and a descriptor whose `time_scale` is not 1.
    static var failureTimeScale: String {
        String(
            localized: "data_failure_time_scale",
            defaultValue: "This vault's software is not for this app. Contact VettID.",
            bundle: .module
        )
    }
    static var timeScaleStaging: String {
        String(localized: "data_time_scale_staging", defaultValue: "Staging: 1 day = 1 hour", bundle: .module)
    }
    static func timeScaleSetting(_ real: String, _ scaled: String) -> String {
        String(localized: "data_time_scale_setting", defaultValue: "\(real) (staging: \(scaled))", bundle: .module)
    }
    /// ANDROID-PLAN "Owner check and status" (release R), verbatim (vettid-android `settings_recovery_unknown_day`): the
    /// text in real time.
    static var recoveryUnknownDay: String {
        String(
            localized: "data_recovery_unknown_day",
            defaultValue: """
                For a day your vault has not been able to check its recovery attempts or record that you were here. If this \
                goes on for three days, your vault is no longer protected against a recovery started by someone else, and \
                until it ends you cannot change your PIN or password. This is a fault of the VettID service or an attack on \
                it. Contact VettID.
                """,
            bundle: .module
        )
    }
    /// The same on a scaled vault, both durations computed (STAGING-TIME-SCALE 0.1.1 S8, S7; ANDROID-PLAN 0.1.49 §4
    /// "Staging time scale"): [day] the clock's period, [quiet] the recovery quiet period. The key is chosen; not in the
    /// spec.
    static func recoveryUnknownDayScaled(_ day: String, _ quiet: String) -> String {
        String(
            localized: "data_recovery_unknown_day_scaled",
            defaultValue: """
                For \(day) your vault has not been able to check its recovery attempts or record that you were here. If \
                this goes on for \(quiet), your vault is no longer protected against a recovery started by someone else, \
                and until it ends you cannot change your PIN or password. This is a fault of the VettID service or an attack \
                on it. Contact VettID.
                """,
            bundle: .module
        )
    }
    /// ``failureDeviceSecret`` on a scaled vault: [from] and [to], a recovery's shortest and longest time (its code delay,
    /// S5, and its quiet period, S7) at the vault's time scale (the owner's decision of 2026-10-19). The key is chosen;
    /// not in the spec.
    static func failureDeviceSecretScaled(_ from: String, _ to: String) -> String {
        String(
            localized: "data_failure_device_secret_scaled",
            defaultValue: """
                This phone no longer holds the keys of your vault. That happens when the app's data was cleared or the phone \
                was set up again from a backup. Nothing was disclosed. Whether you can get back into the vault depends on one \
                of its settings. If its credential backup was on (the usual case), you can recover it: start a recovery on the \
                account site. It takes \(from) to \(to), and you need your PIN and your password. If you had turned \
                credential backup off, this vault cannot be brought back; you can delete it on the account site and start a \
                new one. If you still have a phone on which VettID works, use 'Move to a new phone' there instead. The account \
                site tells you which of these applies.
                """,
            bundle: .module
        )
    }
    static func durationDays(_ n: Int) -> String {
        String(localized: "data_duration_days", defaultValue: "\(n) days", bundle: .module)
    }
    static func durationHours(_ n: Int) -> String {
        String(localized: "data_duration_hours", defaultValue: "\(n) hours", bundle: .module)
    }
    static func durationMinutes(_ n: Int) -> String {
        String(localized: "data_duration_minutes", defaultValue: "\(n) minutes", bundle: .module)
    }
    static func durationSeconds(_ n: Int) -> String {
        String(localized: "data_duration_seconds", defaultValue: "\(n) seconds", bundle: .module)
    }
}
