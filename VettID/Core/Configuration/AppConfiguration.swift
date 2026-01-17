import Foundation

/// Centralized app configuration loaded from Info.plist
/// Environment-specific values can be set via build configurations
enum AppConfiguration {

    // MARK: - API URLs

    /// Primary API base URL for VettID services
    static var apiBaseURL: URL {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "VettIDAPIBaseURL") as? String,
              let url = URL(string: urlString) else {
            return URL(string: "https://api.vettid.dev")!
        }
        return url
    }

    /// Enrollment API URL (may differ from primary API during development)
    static var enrollmentAPIURL: URL {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "VettIDEnrollmentAPIURL") as? String,
              let url = URL(string: urlString) else {
            return apiBaseURL
        }
        return url
    }

    // MARK: - Feature Flags

    /// Whether debug logging is enabled
    static var isDebugLoggingEnabled: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "VettIDDebugLogging") as? Bool ?? false
        #endif
    }

    // MARK: - App Info

    /// App version string
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Build number
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Full version string (e.g., "1.0 (42)")
    static var fullVersionString: String {
        "\(appVersion) (\(buildNumber))"
    }
}
