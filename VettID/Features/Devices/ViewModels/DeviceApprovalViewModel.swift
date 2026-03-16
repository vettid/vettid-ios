import Foundation
import Combine

/// ViewModel for approving or denying a device connection request
@MainActor
final class DeviceApprovalViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DeviceApprovalState = .loading
    @Published private(set) var elapsedSeconds: Int = 0

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal State

    private var elapsedTimer: AnyCancellable?
    private var timeoutTimer: AnyCancellable?
    private var startTime: Date?
    private var listeningTask: Task<Void, Never>?

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Load Pending Approval

    /// Listen for pending device approval requests from the vault
    func loadPendingApproval() {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .loading

        listeningTask?.cancel()
        listeningTask = Task { [weak self] in
            for await request in client.deviceApprovalRequests {
                guard let self = self, !Task.isCancelled else { break }

                let info = DeviceApprovalInfo(from: request)
                self.state = .ready(info)
                self.startElapsedTimer()
                self.startTimeoutTimer()

                #if DEBUG
                print("[DeviceApproval] Received approval request: \(request.requestId)")
                #endif

                // Only handle the first request, then stop listening
                break
            }
        }
    }

    /// Set a specific approval request directly (e.g., from a notification)
    func setApprovalRequest(_ request: DeviceApprovalRequest) {
        let info = DeviceApprovalInfo(from: request)
        state = .ready(info)
        startElapsedTimer()
        startTimeoutTimer()
    }

    // MARK: - Approve

    /// Approve the device connection request
    func approve(requestId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .processingApproval

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.approval",
                payload: [
                    "request_id": AnyCodableValue(requestId),
                    "approved": AnyCodableValue(true)
                ],
                timeout: 30
            )

            if response.success {
                stopTimers()
                state = .approved

                #if DEBUG
                print("[DeviceApproval] Request approved: \(requestId)")
                #endif
            } else {
                state = .error(response.error ?? "Failed to approve request")
            }

        } catch {
            state = .error(error.localizedDescription)

            #if DEBUG
            print("[DeviceApproval] Approve failed: \(error)")
            #endif
        }
    }

    // MARK: - Deny

    /// Deny the device connection request
    func deny(requestId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .processingDenial

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.approval",
                payload: [
                    "request_id": AnyCodableValue(requestId),
                    "approved": AnyCodableValue(false)
                ],
                timeout: 30
            )

            if response.success {
                stopTimers()
                state = .denied

                #if DEBUG
                print("[DeviceApproval] Request denied: \(requestId)")
                #endif
            } else {
                state = .error(response.error ?? "Failed to deny request")
            }

        } catch {
            state = .error(error.localizedDescription)

            #if DEBUG
            print("[DeviceApproval] Deny failed: \(error)")
            #endif
        }
    }

    // MARK: - Timers

    private func startElapsedTimer() {
        stopElapsedTimer()

        startTime = Date()
        elapsedSeconds = 0

        elapsedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let start = self.startTime else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
    }

    private func startTimeoutTimer() {
        stopTimeoutTimer()

        timeoutTimer = Timer.publish(
            every: DeviceConstants.approvalTimeout,
            on: .main,
            in: .common
        )
        .autoconnect()
        .first()
        .sink { [weak self] _ in
            guard let self = self else { return }
            self.handleTimeout()
        }
    }

    private func handleTimeout() {
        stopTimers()
        state = .timeout

        #if DEBUG
        print("[DeviceApproval] Approval request timed out")
        #endif
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
    }

    private func stopTimers() {
        stopElapsedTimer()
        stopTimeoutTimer()
    }

    // MARK: - Computed Properties

    /// Formatted elapsed time string (M:SS)
    var formattedElapsedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Remaining seconds before timeout
    var remainingSeconds: Int {
        max(0, Int(DeviceConstants.approvalTimeout) - elapsedSeconds)
    }

    /// Whether nearing timeout (under 30 seconds remaining)
    var isNearingTimeout: Bool {
        remainingSeconds > 0 && remainingSeconds < 30
    }

    // MARK: - Reset

    /// Reset to initial state
    func reset() {
        stopTimers()
        listeningTask?.cancel()
        listeningTask = nil
        state = .loading
        elapsedSeconds = 0
        startTime = nil
    }

    // MARK: - Cleanup

    deinit {
        elapsedTimer?.cancel()
        timeoutTimer?.cancel()
        listeningTask?.cancel()
    }
}
