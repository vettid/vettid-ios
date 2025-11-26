import Foundation
import LocalAuthentication

/// Handles biometric authentication (Face ID / Touch ID)
final class BiometricAuthService {

    private let context = LAContext()

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
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: - Authentication

    /// Authenticate the user with biometrics
    func authenticate(reason: String = "Unlock VettID") async throws -> Bool {
        let context = LAContext()

        // Check if biometrics are available
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let error = error {
                throw BiometricError.from(laError: error)
            }
            throw BiometricError.notAvailable
        }

        // Perform authentication
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw BiometricError.from(laError: error)
        } catch {
            throw BiometricError.unknown(error)
        }
    }

    /// Authenticate with fallback to device passcode
    func authenticateWithFallback(reason: String = "Unlock VettID") async throws -> Bool {
        let context = LAContext()

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw BiometricError.from(laError: error)
        } catch {
            throw BiometricError.unknown(error)
        }
    }
}

// MARK: - Errors

enum BiometricError: Error {
    case notAvailable
    case notEnrolled
    case lockout
    case cancelled
    case passcodeNotSet
    case biometryNotAvailable
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
        default:
            return .unknown(laError)
        }
    }

    var localizedDescription: String {
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
}
