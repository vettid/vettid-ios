import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// The vault calls behind ``DevicesManager`` (§10.3, §10.11), so that it can be tested without a vault. None signs and none
/// needs the unlock window.
public protocol DevicesOps: Sendable {
    /// `device.list{}`: `{devices: [...]}`, as the vault sent it.
    func list() async throws -> JsonObject
    /// `leash.grant.list{agent_id?}`: `{grants, suspended}`.
    func grants(_ agentID: String?) async throws -> JsonObject
    func endAccess(_ deviceID: String) async throws
    func unlink(_ deviceID: String) async throws
}

extension VaultApi: DevicesOps {
    public func list() async throws -> JsonObject { try await deviceListBody() }
    public func grants(_ agentID: String?) async throws -> JsonObject { try await leashGrantList(agentID: agentID) }
    public func endAccess(_ deviceID: String) async throws { try await sessionEnd(deviceID: deviceID) }
    public func unlink(_ deviceID: String) async throws { try await deviceUnlink(deviceID) }
}

/// The member's devices and agents (ANDROID-PLAN 0.1.53 "Devices & agents", AA1; VAULT-MESSAGING §10.3). Every failure is a
/// ``VaultFailure``. Mirrors vettid-android `DevicesRepository`.
@MainActor
public protocol DevicesRepository: AnyObject, Observable, Sendable {
    /// This phone, then agents, then desktops (``DeviceWire/ordered(_:)``); empty until read, and after a lock.
    var devices: [DeviceInfo] { get }
    var load: ListLoad { get }
    /// The device the member just removed, for the list's "<name> was removed"; until ``dismissRemoved()``.
    var removed: DeviceInfo? { get }

    /// Reads the list (`device.list`, and `leash.grant.list` for the paused agents). Throws the vault's failure.
    func refresh() async throws
    /// A read in the background: at most one in flight and one queued behind it.
    func refreshQuietly()
    /// `device.session.end`: the device's access ends and its waiting requests are declined.
    func endAccess(_ deviceID: String) async throws
    /// `device.unlink`: the device loses access at once; its permissions and share rules go with it.
    func remove(_ deviceID: String) async throws
    /// The longest time, in seconds, that a service shown one of the agent's permissions may still accept it after the agent
    /// is removed: the longest `status_ttl` of its grants plus 60 s (§10.11); 0 when it has none. When the vault cannot be
    /// asked, the worst case (3,600 s plus 60 s): the text is never shorter than the truth.
    func removalBoundSeconds(_ agentID: String) async -> Int64
    func dismissRemoved()
}

/// ``DevicesRepository`` over ``DevicesOps``. The list is kept in memory only, while the vault is open (like the feed):
/// cleared on lock, on entering the hold, on a wipe, on a deletion and with the process (ANDROID-PLAN 0.1.53 AA1). It is
/// re-read after a `sync.event` of kind `device.paired`, `device.unlinked`, `device.session` or `leash.agent.suspended`
/// (``onEvent(_:)``), coalesced.
///
/// ``onDeviceGone`` runs when a device's access ended or the device was removed here: its entries leave Approvals at once
/// (the vault declines them, §6.8). Mirrors vettid-android `DevicesManager`.
@MainActor
@Observable
public final class DevicesManager: DevicesRepository {
    public private(set) var devices: [DeviceInfo] = []
    public private(set) var load = ListLoad.notLoaded
    public private(set) var removed: DeviceInfo?

    /// The calls of what the member does, and of a read nobody asked for (only over the session open now).
    @ObservationIgnored private let ops: @MainActor () async throws -> any DevicesOps
    @ObservationIgnored private let quietOps: @MainActor () throws -> any DevicesOps
    @ObservationIgnored private let selfID: @MainActor () -> String?
    @ObservationIgnored private let onDeviceGone: @MainActor (String) async throws -> Void
    @ObservationIgnored private let reads = ReadGate()
    /// Bumped by ``clear()``: a read that started before it is not applied after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued = false

    public init(
        ops: @escaping @MainActor () async throws -> any DevicesOps, quietOps: @escaping @MainActor () throws -> any DevicesOps,
        selfID: @escaping @MainActor () -> String? = { nil }, onDeviceGone: @escaping @MainActor (String) async throws -> Void = { _ in }
    ) {
        self.ops = ops
        self.quietOps = quietOps
        self.selfID = selfID
        self.onDeviceGone = onDeviceGone
    }

    /// Forgets everything: the vault locked, was held or wiped. Not loaded first, then empty, in one step: LOADED always
    /// means a list that was read (a screen that saw an empty list while LOADED would take it for a session that ended).
    public func clear() {
        generation += 1
        queued = false
        load = .notLoaded
        devices = []
        removed = nil
    }

    /// `sync.event` of kinds that change the list (§10.1).
    public func onEvent(_ m: VaultMessage) {
        guard m.type == "sync.event" else { return }
        if let kind = VaultJSON.string(m.object, "kind"), Self.listEvents.contains(kind) { refreshQuietly() }
    }

    static let listEvents: Set<String> = ["device.paired", "device.unlinked", "device.session", "leash.agent.suspended"]

    public func refreshQuietly() {
        if queued { return }
        queued = true
        Task { [weak self] in try? await self?.read(quietly: true, fromQueue: true) }
    }

    public func refresh() async throws { try await read(quietly: false, fromQueue: false) }

    private func read(quietly: Bool, fromQueue: Bool) async throws {
        await reads.enter()
        defer { reads.leave() }
        if fromQueue { queued = false }
        let gen = generation
        if devices.isEmpty { load = .loading }
        do {
            let o: any DevicesOps = try await Self.guarded { [self] in quietly ? try quietOps() : try await ops() }
            let body = try await Self.guarded { try await o.list() }
            // This phone's id once the session is open (as Android reads it after the list): read before it, a page opened
            // while the session reopens after the foreground would list this phone as another device.
            let parsed = DeviceWire.devices(body, selfID: selfID())
            // The paused agents: only asked when there is an agent. A failure never fails the list and never clears a
            // pause: nil keeps the paused flags already held (fail closed).
            var paused: Set<String>? = []
            if parsed.contains(where: \.isAgent) {
                do {
                    paused = DeviceWire.suspended(try await Self.guarded { try await o.grants(nil) })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    paused = nil
                }
            }
            guard gen == generation else { return }
            let held = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            devices = DeviceWire.ordered(parsed.map { d in
                var d = d
                d.paused = d.isAgent && (paused?.contains(d.id) ?? (held[d.id]?.paused == true))
                return d
            })
            load = .loaded
        } catch is CancellationError {
            if gen == generation, load == .loading { load = .notLoaded }
            throw CancellationError()
        } catch {
            if gen == generation { load = .failed }
            throw error
        }
    }

    public func endAccess(_ deviceID: String) async throws {
        try guardActionable(deviceID)
        let gen = generation
        try await Self.guarded { [self] in try await ops().endAccess(deviceID) }
        // A lock came meanwhile: the list is not this vault-open's any more; Approvals are still cleaned.
        if gen == generation {
            devices = devices.map { d in
                var d = d
                if d.id == deviceID { d.sessionExpiresAt = nil }
                return d
            }
        }
        try await deviceGone(deviceID)
        refreshQuietly()
    }

    public func remove(_ deviceID: String) async throws {
        try guardActionable(deviceID)
        let known = devices.first { $0.id == deviceID }
        let gen = generation
        try await Self.guarded { [self] in try await ops().unlink(deviceID) }
        if gen == generation {
            devices = devices.filter { $0.id != deviceID }
            removed = known
        }
        try await deviceGone(deviceID)
        refreshQuietly()
    }

    public func removalBoundSeconds(_ agentID: String) async -> Int64 {
        let ttls: [Int64]
        do {
            ttls = DeviceWire.statusTtls(try await Self.guarded { [self] in try await ops().grants(agentID) })
        } catch {
            return DeviceWire.maxStatusTtl + DeviceWire.skewSeconds
        }
        return (ttls.max()).map { $0 + DeviceWire.skewSeconds } ?? 0
    }

    public func dismissRemoved() { removed = nil }

    /// The app's own entry, and any other `app`, has no actions (`forbidden` from the vault): nothing is sent for it.
    private func guardActionable(_ deviceID: String) throws {
        if let own = selfID(), deviceID == own { throw VaultFailure(.other, code: "forbidden") }
        if devices.first(where: { $0.id == deviceID })?.actionable == false { throw VaultFailure(.other, code: "forbidden") }
    }

    /// The vault has done it: a failure of the Approvals clean-up must not turn it into a failed request (a cancellation
    /// still ends the task).
    private func deviceGone(_ id: String) async throws {
        do {
            try await onDeviceGone(id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The next read of Approvals settles it.
        }
    }

    /// Turns every failure of [body] into a ``VaultFailure`` (a cancellation stays one).
    private static func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }
}

/// One read at a time, in the order asked (vettid-android's `Mutex`): a read waits for the one before it.
@MainActor
final class ReadGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
