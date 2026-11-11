import Foundation
import VettIDVault

// The member's devices and agents (VAULT-MESSAGING §10.3, §10.11; ANDROID-PLAN 0.1.53 AA1) and pairing an agent or a desktop (AA2,
// §6.7, §10.3) over this manager's session, with
// the rules of the feed (``VaultManager+Activity``): a read nobody asked for never opens a session, and what was read is dropped
// when the vault is no longer open or is held (``DevicesManager/clear()``). Mirrors the devices part of vettid-android
// `VaultManager`.
extension VaultManager {
    static func devicesManager(_ manager: VaultManager) -> DevicesManager {
        let ref = ManagerRef()
        ref.manager = manager
        return DevicesManager(
            ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            selfID: { ref.manager?.session?.device.deviceID },
            // The vault tells the member's other devices only (§10.1): this app drops the device's asks itself, and its session.
            onDeviceGone: { id in
                guard let approvals = ref.manager?.approvals else { return }
                approvals.dropAsks(ofDevice: id)
                approvals.deviceSessionEvent(id, expiresAt: nil)
            },
            // The pairing in progress goes wherever the list does (lock, hold, wipe, deletion).
            onClear: { ref.manager?.pairing.clear() }
        )
    }

    /// Pairing an agent or a desktop: the code, the comparison, the approval. Memory only, cleared with ``devices``; its events
    /// come in ``activityEvent(_:)``, only while the vault takes events.
    static func pairingManager(_ manager: VaultManager) -> PairingManager {
        let ref = ManagerRef()
        ref.manager = manager
        return PairingManager(
            ops: { VaultPairingOps(api: try await memberApi(ref)) },
            knownDeviceIDs: {
                guard let d = ref.manager?.devices, d.load == .loaded else { return nil }
                return Set(d.devices.map(\.id))
            },
            readDevices: {
                guard let d = ref.manager?.devices else { return [] }
                try await d.refresh()
                return d.devices
            },
            onPaired: { ref.manager?.devices.refreshQuietly() }
        )
    }
}
