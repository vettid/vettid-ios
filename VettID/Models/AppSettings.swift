import Foundation

// MARK: - App Theme

enum AppTheme: String, CaseIterable, Codable {
    case auto = "Auto"
    case light = "Light"
    case dark = "Dark"

    var systemColorScheme: String? {
        switch self {
        case .auto: return nil
        case .light: return "light"
        case .dark: return "dark"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Follow system setting"
        case .light: return "Always use light mode"
        case .dark: return "Always use dark mode"
        }
    }
}

// MARK: - App Lock Method

enum AppLockMethod: String, CaseIterable, Codable {
    case pin = "PIN"
    case biometrics = "Biometrics"
    case both = "PIN & Biometrics"

    var icon: String {
        switch self {
        case .pin: return "lock.fill"
        case .biometrics: return "faceid"
        case .both: return "lock.shield.fill"
        }
    }

    var description: String {
        switch self {
        case .pin: return "Use a 4-6 digit PIN"
        case .biometrics: return "Use Face ID or Touch ID"
        case .both: return "Use both PIN and biometrics"
        }
    }
}

// MARK: - Auto Lock Timeout

enum AutoLockTimeout: Int, CaseIterable, Codable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case never = 0

    var displayName: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .never: return "Never"
        }
    }
}

// MARK: - App Lock Settings

struct AppLockSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var method: AppLockMethod = .biometrics
    var autoLockTimeout: AutoLockTimeout = .fiveMinutes
    var pinHash: String? = nil

    static let `default` = AppLockSettings()
}

// MARK: - User Preferences

struct UserPreferences: Codable {
    var theme: AppTheme = .auto
    var appLock: AppLockSettings = .default
    var notificationsEnabled: Bool = true
    var hapticFeedbackEnabled: Bool = true

    static let `default` = UserPreferences()

    // MARK: - Persistence Keys

    private static let userDefaultsKey = "vettid.userPreferences"

    static func load() -> UserPreferences {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
            return .default
        }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
