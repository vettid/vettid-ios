import Foundation
import Combine

/// ViewModel for pairing a new device
@MainActor
final class DevicePairingViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DevicePairingState = .idle
    @Published private(set) var remainingSeconds: Int = 0
    /// Area B — set when the vault publishes `forApp.device.pending-authorization`
    /// for the in-flight invite. Drives the pairing view's auto-advance to
    /// the Authorize step. Mirrors Android `DevicePairingState.DevicePending`.
    @Published private(set) var pendingAuthorization: DevicePendingAuthNotification?

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal State

    private var countdownTimer: AnyCancellable?
    private var expiresAt: Date?

    /// connection_id returned by `device.create-invite`. Kept on the VM
    /// (not in `state`) so cancel/timeout paths can fire `device.cancel-invite`
    /// without leaking it to the UI. Cleared the moment the invite is no
    /// longer cancellable (DevicePending onwards) or after a successful cancel.
    private var pendingConnectionId: String?

    /// Set true the instant the screen advances to the Authorize step.
    /// `cancelOnDeinit` consults it so the still-live invite isn't torn
    /// down by the view-model's deallocation when nav pops the pairing
    /// screen to push the authorize one. Mirrors Android's
    /// `advancingToAuthorize` guard (commit 649b2a3).
    private var advancingToAuthorize = false

    /// Long-lived observer for `devicePendingAuth`. Started by the view
    /// on appear (idempotent), cancelled on cleanup.
    private var pendingAuthListenerTask: Task<Void, Never>?

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
                "device.create-invite",
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

            // Remember the connection_id so cancel / timeout can tear down
            // the in-flight invite vault-side via device.cancel-invite.
            pendingConnectionId = response.getString("connection_id")

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
            startPendingAuthListener()

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
        // Fire-and-forget the vault-side teardown; UI flips to idle right
        // away. If the publish fails the invite ages out vault-side.
        cancelInviteOnVault()
        state = .idle
        expiresAt = nil
    }

    /// Reset to idle state
    func reset() {
        stopCountdown()
        cancelInviteOnVault()
        state = .idle
        expiresAt = nil
        remainingSeconds = 0
        pendingAuthorization = nil
    }

    // MARK: - Area B — Authorize-step hand-off

    /// connection_id of the in-flight invite, if any. Surfaced to the
    /// view so a manual "Scan Desktop QR" escape button can navigate to
    /// AuthorizeDeviceView even when the pending-auth notification is
    /// late / missed.
    func pendingConnectionIdValue() -> String? { pendingConnectionId }

    /// Called by the view right before it navigates to the authorize
    /// step. Tells the cleanup path NOT to cancel the invite — the
    /// pairing is continuing, not being abandoned. Mirrors Android
    /// `DevicePairingViewModel.markAdvancingToAuthorize` (commit 649b2a3).
    func markAdvancingToAuthorize() {
        advancingToAuthorize = true
        // Once the user is on the authorize step the invite is no
        // longer cancellable (the vault has transitioned the connection
        // out of pending_pairing); don't try to cancel it later.
        pendingConnectionId = nil
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
        // Code aged out without being claimed. Tear down the vault-side
        // pending connection so the feed doesn't keep showing it as a
        // standalone card.
        cancelInviteOnVault()
        state = .timeout
        expiresAt = nil

        #if DEBUG
        print("[DevicePairing] Pairing code expired")
        #endif
    }

    /// Area B — listen for the vault's `forApp.device.pending-authorization`
    /// notification. Idempotent. Only transitions if we're currently in
    /// ShowingCode (a stale notification shouldn't yank a fresh-start
    /// session into pending unexpectedly).
    private func startPendingAuthListener() {
        pendingAuthListenerTask?.cancel()
        guard let client = ownerSpaceClient else { return }
        client.startDeviceEventSubscription()
        pendingAuthListenerTask = Task { [weak self] in
            for await notif in client.devicePendingAuth {
                guard let self = self else { return }
                await MainActor.run {
                    guard case .showingCode = self.state else { return }
                    guard notif.connectionId == self.pendingConnectionId else { return }
                    self.stopCountdown()
                    self.pendingAuthorization = notif
                    // The desktop has claimed the invite — Stage-1 is
                    // done, the device-pending state owns the
                    // lifecycle now. Suppress cancel-on-deinit.
                    self.pendingConnectionId = nil
                }
            }
        }
    }

    /// Fire-and-forget `device.cancel-invite` for the in-flight invite,
    /// if any. Used by Cancel / Back / Timeout. Safe to call multiple
    /// times — the connection_id is nilled after the first call.
    private func cancelInviteOnVault() {
        guard let connectionId = pendingConnectionId, let client = ownerSpaceClient else {
            return
        }
        pendingConnectionId = nil
        Task {
            do {
                _ = try await client.sendAndAwaitResponse(
                    "device.cancel-invite",
                    payload: ["connection_id": AnyCodableValue(connectionId)],
                    timeout: 10
                )
            } catch {
                #if DEBUG
                print("[DevicePairing] device.cancel-invite failed (non-fatal): \(error)")
                #endif
            }
        }
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
        pendingAuthListenerTask?.cancel()
        // Fire vault-side teardown if the user genuinely abandoned the
        // pairing (Back, system back, process death). When the screen
        // is cleared because we advanced to the authorize step the
        // invite is still live and in use — cancelling it here would
        // make the authorize land on "no pending authorization".
        if !advancingToAuthorize, let connectionId = pendingConnectionId, let client = ownerSpaceClient {
            Task.detached {
                _ = try? await client.sendAndAwaitResponse(
                    "device.cancel-invite",
                    payload: ["connection_id": AnyCodableValue(connectionId)],
                    timeout: 10
                )
            }
        }
    }
}
