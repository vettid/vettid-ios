import Foundation
import Combine

/// ViewModel for pairing a new device
@MainActor
final class DevicePairingViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DevicePairingState = .idle
    @Published private(set) var remainingSeconds: Int = 0

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal State

    private var countdownTimer: AnyCancellable?
    private var expiresAt: Date?

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Create Invitation

    /// Create a device pairing invitation code
    func createInvitation() async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .creating

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.create-invite",
                timeout: 30
            )

            guard response.success else {
                state = .error(response.error ?? "Failed to create invitation")
                return
            }

            guard let inviteCode = response.getString("invite_code") else {
                state = .error("No invitation code returned")
                return
            }

            // Parse expiration - default to 5 minutes if not provided
            let expirationDate: Date
            if let expiresString = response.getString("expires_at") {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                expirationDate = formatter.date(from: expiresString)
                    ?? fallback.date(from: expiresString)
                    ?? Date().addingTimeInterval(DeviceConstants.pairingCodeExpiration)
            } else {
                expirationDate = Date().addingTimeInterval(DeviceConstants.pairingCodeExpiration)
            }

            self.expiresAt = expirationDate
            state = .showingCode(inviteCode: inviteCode, expiresAt: expirationDate)
            startCountdown(until: expirationDate)

            #if DEBUG
            print("[DevicePairing] Invitation created, code: \(inviteCode)")
            #endif

        } catch {
            state = .error(error.localizedDescription)

            #if DEBUG
            print("[DevicePairing] Create invitation failed: \(error)")
            #endif
        }
    }

    // MARK: - Cancel

    /// Cancel the current pairing process
    func cancel() {
        stopCountdown()
        state = .idle
        expiresAt = nil
    }

    /// Reset to idle state
    func reset() {
        stopCountdown()
        state = .idle
        expiresAt = nil
        remainingSeconds = 0
    }

    // MARK: - Countdown Timer

    private func startCountdown(until expiration: Date) {
        stopCountdown()

        remainingSeconds = max(0, Int(expiration.timeIntervalSinceNow))

        countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }

                let remaining = Int(expiration.timeIntervalSinceNow)

                if remaining <= 0 {
                    self.handleTimeout()
                } else {
                    self.remainingSeconds = remaining
                }
            }
    }

    private func stopCountdown() {
        countdownTimer?.cancel()
        countdownTimer = nil
    }

    private func handleTimeout() {
        stopCountdown()
        remainingSeconds = 0
        state = .timeout
        expiresAt = nil

        #if DEBUG
        print("[DevicePairing] Pairing code expired")
        #endif
    }

    // MARK: - Computed Properties

    /// Formatted countdown string (MM:SS)
    var formattedCountdown: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Whether the countdown is in warning zone (under 60 seconds)
    var isCountdownWarning: Bool {
        remainingSeconds > 0 && remainingSeconds < 60
    }

    // MARK: - Cleanup

    deinit {
        countdownTimer?.cancel()
    }
}
