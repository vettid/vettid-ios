import Foundation
import LocalAuthentication
import CryptoKit

/// Service for managing app lock functionality including PIN and biometric authentication
@MainActor
class AppLockService: ObservableObject {
    static let shared = AppLockService()

    @Published var isLocked = false
    @Published var failedAttempts = 0
    @Published var lockoutEndTime: Date?

    private let maxFailedAttempts = 5
    private let lockoutDuration: TimeInterval = 300 // 5 minutes

    private var backgroundTime: Date?
    private var settings: AppLockSettings {
        UserPreferences.load().appLock
    }

    private init() {}

    // MARK: - Lock State Management

    /// Check if app should be locked based on settings and background time
    func checkLockState(backgroundDuration: TimeInterval) {
        guard settings.isEnabled else {
            isLocked = false
            return
        }

        let timeout = settings.autoLockTimeout
        if timeout == .never {
            return
        }

        let timeoutSeconds = TimeInterval(timeout.rawValue * 60)
        if backgroundDuration >= timeoutSeconds {
            lock()
        }
    }

    /// Lock the app
    func lock() {
        guard settings.isEnabled else { return }
        isLocked = true
    }

    /// Attempt to unlock with PIN
    func unlockWithPIN(_ pin: String) -> Bool {
        // Check for lockout
        if let lockoutEnd = lockoutEndTime, Date() < lockoutEnd {
            return false
        }

        guard let storedHash = settings.pinHash else {
            return false
        }

        let enteredHash = hashPIN(pin)
        if enteredHash == storedHash {
            isLocked = false
            failedAttempts = 0
            lockoutEndTime = nil
            return true
        } else {
            failedAttempts += 1
            if failedAttempts >= maxFailedAttempts {
                lockoutEndTime = Date().addingTimeInterval(lockoutDuration)
                failedAttempts = 0
            }
            return false
        }
    }

    /// Attempt to unlock with biometrics
    func unlockWithBiometrics() async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock VettID"
            )

            if success {
                await MainActor.run {
                    isLocked = false
                    failedAttempts = 0
                }
            }

            return success
        } catch {
            return false
        }
    }

    // MARK: - PIN Management

    /// Set a new PIN
    func setPIN(_ pin: String) -> Bool {
        guard pin.count >= 4 && pin.count <= 6 else {
            return false
        }

        guard pin.allSatisfy({ $0.isNumber }) else {
            return false
        }

        var prefs = UserPreferences.load()
        prefs.appLock.pinHash = hashPIN(pin)
        prefs.appLock.isEnabled = true
        prefs.save()

        return true
    }

    /// Verify current PIN
    func verifyPIN(_ pin: String) -> Bool {
        guard let storedHash = settings.pinHash else {
            return false
        }
        return hashPIN(pin) == storedHash
    }

    /// Clear PIN and disable app lock
    func clearPIN() {
        var prefs = UserPreferences.load()
        prefs.appLock.pinHash = nil
        prefs.appLock.isEnabled = false
        prefs.save()
        isLocked = false
    }

    // MARK: - Biometric Support

    /// Check if biometrics are available
    var isBiometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Get the type of biometrics available
    var biometricType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }

    /// Check if biometrics should be used based on settings
    var shouldUseBiometrics: Bool {
        guard isBiometricsAvailable else { return false }
        let method = settings.method
        return method == .biometrics || method == .both
    }

    /// Check if PIN should be used based on settings
    var shouldUsePIN: Bool {
        let method = settings.method
        return method == .pin || method == .both
    }

    // MARK: - Lockout

    /// Get remaining lockout time in seconds
    var remainingLockoutTime: TimeInterval? {
        guard let lockoutEnd = lockoutEndTime else { return nil }
        let remaining = lockoutEnd.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    /// Check if currently locked out due to failed attempts
    var isLockedOut: Bool {
        if let lockoutEnd = lockoutEndTime {
            return Date() < lockoutEnd
        }
        return false
    }

    // MARK: - Background Time Tracking

    /// Record when app went to background
    func appDidEnterBackground() {
        backgroundTime = Date()
    }

    /// Check lock when app returns to foreground
    func appWillEnterForeground() {
        guard let backgroundTime = backgroundTime else { return }
        let duration = Date().timeIntervalSince(backgroundTime)
        checkLockState(backgroundDuration: duration)
        self.backgroundTime = nil
    }

    // MARK: - Private Helpers

    private func hashPIN(_ pin: String) -> String {
        // Use SHA256 for PIN hashing
        // In production, consider using a more secure method with salt
        let data = Data(pin.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Lockout Timer

extension AppLockService {
    /// Format remaining lockout time for display
    var formattedLockoutTime: String? {
        guard let remaining = remainingLockoutTime else { return nil }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
