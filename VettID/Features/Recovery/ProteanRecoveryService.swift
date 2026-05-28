import Foundation
import UIKit

// MARK: - Protean Recovery Service

/// Manages QR-based credential recovery for Protean Credentials.
///
/// Email-based recovery (24-hour delay, status polling, cancel/expire,
/// password re-entry) was removed — the Account Portal issues a one-shot
/// recovery QR code after the delay completes, and this service exchanges
/// that QR for fresh NATS credentials.
///
/// ## Recovery Flow (Issue #13)
///
/// 1. User scans recovery QR code from the Account Portal
/// 2. `processRecoveryQrCode` parses the QR + exchanges the embedded token
/// 3. On success, NATS credentials are stored and the credential is restored
@MainActor
final class ProteanRecoveryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ProteanRecoveryState = .idle
    @Published private(set) var error: ProteanRecoveryError?

    // MARK: - Dependencies

    private let credentialStore: ProteanCredentialStore
    private let natsConnectionManager: NatsConnectionManager
    private let qrRecoveryClient: QrRecoveryClient

    // MARK: - Initialization

    init(
        credentialStore: ProteanCredentialStore = ProteanCredentialStore(),
        natsConnectionManager: NatsConnectionManager,
        qrRecoveryClient: QrRecoveryClient = QrRecoveryClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.credentialStore = credentialStore
        self.natsConnectionManager = natsConnectionManager
        self.qrRecoveryClient = qrRecoveryClient
    }

    /// Convenience initializer that creates a new NatsConnectionManager
    /// - Note: Must be called from MainActor context
    @MainActor
    convenience init(
        credentialStore: ProteanCredentialStore = ProteanCredentialStore(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.init(
            credentialStore: credentialStore,
            natsConnectionManager: NatsConnectionManager(),
            qrRecoveryClient: QrRecoveryClient(),
            authTokenProvider: authTokenProvider
        )
    }

    // MARK: - Public API

    /// Reset state — used by the error view's Try Again button.
    func reset() {
        state = .idle
        error = nil
    }

    // MARK: - QR Code Recovery (Issue #13)

    /// Start QR code scanning for instant recovery
    func startQrScanning() {
        state = .scanningQrCode
        error = nil
    }

    /// Cancel QR code scanning
    func cancelQrScanning() {
        state = .idle
        error = nil
    }

    /// Process a scanned QR code for instant recovery
    ///
    /// This method:
    /// 1. Parses the QR code content
    /// 2. Connects to NATS with temporary credentials
    /// 3. Exchanges recovery token for full credentials
    /// 4. Stores the recovered credential
    ///
    /// - Parameter qrContent: Raw QR code content (JSON string)
    func processRecoveryQrCode(_ qrContent: String) async {
        // Validate QR code format
        guard RecoveryQrCode.isRecoveryQrCode(qrContent) else {
            error = .invalidQrCode
            state = .error
            return
        }

        // Parse QR code
        guard let recoveryQr = RecoveryQrCode.parse(qrContent) else {
            error = .invalidQrCode
            state = .error
            return
        }

        state = .processingQrCode
        error = nil

        #if DEBUG
        print("[Recovery] Processing QR code recovery")
        print("[Recovery] Vault: \(recoveryQr.natsEndpoint)")
        print("[Recovery] OwnerSpace: \(recoveryQr.ownerSpace)")
        #endif

        // Get device ID
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

        // Exchange recovery token
        let result = await qrRecoveryClient.exchangeRecoveryToken(
            recoveryQr: recoveryQr,
            deviceId: deviceId,
            appVersion: appVersion
        )

        switch result {
        case .success(let exchangeResult):
            if exchangeResult.success {
                await handleSuccessfulQrRecovery(exchangeResult)
            } else {
                error = .qrRecoveryFailed(exchangeResult.message)
                state = .error
            }

        case .failure(let qrError):
            error = .qrRecoveryFailed(qrError.localizedDescription)
            state = .error
        }
    }

    /// Handle successful QR recovery exchange
    private func handleSuccessfulQrRecovery(_ result: RecoveryExchangeResult) async {
        #if DEBUG
        print("[Recovery] QR recovery successful")
        #endif

        // Store the recovered credential
        do {
            // Create metadata for the restored credential
            let metadata = ProteanCredentialMetadata(
                version: result.credentialVersion ?? 1,
                createdAt: Date(),
                sizeBytes: 0,
                userGuid: result.userGuid ?? ""
            )

            // Store credential (actual credential data is managed by vault)
            let placeholderBlob = Data()
            try credentialStore.store(blob: placeholderBlob, metadata: metadata)

            // If we got NATS credentials, connect with them
            if let credentialsContent = result.credentials {
                // Determine endpoint - prefer explicit endpoint, fall back to default
                let natsEndpoint = result.natsEndpoint ?? "vault.vettid.dev:4222"
                let ownerSpace = result.ownerSpace ?? ""

                // Parse NATS credentials using the .creds file format initializer
                if let parsedCreds = NatsCredentials(
                    fromCredsFileContent: credentialsContent,
                    endpoint: natsEndpoint,
                    ownerSpace: ownerSpace,
                    messageSpace: result.messageSpace
                ) {
                    try await natsConnectionManager.connectWithEnrollmentCredentials(
                        parsedCreds,
                        ownerSpace: result.ownerSpace
                    )
                }
            }

            state = .complete
            error = nil

            #if DEBUG
            print("[Recovery] QR credential restore complete")
            #endif

        } catch {
            #if DEBUG
            print("[Recovery] Failed to store QR recovered credential: \(error)")
            #endif
            self.error = .qrRecoveryFailed("Failed to store credential: \(error.localizedDescription)")
            state = .error
        }
    }
}

// MARK: - Supporting Types

/// Current state of the recovery process. QR-only flow: the email
/// "request + 24h delay + cancel/expire" branches were removed; the
/// Account Portal is the source of truth for issuing recovery QR codes.
enum ProteanRecoveryState: Equatable {
    case idle
    case scanningQrCode      // Issue #13: QR code scanning in progress
    case processingQrCode    // Issue #13: Processing scanned QR code
    case authenticating      // Issue #8: NATS authentication in progress
    case complete
    case error
}

/// Errors that can occur during QR recovery
enum ProteanRecoveryError: Error, LocalizedError, Equatable {
    case qrRecoveryFailed(String)
    case invalidQrCode

    var errorDescription: String? {
        switch self {
        case .qrRecoveryFailed(let message):
            return "QR code recovery failed: \(message)"
        case .invalidQrCode:
            return "Invalid QR code. Please scan a valid VettID recovery QR code from the Account Portal."
        }
    }
}
