import Foundation
import LocalAuthentication
import Combine

/// ViewModel for device-to-device credential transfer
/// Handles both new device (requesting) and old device (approving) flows
@MainActor
final class TransferViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: TransferState = .idle
    @Published private(set) var timeRemaining: TimeInterval = 0
    @Published private(set) var isLoading = false

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?
    private let securityService = VaultSecurityService.shared
    private let notificationManager = LocalNotificationManager.shared

    // MARK: - Internal State

    private var timerCancellable: AnyCancellable?
    private var currentTransferId: String?

    // MARK: - Initialization

    init() {
        setupSecurityServiceCallbacks()
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - New Device Flow

    /// Request transfer from an existing device (new device flow)
    func requestTransfer() async {
        guard state == .idle else {
            #if DEBUG
            print("[TransferViewModel] Cannot request transfer: not idle")
            #endif
            return
        }

        isLoading = true
        state = .requesting

        do {
            let transferId = UUID().uuidString
            let deviceInfo = DeviceInfo.current()
            let expiresAt = Date().addingTimeInterval(TransferTimeout.requestExpiration)

            // Send transfer request via NATS
            let request = TransferInitiationRequest(
                requestId: transferId,
                sourceDeviceInfo: deviceInfo,
                timestamp: Date()
            )

            try await ownerSpaceClient?.sendToVault(request, topic: "transfer.request")

            currentTransferId = transferId
            state = .waitingForApproval(transferId: transferId, expiresAt: expiresAt)
            startCountdownTimer(until: expiresAt)

            #if DEBUG
            print("[TransferViewModel] Transfer requested: \(transferId)")
            #endif

        } catch {
            state = .error(message: error.localizedDescription)
            #if DEBUG
            print("[TransferViewModel] Transfer request failed: \(error)")
            #endif
        }

        isLoading = false
    }

    /// Cancel a pending transfer request (new device flow)
    func cancelRequest() async {
        guard case .waitingForApproval(let transferId, _) = state else { return }

        isLoading = true

        do {
            let response = TransferResponse(
                transferId: transferId,
                approved: false,
                reason: "Cancelled by user",
                timestamp: Date()
            )

            try await ownerSpaceClient?.sendToVault(response, topic: "transfer.cancel")

            stopCountdownTimer()
            state = .idle
            currentTransferId = nil

            #if DEBUG
            print("[TransferViewModel] Transfer cancelled: \(transferId)")
            #endif

        } catch {
            #if DEBUG
            print("[TransferViewModel] Cancel failed: \(error)")
            #endif
        }

        isLoading = false
    }

    // MARK: - Old Device Flow

    /// Handle incoming transfer request (old device flow)
    func handleTransferRequest(_ event: TransferRequestedEvent) {
        state = .pendingApproval(request: event)
        currentTransferId = event.transferId
        startCountdownTimer(until: event.expiresAt)

        #if DEBUG
        print("[TransferViewModel] Received transfer request: \(event.transferId)")
        #endif
    }

    /// Approve a transfer request with biometric authentication (old device flow)
    func approve() async {
        guard case .pendingApproval(let request) = state else { return }

        isLoading = true

        // Require biometric authentication before approving
        let authenticated = await authenticateWithBiometric(
            reason: "Authenticate to approve credential transfer to \(request.targetDeviceInfo.displayName)"
        )

        guard authenticated else {
            isLoading = false
            #if DEBUG
            print("[TransferViewModel] Biometric authentication failed")
            #endif
            return
        }

        do {
            let response = TransferResponse(
                transferId: request.transferId,
                approved: true,
                reason: nil,
                timestamp: Date()
            )

            try await ownerSpaceClient?.sendToVault(response, topic: "transfer.approve")

            stopCountdownTimer()
            state = .approved(transferId: request.transferId)
            notificationManager.removeTransferNotifications(transferId: request.transferId)

            #if DEBUG
            print("[TransferViewModel] Transfer approved: \(request.transferId)")
            #endif

        } catch {
            state = .error(message: error.localizedDescription)
            #if DEBUG
            print("[TransferViewModel] Approve failed: \(error)")
            #endif
        }

        isLoading = false
    }

    /// Deny a transfer request (old device flow)
    func deny() async {
        guard case .pendingApproval(let request) = state else { return }

        isLoading = true

        do {
            let response = TransferResponse(
                transferId: request.transferId,
                approved: false,
                reason: "Denied by user",
                timestamp: Date()
            )

            try await ownerSpaceClient?.sendToVault(response, topic: "transfer.deny")

            stopCountdownTimer()
            state = .denied(transferId: request.transferId)
            notificationManager.removeTransferNotifications(transferId: request.transferId)

            #if DEBUG
            print("[TransferViewModel] Transfer denied: \(request.transferId)")
            #endif

        } catch {
            state = .error(message: error.localizedDescription)
            #if DEBUG
            print("[TransferViewModel] Deny failed: \(error)")
            #endif
        }

        isLoading = false
    }

    // MARK: - Event Handling

    /// Handle security events from VaultSecurityService
    private func setupSecurityServiceCallbacks() {
        securityService.onTransferAction = { [weak self] transferId, approved in
            await self?.handleTransferAction(transferId: transferId, approved: approved)
        }
    }

    private func handleTransferAction(transferId: String, approved: Bool) async {
        guard currentTransferId == transferId else { return }

        if approved {
            await approve()
        } else {
            await deny()
        }
    }

    /// Handle transfer completion event
    func handleTransferCompleted(_ event: TransferCompletedEvent) {
        guard currentTransferId == event.transferId else { return }

        stopCountdownTimer()
        state = .completed(transferId: event.transferId)
        currentTransferId = nil

        #if DEBUG
        print("[TransferViewModel] Transfer completed: \(event.transferId)")
        #endif
    }

    /// Handle transfer expired event
    func handleTransferExpired(_ event: TransferExpiredEvent) {
        guard currentTransferId == event.transferId else { return }

        stopCountdownTimer()
        state = .expired(transferId: event.transferId)
        currentTransferId = nil

        #if DEBUG
        print("[TransferViewModel] Transfer expired: \(event.transferId)")
        #endif
    }

    /// Handle transfer approved event (new device receives this)
    func handleTransferApproved(_ event: TransferApprovedEvent) {
        guard currentTransferId == event.transferId else { return }

        state = .approved(transferId: event.transferId)

        #if DEBUG
        print("[TransferViewModel] Transfer was approved: \(event.transferId)")
        #endif
    }

    /// Handle transfer denied event (new device receives this)
    func handleTransferDenied(_ event: TransferDeniedEvent) {
        guard currentTransferId == event.transferId else { return }

        stopCountdownTimer()
        state = .denied(transferId: event.transferId)
        currentTransferId = nil

        #if DEBUG
        print("[TransferViewModel] Transfer was denied: \(event.transferId)")
        #endif
    }

    // MARK: - Biometric Authentication

    private func authenticateWithBiometric(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            #if DEBUG
            print("[TransferViewModel] Biometric not available: \(error?.localizedDescription ?? "unknown")")
            #endif
            // Fall back to device passcode
            return await authenticateWithPasscode(context: context, reason: reason)
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            #if DEBUG
            print("[TransferViewModel] Biometric auth error: \(error)")
            #endif
            return false
        }
    }

    private func authenticateWithPasscode(context: LAContext, reason: String) async -> Bool {
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            #if DEBUG
            print("[TransferViewModel] Passcode auth error: \(error)")
            #endif
            return false
        }
    }

    // MARK: - Timer

    private func startCountdownTimer(until expiresAt: Date) {
        stopCountdownTimer()

        timeRemaining = expiresAt.timeIntervalSinceNow

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }

                self.timeRemaining = expiresAt.timeIntervalSinceNow

                if self.timeRemaining <= 0 {
                    self.handleTimerExpired()
                }
            }
    }

    private func stopCountdownTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
        timeRemaining = 0
    }

    private func handleTimerExpired() {
        stopCountdownTimer()

        switch state {
        case .waitingForApproval(let transferId, _):
            state = .expired(transferId: transferId)
            currentTransferId = nil
        case .pendingApproval(let request):
            state = .expired(transferId: request.transferId)
            currentTransferId = nil
        default:
            break
        }
    }

    // MARK: - Reset

    /// Reset to idle state
    func reset() {
        stopCountdownTimer()
        state = .idle
        currentTransferId = nil
        isLoading = false
    }
}

// MARK: - Time Formatting

extension TransferViewModel {

    /// Formatted time remaining string (MM:SS)
    var formattedTimeRemaining: String {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Whether time remaining is in warning zone (< 2 minutes)
    var isTimeWarning: Bool {
        timeRemaining > 0 && timeRemaining < TransferTimeout.warningThreshold
    }
}
