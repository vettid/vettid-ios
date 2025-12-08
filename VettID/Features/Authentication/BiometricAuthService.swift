import Foundation
import LocalAuthentication

/// Handles biometric authentication (Face ID / Touch ID)
/// Security hardened with timeout management and enrollment change detection
final class BiometricAuthService {

    // MARK: - Configuration

    /// Authentication timeout in seconds (default: 5 minutes)
    private let authenticationTimeout: TimeInterval = 300

    /// Stored domain state for detecting biometric enrollment changes
    private var storedDomainState: Data?

    /// UserDefaults key for persisting domain state
    private static let domainStateKey = "BiometricDomainState"

    // MARK: - Initialization

    init() {
        // Load stored domain state
        storedDomainState = UserDefaults.standard.data(forKey: Self.domainStateKey)
    }

    // MARK: - Biometric Type

    enum BiometricType {
        case none
        case faceID
        case touchID
        case opticID

        var displayName: String {
            switch self {
            case .none: return "Passcode"
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            }
        }

        var systemImage: String {
            switch self {
            case .none: return "key.fill"
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .opticID: return "opticid"
            }
        }
    }

    /// Get the available biometric type on this device
    var availableBiometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }

    /// Check if biometric authentication is available
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Authentication

    /// Authenticate the user with biometrics
    /// Returns a pre-authenticated LAContext for use with Keychain operations
    func authenticate(reason: String = "Unlock VettID") async throws -> LAContext {
        let context = createSecureContext()

        // Check if biometrics are available
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let error = error {
                throw BiometricError.from(laError: error)
            }
            throw BiometricError.notAvailable
        }

        // Check for biometric enrollment changes
        if hasBiometricEnrollmentChanged(context: context) {
            throw BiometricError.enrollmentChanged
        }

        // Perform authentication
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if success {
                // Update stored domain state on successful auth
                updateStoredDomainState(context: context)
                return context
            }
            throw BiometricError.authenticationFailed
        } catch let error as LAError {
            throw BiometricError.from(laError: error)
        } catch let biometricError as BiometricError {
            throw biometricError
        } catch {
            throw BiometricError.unknown(error)
        }
    }

    /// Authenticate and return boolean (simpler API)
    func authenticateSimple(reason: String = "Unlock VettID") async throws -> Bool {
        _ = try await authenticate(reason: reason)
        return true
    }

    /// Authenticate with fallback to device passcode
    func authenticateWithFallback(reason: String = "Unlock VettID") async throws -> LAContext {
        let context = createSecureContext()

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if success {
                return context
            }
            throw BiometricError.authenticationFailed
        } catch let error as LAError {
            throw BiometricError.from(laError: error)
        } catch let biometricError as BiometricError {
            throw biometricError
        } catch {
            throw BiometricError.unknown(error)
        }
    }

    // MARK: - Secure Context Creation

    /// Create a secure LAContext with proper configuration
    private func createSecureContext() -> LAContext {
        let context = LAContext()

        // Set authentication timeout
        context.touchIDAuthenticationAllowableReuseDuration = authenticationTimeout

        // Disable fallback button text (use system default or empty)
        context.localizedFallbackTitle = ""

        // Disable cancel button customization (use system default)
        context.localizedCancelTitle = nil

        return context
    }

    // MARK: - Biometric Enrollment Change Detection

    /// Check if biometric enrollment has changed since last authentication
    func hasBiometricEnrollmentChanged(context: LAContext? = nil) -> Bool {
        let ctx = context ?? LAContext()

        // Evaluate policy to get current domain state
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        guard let currentState = ctx.evaluatedPolicyDomainState else {
            return false
        }

        // First time - no stored state
        guard let storedState = storedDomainState else {
            return false
        }

        // Compare states
        return currentState != storedState
    }

    /// Update the stored domain state after successful authentication
    private func updateStoredDomainState(context: LAContext) {
        guard let domainState = context.evaluatedPolicyDomainState else { return }
        storedDomainState = domainState
        UserDefaults.standard.set(domainState, forKey: Self.domainStateKey)
    }

    /// Clear stored domain state (call when user logs out)
    func clearStoredDomainState() {
        storedDomainState = nil
        UserDefaults.standard.removeObject(forKey: Self.domainStateKey)
    }

    /// Initialize domain state for new user
    func initializeDomainState() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return
        }
        updateStoredDomainState(context: context)
    }

    // MARK: - Biometric Lockout Handling

    /// Check if biometrics are currently locked out
    var isBiometricLockedOut: Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        if let laError = error as? LAError, laError.code == .biometryLockout {
            return true
        }

        return !canEvaluate && error != nil
    }

    /// Reset biometric lockout by authenticating with passcode
    func resetBiometricLockout() async throws {
        let context = LAContext()

        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Enter passcode to reset biometric lockout"
            )
        } catch let error as LAError {
            throw BiometricError.from(laError: error)
        } catch {
            throw BiometricError.unknown(error)
        }
    }
}

// MARK: - Errors

enum BiometricError: Error, LocalizedError {
    case notAvailable
    case notEnrolled
    case lockout
    case cancelled
    case passcodeNotSet
    case biometryNotAvailable
    case authenticationFailed
    case enrollmentChanged
    case unknown(Error)

    static func from(laError: Error) -> BiometricError {
        guard let laError = laError as? LAError else {
            return .unknown(laError)
        }

        switch laError.code {
        case .biometryNotAvailable:
            return .biometryNotAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryLockout:
            return .lockout
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .authenticationFailed:
            return .authenticationFailed
        default:
            return .unknown(laError)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available"
        case .notEnrolled:
            return "No biometric data enrolled. Please set up Face ID or Touch ID in Settings."
        case .lockout:
            return "Biometric authentication is locked. Please use your device passcode."
        case .cancelled:
            return "Authentication was cancelled"
        case .passcodeNotSet:
            return "Please set a device passcode to use VettID"
        case .biometryNotAvailable:
            return "Biometric authentication is not available on this device"
        case .authenticationFailed:
            return "Biometric authentication failed"
        case .enrollmentChanged:
            return "Biometric enrollment has changed. Please re-authenticate with your password."
        case .unknown(let error):
            return "Authentication failed: \(error.localizedDescription)"
        }
    }

    var requiresPasscode: Bool {
        switch self {
        case .lockout, .notEnrolled:
            return true
        default:
            return false
        }
    }

    /// Whether re-enrollment is required
    var requiresReEnrollment: Bool {
        switch self {
        case .enrollmentChanged:
            return true
        default:
            return false
        }
    }
}
