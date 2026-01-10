import Foundation
import UIKit
import UserNotifications

// MARK: - Protean Recovery Service

/// Manages the 24-hour delayed recovery flow for Protean Credentials
///
/// Security rationale: The 24-hour delay prevents immediate credential theft
/// if an attacker gains access to a user's VettID account. The user has time
/// to notice suspicious activity and cancel the recovery request.
///
/// ## Recovery Flow (Issue #8)
///
/// 1. User requests recovery → 24-hour delay starts
/// 2. After delay, recovery becomes "ready"
/// 3. User calls `confirmAndAuthenticate(password:)` which:
///    - Calls Lambda `/vault/credentials/restore/confirm` to get bootstrap credentials
///    - Connects to NATS with bootstrap credentials
///    - Authenticates via NATS `app.authenticate` with password
///    - Vault verifies password and issues full NATS credentials
///    - Stores restored credential locally
@MainActor
final class ProteanRecoveryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ProteanRecoveryState = .idle
    @Published private(set) var activeRecovery: ActiveRecoveryInfo?
    @Published private(set) var error: ProteanRecoveryError?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let credentialStore: ProteanCredentialStore
    private let natsConnectionManager: NatsConnectionManager
    private let authTokenProvider: @Sendable () -> String?
    private let qrRecoveryClient: QrRecoveryClient

    // MARK: - Polling

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 60  // Poll every minute

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        credentialStore: ProteanCredentialStore = ProteanCredentialStore(),
        natsConnectionManager: NatsConnectionManager,
        qrRecoveryClient: QrRecoveryClient = QrRecoveryClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.credentialStore = credentialStore
        self.natsConnectionManager = natsConnectionManager
        self.qrRecoveryClient = qrRecoveryClient
        self.authTokenProvider = authTokenProvider
    }

    /// Convenience initializer that creates a new NatsConnectionManager
    /// - Note: Must be called from MainActor context
    @MainActor
    convenience init(
        apiClient: APIClient = APIClient(),
        credentialStore: ProteanCredentialStore = ProteanCredentialStore(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.init(
            apiClient: apiClient,
            credentialStore: credentialStore,
            natsConnectionManager: NatsConnectionManager(),
            qrRecoveryClient: QrRecoveryClient(),
            authTokenProvider: authTokenProvider
        )
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Public API

    /// Request credential recovery - initiates 24-hour delay
    func requestRecovery() async {
        guard let authToken = authTokenProvider() else {
            error = .notAuthenticated
            return
        }

        state = .requesting

        do {
            let response = try await apiClient.requestProteanRecovery(authToken: authToken)

            let availableAt = ISO8601DateFormatter().date(from: response.availableAt) ?? Date().addingTimeInterval(86400)

            activeRecovery = ActiveRecoveryInfo(
                recoveryId: response.recoveryId,
                requestedAt: Date(),
                availableAt: availableAt,
                status: .pending
            )

            state = .pending
            error = nil

            // Schedule local notification for when recovery is ready
            scheduleRecoveryReadyNotification(availableAt: availableAt)

            // Start polling for status
            startPolling()

        } catch {
            self.error = .requestFailed(error.localizedDescription)
            state = .error
        }
    }

    /// Check recovery status
    func checkStatus() async {
        guard let recovery = activeRecovery,
              let authToken = authTokenProvider() else {
            return
        }

        do {
            let response = try await apiClient.getProteanRecoveryStatus(
                recoveryId: recovery.recoveryId,
                authToken: authToken
            )

            // Update status
            let status = ProteanRecoveryStatus(rawValue: response.status) ?? .pending

            activeRecovery = ActiveRecoveryInfo(
                recoveryId: recovery.recoveryId,
                requestedAt: recovery.requestedAt,
                availableAt: recovery.availableAt,
                status: status,
                remainingSeconds: response.remainingSeconds
            )

            switch status {
            case .pending:
                state = .pending
            case .ready:
                state = .ready
                stopPolling()
            case .cancelled:
                state = .cancelled
                stopPolling()
                activeRecovery = nil
            case .expired:
                state = .expired
                stopPolling()
                activeRecovery = nil
            }

        } catch {
            self.error = .statusCheckFailed(error.localizedDescription)
        }
    }

    /// Cancel a pending recovery request
    func cancelRecovery() async {
        guard let recovery = activeRecovery,
              let authToken = authTokenProvider() else {
            return
        }

        state = .cancelling

        do {
            try await apiClient.cancelProteanRecovery(
                recoveryId: recovery.recoveryId,
                authToken: authToken
            )

            activeRecovery = nil
            state = .cancelled
            error = nil

            // Cancel scheduled notification
            cancelRecoveryNotification()
            stopPolling()

        } catch {
            self.error = .cancelFailed(error.localizedDescription)
            state = .error
        }
    }

    /// Confirm and authenticate credential restore via NATS (Issue #8)
    ///
    /// This is the main restore method that:
    /// 1. Calls confirmRestore to get bootstrap credentials and encrypted backup
    /// 2. Connects to NATS with bootstrap credentials
    /// 3. Authenticates with the vault via NATS (password verification)
    /// 4. Receives full NATS credentials and restores the credential
    ///
    /// - Parameter password: User's vault password for verification
    func confirmAndAuthenticate(password: String) async {
        guard let recovery = activeRecovery,
              recovery.status == .ready,
              let authToken = authTokenProvider() else {
            error = .recoveryNotReady
            return
        }

        state = .downloading

        do {
            // Step 1: Call Lambda to get bootstrap credentials and encrypted backup
            let confirmResponse = try await apiClient.confirmRestore(
                recoveryId: recovery.recoveryId,
                authToken: authToken
            )

            #if DEBUG
            print("[Recovery] Got bootstrap credentials, connecting to NATS...")
            #endif

            state = .authenticating

            // Step 2 & 3: Connect to NATS and authenticate with password
            let authResponse = try await natsConnectionManager.connectAndAuthenticate(
                bootstrap: confirmResponse.vaultBootstrap,
                encryptedCredential: confirmResponse.credentialBackup.encryptedCredential,
                keyId: confirmResponse.credentialBackup.keyId,
                password: password
            )

            #if DEBUG
            print("[Recovery] NATS authentication successful")
            #endif

            // Step 4: Store the credential
            // The credential is now decrypted by the vault and we have full NATS access
            // The encrypted credential backup was sent to the vault which decrypted it
            // and verified the password hash matches

            // Create metadata for the restored credential
            let metadata = ProteanCredentialMetadata(
                version: 1,  // Starting fresh after restore
                createdAt: Date(),
                sizeBytes: 0,  // Will be updated when we get the actual credential
                userGuid: authResponse.ownerSpace ?? ""
            )

            // Note: The actual credential blob is handled by the vault
            // We store minimal metadata locally to track that credential exists
            // The NATS credentials are stored by NatsConnectionManager

            // Mark backup info
            if let backupId = confirmResponse.credentialBackup.backupId as String? {
                // Create a placeholder for the credential store
                // The actual credential data is managed by the vault
                let placeholderBlob = Data()  // Empty - credential is in vault
                try credentialStore.store(blob: placeholderBlob, metadata: metadata)
                try credentialStore.markAsBackedUp(backupId: backupId)
            }

            activeRecovery = nil
            state = .complete
            error = nil

            stopPolling()
            clearPersistedRecovery()

            #if DEBUG
            print("[Recovery] Credential restore complete")
            #endif

        } catch let natsError as NatsConnectionError {
            #if DEBUG
            print("[Recovery] NATS error: \(natsError.localizedDescription)")
            #endif

            // Disconnect NATS on failure
            await natsConnectionManager.disconnect()

            // Check for password verification failure
            let errorMessage = natsError.localizedDescription.lowercased()
            if errorMessage.contains("password") || errorMessage.contains("authentication failed") {
                self.error = .passwordVerificationFailed
            } else {
                self.error = .authenticationFailed(natsError.localizedDescription)
            }
            state = .error

        } catch {
            #if DEBUG
            print("[Recovery] Failed: \(error.localizedDescription)")
            #endif

            // Disconnect NATS on failure
            await natsConnectionManager.disconnect()

            self.error = .downloadFailed(error.localizedDescription)
            state = .error
        }
    }

    /// Download recovered credential (available after 24 hours)
    /// - Note: Deprecated - use confirmAndAuthenticate(password:) instead (Issue #8)
    @available(*, deprecated, message: "Use confirmAndAuthenticate(password:) instead")
    func downloadCredential() async {
        guard let recovery = activeRecovery,
              recovery.status == .ready,
              let authToken = authTokenProvider() else {
            error = .recoveryNotReady
            return
        }

        state = .downloading

        do {
            let response = try await apiClient.downloadRecoveredCredential(
                recoveryId: recovery.recoveryId,
                authToken: authToken
            )

            guard let blobData = Data(base64Encoded: response.credentialBlob) else {
                error = .invalidCredentialData
                state = .error
                return
            }

            // Store the recovered credential
            let metadata = ProteanCredentialMetadata(
                version: response.version,
                createdAt: Date(),
                sizeBytes: blobData.count,
                userGuid: ""  // Will be filled in after decryption
            )

            try credentialStore.store(blob: blobData, metadata: metadata)

            activeRecovery = nil
            state = .complete
            error = nil

            stopPolling()

        } catch {
            self.error = .downloadFailed(error.localizedDescription)
            state = .error
        }
    }

    /// Reset state after recovery completes or is cancelled
    func reset() {
        activeRecovery = nil
        state = .idle
        error = nil
        stopPolling()
        cancelRecoveryNotification()
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
        print("[Recovery] UserGuid: \(result.userGuid ?? "unknown")")
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
            clearPersistedRecovery()

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

    /// Check for existing pending recovery on app launch
    func checkForPendingRecovery() async {
        guard authTokenProvider() != nil else {
            return
        }

        // Try to get backup status first to see if there's a pending recovery
        // This would need a dedicated endpoint to list active recoveries
        // For now, we'll rely on persisted local state
        if let savedRecovery = loadPersistedRecovery() {
            activeRecovery = savedRecovery
            state = .pending
            await checkStatus()
            if state == .pending {
                startPolling()
            }
        }
    }

    // MARK: - Time Helpers

    /// Get remaining time until recovery is available
    var remainingTime: TimeInterval? {
        guard let recovery = activeRecovery else { return nil }
        let remaining = recovery.availableAt.timeIntervalSinceNow
        return max(0, remaining)
    }

    /// Get formatted remaining time string
    var remainingTimeString: String {
        guard let remaining = remainingTime, remaining > 0 else {
            return "Ready"
        }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m remaining"
        } else {
            return "\(minutes)m remaining"
        }
    }

    // MARK: - Private Helpers

    private func startPolling() {
        stopPolling()

        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))

                if Task.isCancelled { break }

                await checkStatus()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func scheduleRecoveryReadyNotification(availableAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Credential Recovery Ready"
        content.body = "Your VettID credential recovery is now available. Open the app to complete the process."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, availableAt.timeIntervalSinceNow),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "protean-recovery-ready",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func cancelRecoveryNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["protean-recovery-ready"]
        )
    }

    // MARK: - Persistence

    private let recoveryPersistenceKey = "com.vettid.pending-recovery"

    private func persistRecovery(_ recovery: ActiveRecoveryInfo) {
        if let data = try? JSONEncoder().encode(recovery) {
            UserDefaults.standard.set(data, forKey: recoveryPersistenceKey)
        }
    }

    private func loadPersistedRecovery() -> ActiveRecoveryInfo? {
        guard let data = UserDefaults.standard.data(forKey: recoveryPersistenceKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ActiveRecoveryInfo.self, from: data)
    }

    private func clearPersistedRecovery() {
        UserDefaults.standard.removeObject(forKey: recoveryPersistenceKey)
    }
}

// MARK: - Supporting Types

/// Current state of the recovery process
enum ProteanRecoveryState: Equatable {
    case idle
    case requesting
    case pending
    case ready
    case downloading
    case authenticating  // Issue #8: NATS authentication in progress
    case complete
    case cancelling
    case cancelled
    case expired
    case error
    case scanningQrCode      // Issue #13: QR code scanning in progress
    case processingQrCode    // Issue #13: Processing scanned QR code
}

/// Information about an active recovery request
struct ActiveRecoveryInfo: Codable, Equatable {
    let recoveryId: String
    let requestedAt: Date
    let availableAt: Date
    var status: ProteanRecoveryStatus
    var remainingSeconds: Int?

    /// Check if recovery is ready to download
    var isReady: Bool {
        status == .ready && Date() >= availableAt
    }

    /// Progress towards completion (0.0 to 1.0)
    var progress: Double {
        let total = availableAt.timeIntervalSince(requestedAt)
        let elapsed = Date().timeIntervalSince(requestedAt)
        return min(1.0, max(0.0, elapsed / total))
    }
}

/// Errors that can occur during recovery
enum ProteanRecoveryError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case requestFailed(String)
    case statusCheckFailed(String)
    case cancelFailed(String)
    case downloadFailed(String)
    case recoveryNotReady
    case invalidCredentialData
    case noPendingRecovery
    case authenticationFailed(String)  // Issue #8: NATS authentication error
    case passwordVerificationFailed    // Issue #8: Vault rejected password
    case qrRecoveryFailed(String)      // Issue #13: QR code recovery error
    case invalidQrCode                 // Issue #13: Invalid QR code scanned

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please sign in first."
        case .requestFailed(let message):
            return "Failed to request recovery: \(message)"
        case .statusCheckFailed(let message):
            return "Failed to check recovery status: \(message)"
        case .cancelFailed(let message):
            return "Failed to cancel recovery: \(message)"
        case .downloadFailed(let message):
            return "Failed to download credential: \(message)"
        case .recoveryNotReady:
            return "Recovery is not ready yet. Please wait for the 24-hour delay to complete."
        case .invalidCredentialData:
            return "Received invalid credential data from server."
        case .noPendingRecovery:
            return "No pending recovery request found."
        case .authenticationFailed(let message):
            return "Failed to authenticate with vault: \(message)"
        case .passwordVerificationFailed:
            return "Incorrect password. Please verify your vault password and try again."
        case .qrRecoveryFailed(let message):
            return "QR code recovery failed: \(message)"
        case .invalidQrCode:
            return "Invalid QR code. Please scan a valid VettID recovery QR code from the Account Portal."
        }
    }
}
