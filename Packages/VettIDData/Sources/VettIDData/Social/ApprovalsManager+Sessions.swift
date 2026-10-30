import Foundation
import VettIDVault

/// Desktops' and agents' access sessions, for a renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3): a session request
/// from a device whose session has not expired. `device.session.pending` does not carry the session's end: it is the
/// device's `session_expires_at` of `device.list` (§10.3), read when the request is shown, or a later `sync.event`
/// `device.session` (§10.1). "Deny and end access now" ends the session with `device.session.end` alone.
extension ApprovalsManager {
    /// Reads `device.list` for the sessions' ends. A read that fails changes nothing: until one is answered (or a
    /// device's session event comes), no request is a renewal. A `device.session` event reads the list again from now.
    public func readDeviceSessions() async throws {
        deviceSessionsWanted = true
        try await readDeviceSessions(quietly: false)
    }

    func readDeviceSessions(quietly: Bool) async throws {
        let g = generation
        let list = try await guarded { try await (quietly ? quietOps() : ops()).deviceList() }
        // Dropped meanwhile (a lock or a hold): what was read is not published.
        guard g == generation else { return }
        var ends: [String: Date] = [:]
        for d in list {
            if let end = ApprovalParser.instant(d.sessionExpiresAt) { ends[d.id] = end }
        }
        deviceSessions = ends
        deviceSessionsKnown = true
        deviceSessionReads += 1
        deviceSessionsVersion += 1
    }

    /// `sync.event` `device.session` (0.77.0 §6.8): the device's current session ends at [expiresAt], or it has none. The
    /// list is read again when a screen asked for it, so that one whose read failed learns the rest (chosen; not in the
    /// spec).
    func deviceSessionEvent(_ deviceID: String, expiresAt: Date?) {
        if let expiresAt { deviceSessions[deviceID] = expiresAt } else { deviceSessions.removeValue(forKey: deviceID) }
        deviceSessionsVersion += 1
        guard deviceSessionsWanted else { return }
        Task { [weak self] in try? await self?.readDeviceSessions(quietly: true) }
    }

    /// "Deny and end access now" (0.78.0 §6.8 step 3): `device.session.end{device_id}` alone, never a deny as well: the
    /// end drops the pending request and is audited and synced once, as an end. The vault tells the member's other devices
    /// only, so this app drops the device's asks itself (``dropAsks(ofDevice:)``). A failure leaves everything as it was,
    /// and the list is read again to learn whether the device still has a session.
    public func endDeviceAccess(_ deviceID: String) async throws {
        do {
            try await guarded { try await ops().sessionEnd(deviceID: deviceID) }
        } catch {
            Task { [weak self] in try? await self?.readDeviceSessions(quietly: true) }
            throw error
        }
        deviceSessions.removeValue(forKey: deviceID)
        deviceSessionsVersion += 1
        dropAsks(ofDevice: deviceID)
    }

    /// Whether the vault is held (§3.6.3): a confirmation ends nothing while it is.
    public var vaultHeld: Bool { held() }

    /// What the vault said of the sessions goes with the vault (a lock, a hold): nothing is known until it is read again.
    func forgetDeviceSessions() {
        deviceSessions = [:]
        deviceSessionsKnown = false
        deviceSessionsWanted = false
        deviceSessionsVersion += 1
    }
}
