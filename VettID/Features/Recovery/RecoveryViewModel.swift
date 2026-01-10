import Foundation
import SwiftUI

/// ViewModel for the recovery flow
@MainActor
final class RecoveryViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: RecoveryState = .idle
    @Published var scannedQRCode: RecoveryQRCode?
    @Published var newPassword: String = ""
    @Published var confirmPassword: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let recoveryService: RecoveryService
    private let deviceId: String
    private let onRecoveryComplete: ((String, String) -> Void)?

    // MARK: - Computed Properties

    var canProceedWithPassword: Bool {
        !newPassword.isEmpty &&
        newPassword == confirmPassword &&
        newPassword.count >= 8
    }

    var passwordError: String? {
        if newPassword.isEmpty { return nil }
        if newPassword.count < 8 {
            return "Password must be at least 8 characters"
        }
        if !confirmPassword.isEmpty && newPassword != confirmPassword {
            return "Passwords do not match"
        }
        return nil
    }

    // MARK: - Initialization

    init(
        recoveryService: RecoveryService = RecoveryService(),
        deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
        onRecoveryComplete: ((String, String) -> Void)? = nil
    ) {
        self.recoveryService = recoveryService
        self.deviceId = deviceId
        self.onRecoveryComplete = onRecoveryComplete
    }

    // MARK: - Public Methods

    /// Start scanning for recovery QR code
    func startScanning() {
        state = .scanning
        errorMessage = nil
    }

    /// Handle scanned QR code
    func handleScannedCode(_ code: String) {
        state = .validating
        isLoading = true

        guard let qrCode = RecoveryQRCode.parse(from: code) else {
            state = .failed(error: .invalidQRCode)
            errorMessage = RecoveryError.invalidQRCode.errorDescription
            isLoading = false
            return
        }

        if !qrCode.isValid {
            if let expires = qrCode.expiresAt, expires < Date() {
                state = .failed(error: .qrCodeExpired)
                errorMessage = RecoveryError.qrCodeExpired.errorDescription
            } else {
                state = .failed(error: .invalidQRCode)
                errorMessage = RecoveryError.invalidQRCode.errorDescription
            }
            isLoading = false
            return
        }

        scannedQRCode = qrCode
        state = .enteringPassword
        isLoading = false
    }

    /// Proceed with recovery using entered password
    func proceedWithRecovery() {
        guard canProceedWithPassword, let qrCode = scannedQRCode else { return }

        Task {
            await exchangeToken(qrCode: qrCode, password: newPassword)
        }
    }

    /// Exchange recovery token for new credential
    private func exchangeToken(qrCode: RecoveryQRCode, password: String) async {
        state = .exchangingToken
        isLoading = true
        errorMessage = nil

        do {
            let response = try await recoveryService.exchangeRecoveryToken(
                qrCode: qrCode,
                deviceId: deviceId,
                newPassword: password
            )

            if response.success, let credential = response.encryptedCredential, let userGuid = response.userGuid {
                state = .savingCredential
                await saveCredential(credential, userGuid: userGuid)
            } else {
                let error = response.error ?? "Unknown error"
                state = .failed(error: .tokenExchangeFailed(error))
                errorMessage = error
            }
        } catch let error as RecoveryError {
            state = .failed(error: error)
            errorMessage = error.errorDescription
        } catch {
            state = .failed(error: .networkError)
            errorMessage = RecoveryError.networkError.errorDescription
        }

        isLoading = false
    }

    /// Save recovered credential to secure storage
    private func saveCredential(_ encryptedCredential: String, userGuid: String) async {
        // In production, this would save to SecureKeyStore
        // For now, we just complete the flow
        do {
            // Simulate saving to keychain
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            state = .completed(userGuid: userGuid)
            onRecoveryComplete?(userGuid, encryptedCredential)

            print("[Recovery] Credential saved successfully for user: \(userGuid)")
        } catch {
            state = .failed(error: .credentialSaveFailed)
            errorMessage = RecoveryError.credentialSaveFailed.errorDescription
        }
    }

    /// Cancel recovery and reset state
    func cancelRecovery() {
        state = .idle
        scannedQRCode = nil
        newPassword = ""
        confirmPassword = ""
        errorMessage = nil
        isLoading = false
    }

    /// Retry after failure
    func retry() {
        errorMessage = nil
        if scannedQRCode != nil {
            state = .enteringPassword
        } else {
            state = .scanning
        }
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }
}
