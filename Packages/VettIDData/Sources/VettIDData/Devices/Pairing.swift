import Foundation
import VettIDCrypto
import Observation
import VettIDVault

/// `device.pair.*`, so that ``PairingManager`` can be tested without a vault. Mirrors vettid-android `PairingOps`.
public protocol PairingOps: Sendable {
    func create(role: PairRole) async throws -> JsonObject
    func approve(pairingID: String, sessionSeconds: Int?) async throws
    func reject(pairingID: String) async throws
}

/// ``PairingOps`` over the vault client. Mirrors vettid-android `VaultPairingOps`.
struct VaultPairingOps: PairingOps {
    let api: VaultApi

    func create(role: PairRole) async throws -> JsonObject { try await api.devicePairCreate(role: role.wire) }
    func approve(pairingID: String, sessionSeconds: Int?) async throws {
        try await api.pairApprove(pairingID, sessionSeconds: sessionSeconds)
    }

    func reject(pairingID: String) async throws { try await api.pairReject(pairingID) }
}

/// Pairing an agent or a desktop (ANDROID-PLAN 0.1.53 AA2), as the screens use it. Every failure is a ``FailureKind`` in the
/// state. Mirrors vettid-android `PairingRepository`.
@MainActor
public protocol PairingRepository: AnyObject, Observable, Sendable {
    var state: PairingState { get }

    /// Step 1: `device.pair.create{role}`; also "New code". A pairing already shown or compared for the same role is kept; one
    /// held for the other role is rejected and replaced in this call, and a create of the other role still in flight is
    /// superseded (its answer is dropped and rejected).
    func start(_ role: PairRole) async

    /// Step 3: `device.pair.approve`, with the first access length in seconds (nil: no access yet); never any grants.
    func approve(sessionSeconds: Int?) async

    /// "They don't match": `device.pair.reject`; the stage becomes ``PairingStage/rejected(told:)``.
    func reject() async

    /// Cancel on the code screen, or leaving the compare screen: a pairing not approved is rejected, and nothing is held.
    func cancel() async

    /// The screen left without an answer: the same as ``cancel()``, without waiting for it.
    func leave()

    /// A final stage was read (rejected, paired, ended, expired): back to nothing held.
    func acknowledge()
}

/// ``PairingRepository`` over ``PairingOps``. Fails secure: nothing is approved except by the member's tap on a code that can be
/// compared, within the time this phone allows; an expired code, a rejected, abandoned or failed pairing grants nothing. Memory
/// only: ``clear()`` (lock, hold, wipe, deletion) drops all of it. Events reach it through ``onEvent(_:)`` only after the app's
/// lock guard took them. Requests are not abandoned half way (a screen that left does not strand the pairing), and a lock bumps a
/// generation so that a late answer is not applied.
///
/// [knownDeviceIDs] (nil while the list was never read) and [readDevices] find the new device's `device_id` when the
/// `device.paired` feed item does not arrive in time (``idWait``). Mirrors vettid-android `PairingManager` (AA5's
/// `onCompareLeft` for Approvals is not built).
@MainActor
@Observable
public final class PairingManager: PairingRepository {
    public private(set) var state = PairingState()

    @ObservationIgnored private let ops: @MainActor () async throws -> any PairingOps
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let knownDeviceIDs: @MainActor () -> Set<String>?
    @ObservationIgnored private let readDevices: @MainActor () async throws -> [DeviceInfo]
    @ObservationIgnored private let onPaired: @MainActor () -> Void

    @ObservationIgnored private var generation = 0
    /// What the pairing in hand is for; every state is stamped with it.
    @ObservationIgnored private var role = PairRole.agent
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// `device_id`s of `device.paired` feed items seen while an approval was in flight or just done.
    @ObservationIgnored private var arrivals: [String] = []
    @ObservationIgnored private var watching = false
    /// The ids listed before the approval, and when it started: an arrival that was listed before, or older, is not it.
    @ObservationIgnored private var baseline: Set<String>?
    @ObservationIgnored private var watchFrom = Date.distantPast

    /// The pending's own window: 10 minutes after the event.
    static let window: TimeInterval = 600
    /// A code never lives longer than 10 minutes plus a minute (§6.4).
    static let codeMax: TimeInterval = 660
    /// How long the `device.paired` feed item is awaited before the list is read.
    public static let idWait: TimeInterval = 10
    static let pollMs = 250
    static let clockSlack: TimeInterval = 30
    static let sessionMin = 60
    static let sessionMax = 86_400

    public init(
        ops: @escaping @MainActor () async throws -> any PairingOps,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        knownDeviceIDs: @escaping @MainActor () -> Set<String>? = { nil },
        readDevices: @escaping @MainActor () async throws -> [DeviceInfo] = { [] },
        onPaired: @escaping @MainActor () -> Void = {}
    ) {
        self.ops = ops
        self.now = now
        self.sleep = sleep
        self.knownDeviceIDs = knownDeviceIDs
        self.readDevices = readDevices
        self.onPaired = onPaired
    }

    /// Stamps [v] with the role of the pairing in hand and publishes it.
    private func set(_ v: PairingState) {
        var v = v
        v.role = role
        state = v
    }

    /// Forgets everything: the vault locked, was held or wiped. A request on its way is not applied afterwards.
    public func clear() {
        generation += 1
        timer?.cancel()
        timer = nil
        arrivals = []
        watching = false
        role = .agent
        set(PairingState())
    }

    /// `device.pair.pending` for the pairing shown, and the `device.paired` feed item that names the new device.
    public func onEvent(_ m: VaultMessage) {
        switch m.type {
        case "device.pair.pending":
            pending(m.object)
        case "feed.event":
            let body = m.object
            guard VaultJSON.string(body, "kind") == "device.paired" else { return }
            let id = VaultJSON.string(body, "device_id").flatMap { $0.isEmpty ? nil : $0 }
            let at = OwnerCheckManager.instant(VaultJSON.string(body, "at"))
            // Only a new device, from after the approval started (a little slack for the clocks).
            let fresh = at.map { $0 >= watchFrom.addingTimeInterval(-Self.clockSlack) } ?? false
            guard watching, let id else { return }
            let usable = fresh && baseline?.contains(id) != true
            if usable, !arrivals.contains(id) { arrivals.append(id) }
        default:
            break
        }
    }

    private func pending(_ body: JsonObject) {
        guard let id = VaultJSON.string(body, "pairing_id").flatMap({ $0.isEmpty ? nil : $0 }) else { return }
        let at = now()
        // Only the pairing this phone made, once: a second event for it, or one for another, changes nothing.
        guard ours(state.stage, id, at) else { return }
        let sas = VaultJSON.string(body, "role") == role.wire ? Self.readSas(VaultJSON.string(body, "sas")) : nil
        let ends = at.addingTimeInterval(Self.window)
        let p = PendingPairing(pairingID: id, name: DeviceWire.cleanName(VaultJSON.string(body, "name")), sas: sas, ends: ends)
        timer?.cancel()
        let gen = generation
        timer = Task { [weak self] in
            await self?.endAt(ends, gen) { if case .compare(let c) = $0 { c.pairingID == id } else { false } }
        }
        set(PairingState(stage: .compare(p)))
    }

    /// Whether [stage] is the pairing [id] this phone made and still takes the device's answer at [at].
    private func ours(_ stage: PairingStage, _ id: String, _ at: Date) -> Bool {
        switch stage {
        // A code whose end has passed but whose timer has not run yet takes a late answer like an expired one (the same minute).
        case .code(let c): c.pairingID == id && at <= c.exp.addingTimeInterval(PairingStage.lateSeconds)
        case .codeExpired(let pairingID, let exp): pairingID == id && at <= exp.addingTimeInterval(PairingStage.lateSeconds)
        default: false
        }
    }

    /// At [at] a stage that [still] holds ends: nothing was approved, so nothing is.
    private func endAt(_ at: Date, _ gen: Int, still: (PairingStage) -> Bool) async {
        let wait = at.timeIntervalSince(now())
        if wait > 0 {
            do { try await sleep(.milliseconds(Int((wait * 1000).rounded(.up)) + 1)) } catch { return }
        }
        // The generation too: a timer woken as its pairing was replaced (cancellation is only cooperative) must not end the new
        // pairing's code, which `still` alone would take for its own.
        guard gen == generation, still(state.stage) else { return }
        // An approval in flight settles it by its answer.
        if state.busy { return }
        if case .code(let c) = state.stage {
            set(PairingState(stage: .codeExpired(pairingID: c.pairingID, exp: c.exp)))
        } else {
            set(PairingState(stage: .ended))
        }
    }

    public func start(_ role: PairRole = .agent) async {
        let gen: Int
        // A pairing of the other role that this start replaces: the vault is told it is not wanted.
        var replaced: String?
        let s = state
        if s.stage != .idle, self.role != role {
            // The other button: the held pairing is rejected and replaced in one step, so no state of it is left behind. An
            // approval in flight is not interrupted. A create in flight is superseded: its answer is dropped and rejected.
            if s.busy, s.stage != .creating { return }
            replaced = heldID(s.stage)
            generation += 1
        } else {
            if s.busy || s.stage == .creating { return }
            if case .compare = s.stage { return }
            if case .code(let c) = s.stage, c.exp > now() { return }
            // "New code" after an expiry: the expired pairing may still be answered for a minute, and the vault is told it is not wanted.
            if case .codeExpired(let id, _) = s.stage { replaced = id }
            // Every start is a new pairing: what the earlier one still has running (an id search) is not applied to it.
            generation += 1
        }
        gen = generation
        timer?.cancel()
        self.role = role
        set(PairingState(stage: .creating, busy: true))
        if let replaced { Task { [weak self] in _ = await self?.sendReject(replaced) } }
        // Once sent, the answer is applied (or rejected) whatever became of the caller: a cancelled screen must neither strand the
        // pairing in Creating nor leave an unwanted code at the vault.
        await Task { [self] in await create(role, gen) }.value
    }

    private func create(_ wanted: PairRole, _ gen: Int) async {
        do {
            let answer = try await guarded { [self] in try await ops().create(role: wanted) }
            let code = try read(answer, wanted)
            var stale: String?
            if gen != generation {
                // Superseded or cleared while the request was out: not shown. Told it is not wanted, unless it is the pairing
                // held now.
                if code.pairingID != heldID(state.stage) { stale = code.pairingID }
            } else {
                timer = Task { [weak self] in await self?.endAt(code.exp, gen) { if case .code = $0 { true } else { false } } }
                set(PairingState(stage: .code(code)))
            }
            // In the manager's scope, like the replaced id's: it never depends on the caller staying alive.
            if let stale { Task { [weak self] in _ = await self?.sendReject(stale) } }
        } catch {
            if gen == generation {
                let f = Self.failure(error)
                set(PairingState(stage: .idle, error: f.kind))
            }
        }
    }

    /// The id of the pairing a stage holds, if it holds one.
    private func heldID(_ stage: PairingStage) -> String? {
        switch stage {
        case .code(let c): c.pairingID
        case .codeExpired(let id, _): id
        case .compare(let p): p.pairingID
        default: nil
        }
    }

    /// The answer as a code: a link that is not a pairing of [role] (an agent's for a desktop, or the reverse), or one that does not
    /// read, is never shown.
    private func read(_ body: JsonObject, _ role: PairRole) throws -> PairingCode {
        let id = VaultJSON.string(body, "pairing_id").flatMap { $0.isEmpty ? nil : $0 }
        let link = VaultJSON.string(body, "link").flatMap { $0.isEmpty ? nil : $0 }
        guard let id, let link else { throw VaultFailure(.other, code: "unreadable_result") }
        let q: InviteQr
        do {
            q = try InviteQr.parseLink(link)
        } catch {
            throw unwanted(id)
        }
        guard q.kind == role.kind else { throw unwanted(id) }
        let at = now()
        let own = Date(timeIntervalSince1970: TimeInterval(q.exp))
        // The earliest of what the vault says and what the link says, and never longer than a code lives (§6.4).
        let exp = [OwnerCheckManager.instant(VaultJSON.string(body, "exp")), own, at.addingTimeInterval(Self.codeMax)]
            .compactMap { $0 }.min() ?? own
        return PairingCode(pairingID: id, link: link, exp: exp)
    }

    /// A pairing the vault made that this phone will not show (a link of the other kind, or one that does not read): it is rejected
    /// by its id at once, in this manager's scope, instead of being left to expire. Nothing of it is shown.
    private func unwanted(_ id: String) -> VaultFailure {
        Task { [weak self] in _ = await self?.sendReject(id) }
        return VaultFailure(.other, code: "unreadable_result")
    }

    public func approve(sessionSeconds: Int?) async {
        guard case .compare(let p) = state.stage else { return }
        let forRole = role
        // Never an approval of what cannot be compared, nor after this phone's time ran out, nor twice.
        if state.busy || !p.comparable || p.ends <= now() { return }
        if let s = sessionSeconds, !(Self.sessionMin...Self.sessionMax).contains(s) { return }
        let gen = generation
        arrivals = []
        watching = true
        // What the list shows now, and nothing is read first (the list may never have been loaded: then no guess).
        baseline = knownDeviceIDs()
        watchFrom = now()
        set(PairingState(stage: .compare(p), busy: true))
        // Once sent, everything up to the settled stage runs to its end: a screen that left must not strand the pairing busy and
        // watching.
        await Task { [self] in
            await settle(gen, p, forRole, sessionSeconds)
            // Only this approval's watch: a lock and a newer approval may have come since.
            if gen == generation { watching = false }
        }.value
    }

    private func settle(_ gen: Int, _ p: PendingPairing, _ forRole: PairRole, _ sessionSeconds: Int?) async {
        do {
            try await guarded { [self] in try await ops().approve(pairingID: p.pairingID, sessionSeconds: sessionSeconds) }
        } catch {
            await failed(gen, p, forRole, Self.failure(error))
            return
        }
        if gen != generation { return }
        timer?.cancel()
        timer = nil
        set(PairingState(stage: .paired(name: p.name, deviceID: nil)))
        onPaired()
        let id = await findDevice(p, forRole, gen)
        if gen == generation, case .paired = state.stage { set(PairingState(stage: .paired(name: p.name, deviceID: id))) }
    }

    private func failed(_ gen: Int, _ p: PendingPairing, _ forRole: PairRole, _ e: VaultFailure) async {
        // No answer at all: the vault may have taken the approval (also a connection lost on the way: ``FailureKind/offline`` is
        // this phone's own kind, chosen; not in the spec). Look for the new device before saying anything.
        let unknown = e.kind == .network || e.kind == .offline || e.kind == .noResponse
        let found = unknown ? await findDevice(p, forRole, gen) : nil
        if gen != generation { return }
        watching = false
        if let found {
            timer?.cancel()
            timer = nil
            set(PairingState(stage: .paired(name: p.name, deviceID: found)))
            onPaired()
            return
        }
        // The daily check is due: the approval was not sent for it, and the same code may still be compared.
        if e.kind == .ownerCheckRequired, p.ends > now() {
            set(PairingState(stage: .compare(p), error: e.kind))
            return
        }
        timer?.cancel()
        timer = nil
        // Any other answer: the pairing may have ended (the app does not know when, §10.3), so nothing is paired as far as this
        // phone knows. When there was no answer at all the vault may have taken it: say so.
        set(PairingState(stage: .ended, error: e.kind, unknownOutcome: unknown, agentName: p.name))
    }

    /// The new device's `device_id` (ANDROID-PLAN 0.1.53 AA2 step 4): from the `device.paired` feed item, else within ``idWait``
    /// from the list, the one entry of the role that was not listed before and carries the compared name. Nil when none or more
    /// than one fits: the list opens instead.
    private func findDevice(_ p: PendingPairing, _ forRole: PairRole, _ gen: Int) async -> String? {
        // A lock, a hold or a wipe came meanwhile: nothing is searched any more, and the list is not read (that could open a session
        // and fill the list after it was cleared).
        var waited = 0
        while waited < Int(Self.idWait * 1000) {
            if gen != generation { return nil }
            if arrivals.count == 1 { return arrivals[0] }
            try? await sleep(.milliseconds(Self.pollMs))
            waited += Self.pollMs
        }
        if arrivals.count == 1 { return arrivals[0] }
        if arrivals.count > 1 { return nil }
        guard gen == generation, let known = baseline else { return nil }
        let list: [DeviceInfo]
        do { list = try await readDevices() } catch { return nil }
        let fits = list.filter { forRole.matches($0) && !known.contains($0.id) && $0.name == p.name }
        return fits.count == 1 ? fits[0].id : nil
    }

    public func reject() async {
        guard case .compare(let p) = state.stage, !state.busy else { return }
        set(PairingState(stage: .compare(p), busy: true))
        let told = await sendReject(p.pairingID)
        if case .compare(let s) = state.stage, s.pairingID == p.pairingID {
            timer?.cancel()
            timer = nil
            set(PairingState(stage: .rejected(told: told)))
        }
    }

    public func cancel() async {
        let s = state
        let id: String
        switch s.stage {
        case .code(let c): id = c.pairingID
        case .compare(let p):
            if s.busy { return }
            id = p.pairingID
        // A late handshake of the expired code may still be live: the vault is told this one is not wanted.
        case .codeExpired(let pairingID, _): id = pairingID
        case .creating:
            // Left while the code was being made: nothing is shown, and the answer, when it comes, is not this pairing's (the
            // generation moved), so it is rejected like any unwanted one.
            generation += 1
            timer?.cancel()
            timer = nil
            set(PairingState())
            return
        default:
            if !s.busy { set(PairingState()) }
            return
        }
        timer?.cancel()
        timer = nil
        set(PairingState())
        // Nothing is held any more; the vault is told (best effort: the pairing ends by itself within 10 minutes).
        _ = await sendReject(id)
    }

    public func leave() {
        Task { [weak self] in await self?.cancel() }
    }

    public func acknowledge() {
        let s = state
        if s.busy { return }
        switch s.stage {
        case .rejected, .paired, .ended, .codeExpired: set(PairingState())
        case .idle: if s.error != nil { set(PairingState()) }
        // The daily check passed: the refused approval may be sent again for the same comparison.
        case .compare: if s.error != nil { set(PairingState(stage: s.stage)) }
        default: break
        }
    }

    /// `device.pair.reject`; whether the vault took it. A failure is not an error to show: nothing is paired either way.
    private func sendReject(_ id: String) async -> Bool {
        do {
            try await guarded { [self] in try await ops().reject(pairingID: id) }
            return true
        } catch {
            return false
        }
    }

    /// A request that is not abandoned half way: once it was sent, its answer is applied even if the screen that asked has gone (a
    /// cancelled caller would leave the state waiting for an answer that nobody reads). Every failure is a ``VaultFailure`` (or a
    /// cancellation).
    private func guarded<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await Task { @MainActor in
            do {
                return try await body()
            } catch {
                throw VaultFailures.map(error)
            }
        }.value
    }

    /// [e] as a failure: a cancellation, which no request of a pairing can end in, is an answer that did not come.
    private static func failure(_ e: any Error) -> VaultFailure {
        if let f = e as? VaultFailure { return f }
        return VaultFailure(e is CancellationError ? .noResponse : .other)
    }

    /// The six digits, from "123456" or "123 456"; nil for anything else.
    static func readSas(_ s: String?) -> String? {
        guard let t = s?.replacingOccurrences(of: " ", with: ""), t.utf8.count == 6 else { return nil }
        return t.utf8.allSatisfy { (0x30...0x39).contains($0) } ? t : nil
    }
}
