import Foundation
import VettIDVault

/// The bookkeeping of the sessions' reads and events, in the order they reach the app (``ApprovalsManager``'s
/// `sessionBook`).
final class DeviceSessionBook {
    /// A screen asked for the sessions: a `device.session` event and a read of the lists (after an unlock, or when a hold
    /// lifts) read them again. Kept across a hold, so a screen left open learns the sessions again when it lifts.
    var wanted = false
    /// Bumped at each read's start and each event, so that an answer and the events are put in the order they came.
    var tick = 0
    /// The start of the newest read applied: an answer to a read begun before it is dropped.
    var lastRead = 0
    /// The events applied, with their tick, while a read may be on its way: applied again over a read begun before them.
    var events: [Event] = []

    struct Event {
        var tick: Int
        var deviceID: String
        var end: Date?
    }

    static let maxEvents = 64
}

/// Desktops' and agents' access sessions, for a renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3): a session request
/// from a device whose session has not expired. `device.session.pending` does not carry the session's end: it is the
/// device's `session_expires_at` of `device.list` (§10.3), read when the request is shown, or a later `sync.event`
/// `device.session` (§10.1). "Deny and end access now" ends the session with `device.session.end` alone.
extension ApprovalsManager {
    /// Reads `device.list` for the sessions' ends. A read that fails changes nothing: until one is answered, no request is
    /// a renewal. From now on a `device.session` event, and every read of the lists, reads it again.
    public func readDeviceSessions() async throws {
        sessionBook.wanted = true
        try await readDeviceSessions(quietly: false)
    }

    /// The sessions are read again, quietly, when a screen asked for them (``readDeviceSessions()``).
    func rereadDeviceSessions() {
        guard sessionBook.wanted else { return }
        Task { [weak self] in try? await self?.readDeviceSessions(quietly: true) }
    }

    func readDeviceSessions(quietly: Bool) async throws {
        let g = generation
        sessionBook.tick += 1
        let start = sessionBook.tick
        let list = try await guarded { try await (quietly ? quietOps() : ops()).deviceList() }
        // Dropped meanwhile (a lock or a hold), or a read begun later already answered: this answer is not published.
        guard g == generation, start > sessionBook.lastRead else { return }
        var ends: [String: Date] = [:]
        for d in list {
            if let end = ApprovalParser.instant(d.sessionExpiresAt) { ends[d.id] = end }
        }
        // An event that came after this read began is newer than what it read (chosen; not in the spec: the vault's
        // answer may have been made before the event's change).
        for e in sessionBook.events where e.tick > start {
            if let end = e.end { ends[e.deviceID] = end } else { ends.removeValue(forKey: e.deviceID) }
        }
        sessionBook.lastRead = start
        sessionBook.events.removeAll { $0.tick <= start }
        deviceSessions = ends
        deviceSessionsKnown = true
        deviceSessionReads += 1
        deviceSessionsVersion += 1
    }

    /// `sync.event` `device.session` (0.77.0 §6.8): the device's current session ends at [expiresAt], or it has none. The
    /// list is read again when a screen asked for it, so that one whose read failed learns the rest (chosen; not in the
    /// spec).
    func deviceSessionEvent(_ deviceID: String, expiresAt: Date?) {
        sessionBook.tick += 1
        sessionBook.events.append(DeviceSessionBook.Event(tick: sessionBook.tick, deviceID: deviceID, end: expiresAt))
        if sessionBook.events.count > DeviceSessionBook.maxEvents { sessionBook.events.removeFirst() }
        if let expiresAt { deviceSessions[deviceID] = expiresAt } else { deviceSessions.removeValue(forKey: deviceID) }
        deviceSessionsVersion += 1
        rereadDeviceSessions()
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
        deviceSessionEvent(deviceID, expiresAt: nil)
        dropAsks(ofDevice: deviceID)
    }

    /// Whether the vault is held (§3.6.3): nothing is ended while it is.
    public var vaultHeld: Bool { held() }

    /// What the vault said of the sessions goes with the vault (a lock, a hold): nothing is known until it is read again.
    /// Whether a screen asked stays, so the read when the hold lifts includes them.
    func forgetDeviceSessions() {
        deviceSessions = [:]
        deviceSessionsKnown = false
        sessionBook.events = []
        deviceSessionsVersion += 1
    }
}
