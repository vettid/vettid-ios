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
