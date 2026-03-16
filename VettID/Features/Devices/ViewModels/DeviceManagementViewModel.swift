import Foundation
import Combine

/// ViewModel for managing connected devices
@MainActor
final class DeviceManagementViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DeviceManagementState = .loading
    @Published private(set) var isRevoking = false
    @Published private(set) var isExtending = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Internal State

    private var heartbeatTimer: AnyCancellable?
    private var devices: [ConnectedDevice] = []

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Load Devices

    /// Load the list of connected devices from the vault
    func loadDevices() async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .loading

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.list",
                timeout: 30
            )

            guard response.success else {
                state = .error(response.error ?? "Failed to load devices")
                return
            }

            // Parse the devices array from the response
            let deviceDicts = response.getArray("devices") ?? []
            devices = deviceDicts.compactMap { ConnectedDevice.from(dict: $0) }

            // Sort by last active, most recent first
            devices.sort { $0.lastActiveAt > $1.lastActiveAt }

            if devices.isEmpty {
                state = .empty
            } else {
                state = .loaded(devices)
            }

            // Start heartbeat after successful load
            startHeartbeat()

        } catch {
            state = .error(error.localizedDescription)

            #if DEBUG
            print("[DeviceManagement] Failed to load devices: \(error)")
            #endif
        }
    }

    /// Refresh the device list
    func refresh() async {
        await loadDevices()
    }

    // MARK: - Revoke Device

    /// Revoke a connected device
    func revokeDevice(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            errorMessage = "Not connected to vault"
            return
        }

        isRevoking = true

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.revoke",
                payload: [
                    "connection_id": AnyCodableValue(connectionId)
                ],
                timeout: 30
            )

            if response.success {
                // Remove from local list
                devices.removeAll { $0.connectionId == connectionId }

                if devices.isEmpty {
                    state = .empty
                } else {
                    state = .loaded(devices)
                }

                #if DEBUG
                print("[DeviceManagement] Device revoked: \(connectionId)")
                #endif
            } else {
                errorMessage = response.error ?? "Failed to revoke device"
            }

        } catch {
            errorMessage = error.localizedDescription

            #if DEBUG
            print("[DeviceManagement] Revoke failed: \(error)")
            #endif
        }

        isRevoking = false
    }

    // MARK: - Extend Session

    /// Extend a device's session
    func extendSession(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            errorMessage = "Not connected to vault"
            return
        }

        isExtending = true

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.device.extend-session",
                payload: [
                    "connection_id": AnyCodableValue(connectionId)
                ],
                timeout: 30
            )

            if response.success {
                // Refresh to get updated session info
                await loadDevices()

                #if DEBUG
                print("[DeviceManagement] Session extended: \(connectionId)")
                #endif
            } else {
                errorMessage = response.error ?? "Failed to extend session"
            }

        } catch {
            errorMessage = error.localizedDescription

            #if DEBUG
            print("[DeviceManagement] Extend session failed: \(error)")
            #endif
        }

        isExtending = false
    }

    // MARK: - Heartbeat

    /// Start periodic heartbeat to keep device connection alive
    private func startHeartbeat() {
        stopHeartbeat()

        heartbeatTimer = Timer.publish(
            every: DeviceConstants.heartbeatInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { [weak self] in
                await self?.sendHeartbeat()
            }
        }
    }

    /// Stop the heartbeat timer
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Send a single heartbeat to the vault
    private func sendHeartbeat() async {
        guard let client = ownerSpaceClient else { return }

        do {
            let _ = try await client.sendAndAwaitResponse(
                "connection.device.heartbeat",
                timeout: 10
            )

            #if DEBUG
            print("[DeviceManagement] Heartbeat sent")
            #endif
        } catch {
            #if DEBUG
            print("[DeviceManagement] Heartbeat failed: \(error)")
            #endif
        }
    }

    // MARK: - Cleanup

    deinit {
        heartbeatTimer?.cancel()
    }
}
