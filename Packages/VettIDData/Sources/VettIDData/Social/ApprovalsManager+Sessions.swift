import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// A screen's ask for the desktops' and agents' sessions (``ApprovalsRepository/askDeviceSessions()``), given back when it
/// is let go.
public final class DeviceSessionsAsk: Sendable {
    private let release: @Sendable () -> Void

    public init(_ release: @escaping @Sendable () -> Void) { self.release = release }

    deinit { release() }
}

/// The desktops' and agents' access sessions as the vault last said, memory only and dropped with the vault, and the
/// bookkeeping of their reads and events, in the order they reach the app (``ApprovalsManager``'s `sessionBook`;
/// ``ApprovalsRepository`` says what each one is). Observed, so a screen follows them.
@MainActor
@Observable
final class DeviceSessionBook {
    var sessions: [String: Date] = [:]
    var known = false
    var reads = 0
    var version = 0
    /// Whether the vault is held (§3.6.3): nothing is ended while it is.
    @ObservationIgnored var held: @MainActor () -> Bool = { false }
    /// The screens asking for the sessions (``DeviceSessionsAsk``): while one is open, a `device.session` event and a read
    /// of the lists (an unlock, a hold that lifts) read them again. A hold keeps them (a screen that outlives it learns the
    /// sessions again when it lifts); a lock ends them all (``ApprovalsManager/vaultClosed()``).
    @ObservationIgnored var askers = 0
    /// Bumped at each lock: a screen's ask from before it is not given back twice.
    @ObservationIgnored var epoch = 0
    /// Bumped at each read's start and each event, so that an answer and the events are put in the order they came.
    @ObservationIgnored var tick = 0
    /// The start of the newest read applied: an answer to a read begun before it is dropped.
    @ObservationIgnored var lastRead = 0
    /// The events applied, with their tick, while a read may be on its way: applied again over a read begun before them.
    @ObservationIgnored var events: [Event] = []

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
    public var deviceSessions: [String: Date] { sessionBook.sessions }
    public var deviceSessionsKnown: Bool { sessionBook.known }
    public var deviceSessionReads: Int { sessionBook.reads }
    public var deviceSessionsVersion: Int { sessionBook.version }

    /// Reads `device.list` for the sessions' ends. A read that fails changes nothing: until one is answered, no request is
    /// a renewal.
    public func readDeviceSessions() async throws {
        try await readDeviceSessions(quietly: false)
    }

    /// A screen asks for the sessions while it holds the answer: a `device.session` event, and every read of the lists,
    /// read them again until it is let go (when the screen goes) or the vault locks.
    public func askDeviceSessions() -> DeviceSessionsAsk {
        sessionBook.askers += 1
        let epoch = sessionBook.epoch
        return DeviceSessionsAsk { [weak self] in Task { @MainActor in self?.stopAsking(epoch) } }
    }

    private func stopAsking(_ epoch: Int) {
        guard epoch == sessionBook.epoch, sessionBook.askers > 0 else { return }
        sessionBook.askers -= 1
    }

    /// The vault locked: every screen's ask ends with it.
    public func vaultClosed() {
        sessionBook.askers = 0
        sessionBook.epoch += 1
    }

    /// The sessions are read again, quietly, while a screen asks for them (``askDeviceSessions()``).
    func rereadDeviceSessions() {
        guard sessionBook.askers > 0 else { return }
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
        sessionBook.sessions = ends
        sessionBook.known = true
        sessionBook.reads += 1
        sessionBook.version += 1
    }

    /// `sync.event` `device.session` (0.77.0 §6.8): what it says of the device's session holds whatever the list says of
    /// its request, so it is applied before the list's cut.
    func deviceSessionEvent(_ o: JsonObject) {
        guard let device = VaultJSON.string(o, "device_id") else { return }
        deviceSessionEvent(device, expiresAt: ApprovalParser.instant(VaultJSON.string(o, "expires_at")))
    }

    /// The device's current session ends at [expiresAt], or it has none. The list is read again when a screen asked for it,
    /// so that one whose read failed learns the rest (chosen; not in the spec).
    func deviceSessionEvent(_ deviceID: String, expiresAt: Date?) {
        sessionBook.tick += 1
        sessionBook.events.append(DeviceSessionBook.Event(tick: sessionBook.tick, deviceID: deviceID, end: expiresAt))
        if sessionBook.events.count > DeviceSessionBook.maxEvents { sessionBook.events.removeFirst() }
        if let expiresAt { sessionBook.sessions[deviceID] = expiresAt } else { sessionBook.sessions.removeValue(forKey: deviceID) }
        sessionBook.version += 1
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
    public var vaultHeld: Bool { sessionBook.held() }

    /// What the vault said of the sessions goes with the vault (a lock, a hold): nothing is known until it is read again.
    /// The screens asking stay through a hold; a lock ends them (``vaultClosed()``).
    func forgetDeviceSessions() {
        sessionBook.sessions = [:]
        sessionBook.known = false
        sessionBook.events = []
        sessionBook.version += 1
    }
}
