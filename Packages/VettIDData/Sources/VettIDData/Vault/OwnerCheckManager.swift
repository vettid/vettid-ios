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
    /// (Release L, §3.6.8) `vault.locking`'s reason for the idle lock.
    public nonisolated static let reasonIdle = "idle"
    /// (Release L, §10.8) The idle lock's setting.
    public nonisolated static let keyIdle = "idle_lock.after_seconds"
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
    /// (Release L) The vault locked itself (kept on the phone until it opens again); the idle-lock setting (nil before it was
    /// read, and for a vault that does not list it).
    public private(set) var idleLocked: IdleLocked?
    public private(set) var idleLockSetting: IdleLockSetting?

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
    /// What a failure shows beyond the check's screen (``VaultManager/noted(_:since:resend:)``: `credential_required`'s root
    /// screen).
    @ObservationIgnored private let notes: FailureNotes
    /// (Release R) When the check whose presence was not recorded passed, on the vault's clock (its answer's deadline less
    /// its interval), so that only a presence recorded since then ends the notice; nil when the answer did not say.
    @ObservationIgnored private var presenceCheckAt: Date?
    /// The `ts` of the newest `vault.held` applied (an older one never overwrites newer counts).
    @ObservationIgnored private(set) var heldTs: Date?
    /// (Release L) The lowest idle-lock value set since the last check, when one was set; nil: the set value is in force.
    @ObservationIgnored private var idleInForce: Int64?
    /// (Release L) How long past the deadline the vault locks itself, as read while the check was not yet due (then
    /// `idle_lock_at` less `deadline` is the value in force; past the deadline an unlock's extra hour or a call can move
    /// `idle_lock_at`, and the difference no longer says how long the member was away). Nil: never read.
    @ObservationIgnored private var idleAfterKnown: Int64?
    /// (Release L) The vault locked for a reason other than the idle lock since it last opened (the member locked it on this
    /// phone, or a notice named another reason): the time of `idle_lock_at` does not say why it is locked then.
    @ObservationIgnored private var lockedHere = false

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
        if saved.viewless != true { ownerCheck = saved.view }
        presenceUnrecorded = saved.presenceUnrecorded
        presenceCheckAt = saved.presenceCheckAt
        heldTs = saved.heldTs
        idleLocked = saved.idleLocked == true ? IdleLocked(afterSeconds: saved.idleAfter) : nil
        idleInForce = saved.idleInForce
        idleAfterKnown = saved.idleAfterKnown
        lockedHere = saved.lockedHere == true
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
                // A passed check: the idle lock's time moved with the deadline (the vault says it again), and a longer
                // idle-lock value set before it is in force now (§3.6.8).
                checkPassedForIdleLock()
                update { v in
                    v.state = .ok
                    v.deadline = Self.instant(VaultJSON.string(m.object, "deadline")) ?? v.deadline
                    v.failures = 0
                    v.waiting = nil
                    v.idleLockAt = nil
                }
            case "settings.changed": refreshQuietly()
            default: break
            }
        case "vault.locking": locking(reason: VaultJSON.string(m.object, "reason"))
        default: break
        }
    }

    private func locking(reason: String?) {
        switch reason {
        case Self.reasonOwnerCheck:
            lockedByOwnerCheck = true
            lockedHere = true
            saveFlags()
        // (Release L, §3.6.8) It locked itself: said on the unlock screen, with how long past the deadline that was, as the
        // vault last said.
        case Self.reasonIdle:
            idleLocked = IdleLocked(afterSeconds: idleAfterKnown)
            saveFlags()
        // Locked for another reason (the member's own lock, a recovery, a vault that names none): the time of `idle_lock_at`
        // is no reason to say it locked itself.
        default:
            lockedHere = true
            saveFlags()
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
        // (Release L) A `vault.held` from a release before L says nothing of the idle lock: what was read stays.
        v.idleLockAt = Self.instant(n.idleLockAt) ?? base.idleLockAt
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
    func onOpened() {
        endIdleLocked()
        refreshQuietly()
    }

    /// The vault is open again: it no longer is locked by itself.
    private func endIdleLocked() {
        if idleLocked == nil, !lockedHere { return }
        idleLocked = nil
        lockedHere = false
        saveFlags()
    }

    /// The unlock of a vault that may be past its deadline (§3.6.5): reads `vault.status` and, if the vault is held or
    /// due, sends the check with the same entries; the answer waits in ``unlockCheckOutcome``.
    func afterUnlock(pin: String, password: String) async {
        lockedByOwnerCheck = false
        endIdleLocked()
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
            waiting: state == .ok ? nil : Self.counts(st.waiting) ?? ownerCheck?.waiting,
            // (Release L) As the vault computes it now; absent before L.
            idleLockAt: Self.instant(st.idleLockAt)
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
            idleLocked = nil
            lockedHere = false
            checkPassedForIdleLock()
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

    // MARK: - The idle lock (release L, §3.6.8)

    public func idleLockedNow(_ now: Date) -> IdleLocked? {
        if let idleLocked { return idleLocked }
        guard !lockedHere, let at = ownerCheck?.idleLockAt, now >= at else { return nil }
        return IdleLocked(afterSeconds: idleAfterKnown)
    }

    public func onLockedHere() {
        lockedHere = true
        saveFlags()
    }

    public func refreshIdleLockSetting() async throws {
        let st = try await vault { try await self.ops().settingsGet() }
        idleLockSetting = st.values[Self.keyIdle].flatMap { Int64($0) }.map(settingOf)
    }

    public func setIdleLockAfter(seconds: Int64) async throws {
        guard IdleLockSetting.choices.contains(seconds) else { throw VaultFailure(.other, code: "bad_request") }
        if idleLockSetting == nil { try? await refreshIdleLockSetting() }
        guard let before = idleLockSetting else { throw VaultFailure(.notSupported) }
        try await setSetting(Self.keyIdle, String(seconds))
        // The vault keeps the lowest value since the last check (owner decision 2026-10-23): a longer one waits for it.
        let inForce = min(before.inForceSeconds, seconds)
        idleInForce = inForce < seconds ? inForce : nil
        idleLockSetting = IdleLockSetting(seconds: seconds, inForceSeconds: inForce)
        if let v = ownerCheck { set(v) }
        // A shorter value moves the idle lock's time at once.
        _ = try? await readStatus()
    }

    private func settingOf(_ seconds: Int64) -> IdleLockSetting {
        IdleLockSetting(seconds: seconds, inForceSeconds: min(seconds, idleInForce ?? seconds))
    }

    /// A check passed: the value set is the one in force from now on.
    private func checkPassedForIdleLock() {
        // The value set is in force from now on (a longer one set before the check included): the time said at an idle lock
        // is that value as it runs on this vault.
        if let setting = idleLockSetting {
            idleAfterKnown = Int64(TimeScale.scaled(TimeInterval(setting.seconds), by: max(scaleNow(), 1)))
        } else if idleInForce != nil {
            // A longer value waited for this check, but its value is not loaded (a new process that has not read the
            // setting): the time is not known, so the notice says so rather than the shorter value read before.
            idleAfterKnown = nil
        }
        idleInForce = nil
        if let setting = idleLockSetting { idleLockSetting = IdleLockSetting(seconds: setting.seconds) }
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
        // `settings.set` carries no secret and sets the same value again: "Try again" on the root screen resends it.
        try await vault(resend: .setting(key: key, json: json)) {
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
        idleLocked = nil
        idleInForce = nil
        idleAfterKnown = nil
        lockedHere = false
        idleLockSetting = nil
        try? persist([])
    }

    // MARK: - State

    private static func unknownHeld() -> OwnerCheckView { OwnerCheckView(state: .held, deadline: nil) }

    private func update(_ f: (inout OwnerCheckView) -> Void) {
        guard var v = ownerCheck else { return }
        f(&v)
        set(v)
    }

    /// Keeps the idle-lock flags on the phone, with or without a view of the check: a restart before any view was read must
    /// not forget that the vault locked for another reason or by itself.
    private func saveFlags() {
        if let v = ownerCheck { set(v); return }
        loadIfNeeded()
        // A file that cannot be read yet (the iPhone is locked) is not written over.
        guard loaded else { return }
        if let v = ownerCheck { set(v); return }
        persistSaved(Self.unknownHeld(), viewless: true)
    }

    private func persistSaved(_ v: OwnerCheckView, viewless: Bool = false) {
        var saved = Saved(view: v, heldTs: heldTs, presenceUnrecorded: presenceUnrecorded, presenceCheckAt: presenceCheckAt)
        saved.viewless = viewless ? true : nil
        saved.idleLocked = idleLocked != nil
        saved.idleAfter = idleLocked?.afterSeconds
        saved.idleInForce = idleInForce
        saved.idleAfterKnown = idleAfterKnown
        saved.lockedHere = lockedHere
        if let b = try? JSONEncoder().encode(saved) { try? persist(Array(b)) }
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
        // Before the deadline the idle lock's time is the deadline plus the value in force (§3.6.8).
        if v.state == .ok, let d = v.deadline, now() < d, let after = v.idleAfterSeconds { idleAfterKnown = after }
        persistSaved(v)
    }

    /// Runs [body] and turns every failure into a ``VaultFailure``.
    private func vault<T>(resend: Resend? = nil, _ body: () async throws -> T) async throws -> T {
        try await notes.run(resend: resend, body)
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
}
