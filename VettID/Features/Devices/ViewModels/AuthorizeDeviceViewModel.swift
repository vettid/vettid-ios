import Foundation
import Combine

/// Stage-2 authorization: the user has a pending desktop and scans
/// its QR (token + connection_id). They pick a session duration and
/// device name, then approve — which submits `device.authorize-session`
/// to the vault. Mirrors Android `AuthorizeDeviceViewModel`.
@MainActor
final class AuthorizeDeviceViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AuthorizeDeviceState = .scanning

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal State

    /// Last seen pending-authorization notification matching our
    /// connection_id. Populated by the devicePendingAuth listener so a
    /// QR scan can immediately hand off into `.ready` with the real
    /// fingerprint card. Nil means "scanned QR before notification
    /// arrived" — we fall through to a synthesized PendingDeviceInfo.
    private var pendingForConnection: PendingDeviceInfo?

    /// The connection_id the user started this flow for (from the
    /// pairing screen's hand-off). Used to filter the
    /// devicePendingAuth stream.
    private var connectionIdFilter: String?

    private var listenerTask: Task<Void, Never>?

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Pending hand-off from pairing

    /// Called from the view's `.onAppear`. Filters incoming
    /// `devicePendingAuth` notifications to the desktop the user is
    /// authorizing right now. Idempotent across re-appears.
    func setPendingFromNotification(connectionId: String) {
        connectionIdFilter = connectionId
        listenerTask?.cancel()
        guard let client = ownerSpaceClient else { return }
        client.startDeviceEventSubscription()
        listenerTask = Task { [weak self] in
            for await notification in client.devicePendingAuth {
                guard let self = self else { return }
                await MainActor.run {
                    guard notification.connectionId == self.connectionIdFilter else { return }
                    self.pendingForConnection = PendingDeviceInfo.from(notification: notification)
                    // If the user already scanned the QR (we're in
                    // .ready with a synthesized info), upgrade the
                    // displayed info now that the real one arrived.
                    if case .ready(let scanned, _, let deviceName, let durationSeconds) = self.state,
                       let info = self.pendingForConnection {
                        self.state = .ready(
                            scanned: scanned,
                            info: info,
                            deviceName: deviceName,
                            durationSeconds: durationSeconds
                        )
                    }
                }
            }
        }
    }

    // MARK: - QR scan

    /// User scanned a QR — validate the payload and transition to
    /// `.ready` with the form. The vault rejects on token mismatch,
    /// so a synthesised PendingDeviceInfo (when the notification is
    /// late) is safe; the security boundary is the approval_token.
    func onQrScanned(_ qrText: String) {
        guard let parsed = ScannedDeviceAuthQr.parse(qrText) else {
            state = .error("Invalid QR code — try again")
            return
        }

        if let pending = pendingForConnection, pending.connectionId != parsed.connectionId {
            state = .error("QR doesn't match the device waiting for authorization")
            return
        }

        let info = pendingForConnection ?? PendingDeviceInfo.fallback(connectionId: parsed.connectionId)
        let initialName = info.hostname.isEmpty ? "Desktop" : info.hostname
        state = .ready(
            scanned: parsed,
            info: info,
            deviceName: initialName,
            durationSeconds: info.defaultDurationSeconds
        )
    }

    // MARK: - Form mutations

    func updateDeviceName(_ name: String) {
        guard case .ready(let scanned, let info, _, let durationSeconds) = state else { return }
        state = .ready(scanned: scanned, info: info, deviceName: name, durationSeconds: durationSeconds)
    }

    func updateDuration(_ seconds: Int) {
        guard case .ready(let scanned, let info, let deviceName, _) = state else { return }
        let capped = min(max(seconds, 60), info.maxDurationSeconds)
        state = .ready(scanned: scanned, info: info, deviceName: deviceName, durationSeconds: capped)
    }

    // MARK: - Approve / ConfirmReplace

    func approve() async {
        guard case .ready(let scanned, let info, let deviceName, let durationSeconds) = state else { return }
        await submitAuthorize(
            scanned: scanned,
            info: info,
            deviceName: deviceName,
            durationSeconds: durationSeconds,
            forceReplace: false
        )
    }

    /// User accepted the "end existing session and continue" prompt.
    /// Re-fires authorize-session with force_replace=true.
    func confirmReplace() async {
        guard case .confirmReplace(let scanned, let info, let deviceName, let durationSeconds, _) = state else {
            return
        }
        await submitAuthorize(
            scanned: scanned,
            info: info,
            deviceName: deviceName,
            durationSeconds: durationSeconds,
            forceReplace: true
        )
    }

    /// User dismissed the ConfirmReplace prompt — return to .ready.
    func cancelReplace() {
        guard case .confirmReplace(let scanned, let info, let deviceName, let durationSeconds, _) = state else {
            return
        }
        state = .ready(scanned: scanned, info: info, deviceName: deviceName, durationSeconds: durationSeconds)
    }

    func reset() {
        state = .scanning
    }

    // MARK: - Network round-trip

    /// Submit `device.authorize-session`. Tolerates the desktop's
    /// Stage-1 connect taking several seconds: a `"pending authorization"`
    /// error means request-session hasn't landed yet — retry rather
    /// than failing the pair. Mirrors Android's `submitAuthorize`.
    private func submitAuthorize(
        scanned: ScannedDeviceAuthQr,
        info: PendingDeviceInfo,
        deviceName: String,
        durationSeconds: Int,
        forceReplace: Bool
    ) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .submitting

        let deadline = Date().addingTimeInterval(45)  // AUTHORIZE_RETRY_WINDOW_MS = 45s
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(scanned.connectionId),
            "approval_token": AnyCodableValue(scanned.approvalToken),
            "device_name": AnyCodableValue(deviceName.isEmpty ? "Desktop" : deviceName),
            "duration_seconds": AnyCodableValue(durationSeconds)
        ]
        if forceReplace { payload["force_replace"] = AnyCodableValue(true) }

        while true {
            do {
                let response = try await client.sendAndAwaitResponse(
                    "device.authorize-session",
                    payload: payload,
                    timeout: 20
                )

                if response.success {
                    state = .done
                    return
                }

                // Retry the "desktop not ready yet" case — Stage-1
                // request-session can lag the user's QR scan.
                let errMsg = response.error ?? ""
                let isPendingAuth = errMsg.range(of: "pending authorization", options: .caseInsensitive) != nil
                if isPendingAuth && response.errorCode != "existing_session_active" && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                if response.errorCode == "existing_session_active" {
                    let existing = Self.parseExistingDevices(from: response.raw)
                    state = .confirmReplace(
                        scanned: scanned,
                        info: info,
                        deviceName: deviceName,
                        durationSeconds: durationSeconds,
                        existingDevices: existing
                    )
                    return
                }

                state = .error(errMsg.isEmpty ? "Authorization failed" : errMsg)
                return
            } catch {
                state = .error(error.localizedDescription)
                return
            }
        }
    }

    private static func parseExistingDevices(from raw: [String: Any]) -> [ExistingDeviceSummary] {
        let arr = (raw["existing_devices"] as? [[String: Any]])
            ?? ((raw["extra"] as? [String: Any])?["existing_devices"] as? [[String: Any]])
            ?? []
        return arr.compactMap { item in
            guard let connId = item["connection_id"] as? String else { return nil }
            return ExistingDeviceSummary(
                connectionId: connId,
                deviceName: (item["device_name"] as? String) ?? "",
                lastActiveAt: (item["last_active_at"] as? Int) ?? 0,
                expiresAt: (item["expires_at"] as? Int) ?? 0
            )
        }
    }

    deinit {
        listenerTask?.cancel()
    }
}
