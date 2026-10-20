import Foundation
import Observation
import VettIDCrypto
import VettIDKeys
import VettIDVault

/// The vault operations the owner check needs (``VaultOwnerCheckOps`` in the app; a fake in tests). Mirrors
/// vettid-android `OwnerCheckOps`.
public protocol OwnerCheckOps: Sendable {
    /// `vault.status`'s `owner_check` and (release R) `recovery`, from one read.
    func statusAndRecovery() async throws -> (OwnerCheckStatus?, RecoveryStatus?)

    func check(pin: String, password: String, hold: Bool?, holdOffUntil: String?) async throws -> OwnerCheckPassed

    func settingsGet() async throws -> VaultSettings

    func settingsSet(version: UInt64, set: [(key: String, json: String)]) async throws
}

/// The app's side of the daily owner check (VAULT-MESSAGING 0.13.0 §3.6): follows the vault's deadline and hold, sends
/// the check, changes the interval and the hold, and keeps what it learnt through [persist] (an encrypted file of the
/// app) so that a locked vault past its deadline asks for the PIN and the password together. Gating the screens (when to
/// show the check, never over an action in progress) is the UI's part (§3.6.5). The feed's `owner_check.*` notices come
/// with the Notifications screen (IOS-PLAN §8 I2.3). Mirrors vettid-android `OwnerCheckManager`.
@MainActor
@Observable
public final class OwnerCheckManager: OwnerCheckRepository {
    public nonisolated static let reasonOwnerCheck = "owner_check"
    public nonisolated static let keyInterval = "owner_check.interval_seconds"
    public nonisolated static let keyHold = "owner_check.hold"
    nonisolated static let codeBadPin = "bad_pin"
    nonisolated static let codeBadPassword = "bad_password"
    nonisolated static let codeBackoff = "backoff"
    /// How long a failed check waits for the status that says how many checks are left (the tenth locks the vault, and
    /// then nothing answers).
    nonisolated static let statusAfterFailure: Duration = .seconds(5)
    /// The margin under the 30 days a hold may stay off, for the clocks of the phone and the enclave.
    nonisolated static let holdOffMargin: TimeInterval = 600

    public private(set) var ownerCheck: OwnerCheckView? {
        didSet {
            let (was, now) = ((oldValue?.state ?? .ok) != .ok, (ownerCheck?.state ?? .ok) != .ok)
            if was != now { onHeldChange(now) }
        }
    }
    /// Told when the vault becomes held or due (true) and when it is no longer (false), as the state says (§3.6.3).
    @ObservationIgnored public var onHeldChange: @MainActor (_ held: Bool) -> Void = { _ in }
    public private(set) var lockedByOwnerCheck = false
    public private(set) var unlockCheckOutcome: OwnerCheckOutcome?
    public private(set) var notices: [OwnerCheckNotice] = []
    public private(set) var presenceUnrecorded = false
    public private(set) var checkAfterCancel = false

    @ObservationIgnored private let ops: @MainActor () async throws -> any OwnerCheckOps
    @ObservationIgnored private let load: @MainActor () throws -> [UInt8]?
    @ObservationIgnored private let persist: @MainActor ([UInt8]) throws -> Void
    /// What was kept on the phone has been read (or replaced by something newer).
    @ObservationIgnored private var loaded = false
    /// Bumped by every ``clear()``: an answer to a request sent before it is not kept.
    @ObservationIgnored private var clears = 0
    @ObservationIgnored private let onPassed: @MainActor () -> Void
    @ObservationIgnored private let onRecoveryStatus: @MainActor (RecoveryStatus?, Int) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let mark: @MainActor () -> Int
    @ObservationIgnored private let sleep: LockSleep
    /// The vault's time scale now (STAGING-TIME-SCALE §5.2; ``LocalAccount/timeScale``).
    @ObservationIgnored private let scaleNow: @MainActor () -> UInt64
    /// What a failure shows beyond the check's screen (``VaultManager/noted(_:since:retry:)``: `credential_required`'s root
    /// screen).
    @ObservationIgnored private let notes: FailureNotes
    /// (Release R) When the check whose presence was not recorded passed, on the vault's clock (its answer's deadline less
    /// its interval), so that only a presence recorded since then ends the notice; nil when the answer did not say.
    @ObservationIgnored private var presenceCheckAt: Date?
    /// The `ts` of the newest `vault.held` applied (an older one never overwrites newer counts).
    @ObservationIgnored private(set) var heldTs: Date?

    /// [ops] the vault's operations, opened when needed; [load] and [persist] the kept state, read by ``loadIfNeeded()``
    /// (never before the first-run cleanup and a pending wipe); [onPassed] the catch-up after a passed check (§3.6.3);
    /// [onRecoveryStatus] each status's `recovery`, with the [mark] read before it.
    public init(
        ops: @escaping @MainActor () async throws -> any OwnerCheckOps,
        load: @escaping @MainActor () throws -> [UInt8]?,
        persist: @escaping @MainActor ([UInt8]) throws -> Void,
        onPassed: @escaping @MainActor () -> Void = {},
        onRecoveryStatus: @escaping @MainActor (RecoveryStatus?, Int) -> Void = { _, _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        mark: @escaping @MainActor () -> Int = { 0 },
        sleep: @escaping LockSleep = realLockSleep,
        timeScale: @escaping @MainActor () -> UInt64 = { 1 },
        notes: FailureNotes = .none
    ) {
        self.ops = ops
        self.load = load
        self.persist = persist
        self.onPassed = onPassed
        self.onRecoveryStatus = onRecoveryStatus
        self.now = now
        self.mark = mark
        self.sleep = sleep
        scaleNow = timeScale
        self.notes = notes
    }

    /// The vault's time scale as this phone last learnt it (STAGING-TIME-SCALE §5.2), for the screens.
    public var timeScale: UInt64 { scaleNow() }

    /// Reads what was kept on the phone, once. A locked iPhone (protected data not available yet) reads nothing and is
    /// tried again by the next call; a file that does not read is no state.
    public func loadIfNeeded() {
        guard !loaded else { return }
        let bytes: [UInt8]?
        do {
            bytes = try load()
        } catch KeysError.unavailable {
            return
        } catch {
            bytes = nil
        }
        loaded = true
        guard let b = bytes, !b.isEmpty, let saved = try? JSONDecoder().decode(Saved.self, from: Data(b)) else { return }
        ownerCheck = saved.view
        presenceUnrecorded = saved.presenceUnrecorded
        presenceCheckAt = saved.presenceCheckAt
        heldTs = saved.heldTs
    }

    public func consumeCheckAfterCancel() { checkAfterCancel = false }

    public func consumeUnlockCheckOutcome() { unlockCheckOutcome = nil }

    public func dismissNotices() async throws { notices = [] }

    // MARK: - What the vault tells

    /// Events the manager follows: `vault.held`, `sync.event{owner_check}`, `vault.locking{reason: "owner_check"}`.
    func onEvent(_ m: VaultMessage) {
        switch m.type {
        case "vault.held": onHeld(m)
        case "sync.event":
            switch VaultJSON.string(m.object, "kind") {
            // Another device saw a check pass (§3.6.3); the holder learns it from its own answer.
            case "owner_check":
                update { v in
                    v.state = .ok
                    v.deadline = Self.instant(VaultJSON.string(m.object, "deadline")) ?? v.deadline
                    v.failures = 0
                    v.waiting = nil
                }
            case "settings.changed": refreshQuietly()
            default: break
            }
        case "vault.locking":
            if VaultJSON.string(m.object, "reason") == Self.reasonOwnerCheck { lockedByOwnerCheck = true }
        default: break
        }
    }

    private func onHeld(_ m: VaultMessage) {
        guard let n = try? VaultJSON.decode(HeldNotice.self, m.body) else { return }
        // A device keeps the newest by ts (§3.6.3).
        if let prev = heldTs, m.ts < prev { return }
        heldTs = m.ts
        let base = ownerCheck ?? Self.unknownHeld()
        var v = base
        v.state = base.holdOff(now()) ? .due : .held
        v.deadline = Self.instant(n.deadline) ?? base.deadline
        v.waiting = Self.counts(n.waiting) ?? WaitingCounts()
        set(v)
    }

    /// A request was answered `owner_check_required` (§3.6.3): the vault is past its deadline.
    func onRequired() {
        if ownerCheck == nil || ownerCheck?.state == .ok {
            var v = ownerCheck ?? Self.unknownHeld()
            v.state = v.holdOff(now()) ? .due : .held
            set(v)
        }
        refreshQuietly()
    }

    /// The vault opened (an unlock, or the app started with it unlocked): the check is read again.
    func onOpened() { refreshQuietly() }

    /// The unlock of a vault that may be past its deadline (§3.6.5): reads `vault.status` and, if the vault is held or
    /// due, sends the check with the same entries; the answer waits in ``unlockCheckOutcome``.
    func afterUnlock(pin: String, password: String) async {
        lockedByOwnerCheck = false
        let v = try? await readStatus().view
        if let v, v.gated(now()) { unlockCheckOutcome = await checkOutcome(pin: pin, password: password, holdOff: nil) }
    }

    /// (Release R, ANDROID-PLAN "Other screens") Right after an unlock that cancelled a recovery: the owner check at once,
    /// with the same entries, whatever the deadline, because it records that the member is present (§11.14.5). A check
    /// that does not pass waits in ``unlockCheckOutcome``, and ``checkAfterCancel`` asks for the check screen.
    func afterCancelledRecovery(pin: String, password: String) async {
        lockedByOwnerCheck = false
        let r = await checkOutcome(pin: pin, password: password, holdOff: nil)
        if r != .passed {
            unlockCheckOutcome = r
            checkAfterCancel = true
        }
    }

    // MARK: - OwnerCheckRepository

    public func refreshOwnerCheck() async throws { _ = try await readStatus() }

    private func refreshQuietly() {
        Task { [weak self] in _ = try? await self?.readStatus() }
    }

    /// `vault.status`: the view it gives, and whether it is a fresh one (false: the vault sent no `owner_check`).
    private func readStatus() async throws -> (view: OwnerCheckView?, fresh: Bool) {
        let since = mark()
        let cleared = clears
        let (st0, recovery) = try await vault { try await self.ops().statusAndRecovery() }
        // A wipe meanwhile: nothing of the old vault is kept.
        guard cleared == clears else { return (ownerCheck, false) }
        presenceFromStatus(recovery)
        onRecoveryStatus(recovery, since)
        guard let st = st0 else { return (ownerCheck, false) }
        let state: OwnerCheckState = switch st.state {
        case "held": .held
        case "due": .due
        default: .ok
        }
        let v = OwnerCheckView(
            state: state,
            deadline: Self.instant(st.deadline),
            intervalSeconds: st.intervalSeconds ?? OwnerCheckView.maxIntervalSeconds,
            failures: st.failures ?? 0,
            hold: st.hold ?? true,
            holdOffUntil: Self.instant(st.holdOffUntil),
            // 0.19.0: the status says what is waiting; from an older vault only `vault.held` does.
            waiting: state == .ok ? nil : Self.counts(st.waiting) ?? ownerCheck?.waiting
        )
        set(v)
        return (v, true)
    }

    public func check(pin: String, password: String, holdOff: HoldOff?) async throws -> OwnerCheckOutcome {
        await checkOutcome(pin: pin, password: password, holdOff: holdOff)
    }

    private func checkOutcome(pin: String, password: String, holdOff: HoldOff?) async -> OwnerCheckOutcome {
        let until = holdOff?.until.map(clampHoldOff)
        let cleared = clears
        do {
            let r = try await vault {
                try await self.ops().check(
                    pin: pin, password: password, hold: holdOff == nil ? nil : false, holdOffUntil: until.map(Self.format)
                )
            }
            guard cleared == clears else { return .failed(.other, code: nil) }
            lockedByOwnerCheck = false
            heldTs = nil
            presenceFromCheck(r)
            set(OwnerCheckView(
                state: .ok,
                deadline: Self.instant(r.deadline),
                intervalSeconds: r.intervalSeconds ?? ownerCheck?.intervalSeconds ?? OwnerCheckView.maxIntervalSeconds,
                failures: 0,
                hold: r.hold ?? true,
                holdOffUntil: Self.instant(r.holdOffUntil)
            ))
            onPassed()
            return .passed
        } catch let e as VaultFailure {
            return await failed(e)
        } catch {
            return .failed(.other, code: nil)
        }
    }

    private func failed(_ e: VaultFailure) async -> OwnerCheckOutcome {
        switch e.code {
        case Self.codeBadPin: .badPin(checksLeft: await checksLeftAfterFailure())
        case Self.codeBadPassword: .badPassword(checksLeft: await checksLeftAfterFailure())
        // A backoff's wait: the error body's `retry_after` (VAULT-MESSAGING 0.17.0 §3.6.1, §10.1); 0 from older vaults.
        case Self.codeBackoff: .backoff(retryAfterSeconds: e.retryAfterSeconds)
        default: .failed(e.kind, code: e.code)
        }
    }

    /// A failed check counts (§3.6.4): `failures` is read again, for at most ``statusAfterFailure`` (the tenth locks the
    /// vault, and then nothing answers); without a fresh status the count kept here goes up by one.
    private func checksLeftAfterFailure() async -> Int? {
        let before = ownerCheck
        let wait = KickableWait()
        let read = FreshStatus()
        Task { @MainActor [weak self] in
            if let r = try? await self?.readStatus(), r.fresh { read.view = r.view }
            wait.kick()
        }
        await wait.wait(Self.statusAfterFailure, sleep: sleep)
        if let after = read.view { return after.checksLeft }
        guard var b = before else { return nil }
        b.failures += 1
        set(b)
        return b.checksLeft
    }

    private func clampHoldOff(_ until: Date) -> Date {
        // At most 30 days ahead at the vault (§3.6.7): a small margin for the clocks of the phone and the enclave.
        let max = now().addingTimeInterval(OwnerCheckView.maxHoldOff - Self.holdOffMargin)
        let t = until > max ? max : until
        return Date(timeIntervalSince1970: t.timeIntervalSince1970.rounded(.down))
    }

    public func setCheckInterval(seconds: Int64) async throws {
        guard (OwnerCheckView.minIntervalSeconds...OwnerCheckView.maxIntervalSeconds).contains(seconds) else {
            throw VaultFailure(.other, code: "bad_request")
        }
        try await setSetting(Self.keyInterval, String(seconds))
        // Shortening may move the deadline at once, and may hold the vault (§3.6.2).
        _ = try? await readStatus()
    }

    public func turnHoldOn() async throws {
        try await setSetting(Self.keyHold, "true")
        update { v in
            v.hold = true
            v.holdOffUntil = nil
        }
        _ = try? await readStatus()
    }

    private func setSetting(_ key: String, _ json: String) async throws {
        // `settings.set` carries no secret: "Try again" on the root screen sends it again (IOS-PLAN §4.4 (1)).
        try await vault(retry: { [weak self] in try? await self?.setSetting(key, json) }) {
            let o = try await self.ops()
            let current = try await o.settingsGet()
            if current.values[key] != json { try await o.settingsSet(version: current.version, set: [(key, json)]) }
        }
    }

    /// (Release R, §11.14.5) `present_recorded` false starts the notice; true ends it; absent changes nothing.
    private func presenceFromCheck(_ r: OwnerCheckPassed) {
        switch r.recovery?.presentRecorded {
        case false?:
            let deadline = Self.instant(r.deadline)
            // The interval is in real units; the vault divided it by its time scale for this deadline (§5.1): the scale
            // recorded with the deadline (as ``set(_:)`` records it).
            let scale = deadline != nil && deadline == ownerCheck?.deadline ? ownerCheck?.timeScale ?? scaleNow() : scaleNow()
            presenceCheckAt = if let deadline, let i = r.intervalSeconds {
                deadline.addingTimeInterval(-TimeScale.scaled(Double(i), by: scale))
            } else {
                nil
            }
            presenceUnrecorded = true
        case true?:
            presenceCheckAt = nil
            presenceUnrecorded = false
        case nil:
            break
        }
    }

    /// A `vault.status` whose presence was recorded at or after the check that could not record it ends the notice.
    private func presenceFromStatus(_ r: RecoveryStatus?) {
        let at = Self.instant(r?.presentRecordedAt)
        // Without the check's time (an answer without deadline or interval) no status can show it was recorded since.
        guard presenceUnrecorded, let at, let since = presenceCheckAt, at >= since else { return }
        presenceCheckAt = nil
        presenceUnrecorded = false
        if let v = ownerCheck { set(v) }
    }

    /// Forgets everything (a wipe, a deleted vault); an answer on its way is not kept.
    func clear() {
        clears += 1
        loaded = true
        ownerCheck = nil
        lockedByOwnerCheck = false
        unlockCheckOutcome = nil
        notices = []
        heldTs = nil
        presenceUnrecorded = false
        presenceCheckAt = nil
        checkAfterCancel = false
        try? persist([])
    }

    // MARK: - State

    private static func unknownHeld() -> OwnerCheckView { OwnerCheckView(state: .held, deadline: nil) }

    private func update(_ f: (inout OwnerCheckView) -> Void) {
        guard var v = ownerCheck else { return }
        f(&v)
        set(v)
    }

    private func set(_ view: OwnerCheckView) {
        var v = view
        // STAGING-TIME-SCALE §5.2: a new deadline's early warning takes the scale known now; the same deadline keeps the
        // scale it was learnt with.
        let same = v.deadline != nil && v.deadline == ownerCheck?.deadline
        v.timeScale = same ? ownerCheck?.timeScale ?? scaleNow() : scaleNow()
        // Newer than what the file held: the file is not read over it.
        loaded = true
        ownerCheck = v
        let saved = Saved(view: v, heldTs: heldTs, presenceUnrecorded: presenceUnrecorded, presenceCheckAt: presenceCheckAt)
        if let b = try? JSONEncoder().encode(saved) { try? persist(Array(b)) }
    }

    /// Runs [body] and turns every failure into a ``VaultFailure``.
    private func vault<T>(retry: RetryAction? = nil, _ body: () async throws -> T) async throws -> T {
        try await notes.run(retry: retry, body)
    }

    private static func counts(_ h: HeldCounts?) -> WaitingCounts? {
        h.map { WaitingCounts(messages: $0.messages ?? 0, requests: $0.requests ?? 0, calls: $0.calls ?? 0, other: $0.other ?? 0) }
    }

    /// An RFC 3339 instant of the vault (with or without fractional seconds); nil when absent or unreadable.
    public nonisolated static func instant(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    nonisolated static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// What is kept on the phone. `waiting` nil: the vault has not said what is waiting (never zero for unknown);
    /// `heldTs`: the `ts` of the `vault.held` the counts came from.
    private struct Saved: Codable {
        var state: OwnerCheckState
        var deadline: Date?
        var interval: Int64
        var failures: Int
        var hold: Bool
        var holdOffUntil: Date?
        var waiting: WaitingCounts?
        var heldTs: Date?
        var presenceUnrecorded: Bool
        var presenceCheckAt: Date?
        /// The deadline's time scale; absent in a file written before it (1).
        var timeScale: UInt64?

        init(view v: OwnerCheckView, heldTs: Date?, presenceUnrecorded: Bool, presenceCheckAt: Date?) {
            state = v.state
            deadline = v.deadline
            interval = v.intervalSeconds
            failures = v.failures
            hold = v.hold
            holdOffUntil = v.holdOffUntil
            waiting = v.waiting
            self.heldTs = heldTs
            self.presenceUnrecorded = presenceUnrecorded
            self.presenceCheckAt = presenceCheckAt
            timeScale = v.timeScale
        }

        var view: OwnerCheckView {
            OwnerCheckView(
                state: state, deadline: deadline, intervalSeconds: interval, failures: failures, hold: hold,
                holdOffUntil: holdOffUntil, waiting: waiting, timeScale: max(timeScale ?? 1, 1)
            )
        }
    }
}

/// A status read that may finish after its wait ended (it is then not used).
@MainActor
private final class FreshStatus {
    var view: OwnerCheckView?
}

/// ``OwnerCheckOps`` over the vault client. Mirrors vettid-android `VaultOwnerCheckOps`.
struct VaultOwnerCheckOps: OwnerCheckOps {
    let api: VaultApi
    /// Runs before the check is sent: refuses it while a change of PIN or password is unresolved (VAULT-MESSAGING
    /// §11.14.9 "A lost answer").
    var gate: @Sendable () async throws -> Void = {}
    /// Hears each `vault.status` (its `time_scale`, STAGING-TIME-SCALE §5.2).
    var onStatus: @Sendable (VaultStatusInfo) async -> Void = { _ in }

    func statusAndRecovery() async throws -> (OwnerCheckStatus?, RecoveryStatus?) {
        let s = try await api.status()
        await onStatus(s)
        return (s.ownerCheck, s.recovery)
    }

    func check(pin: String, password: String, hold: Bool?, holdOffUntil: String?) async throws -> OwnerCheckPassed {
        try await gate()
        return try await api.ownerCheck(pin: pin, password: password, hold: hold, holdOffUntil: holdOffUntil)
    }

    func settingsGet() async throws -> VaultSettings { try await api.settingsGet() }

    func settingsSet(version: UInt64, set: [(key: String, json: String)]) async throws {
        _ = try await api.settingsSet(version: version, set: set)
    }
}
