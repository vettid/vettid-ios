import Foundation
import Observation
import VettIDData

/// Why the check screen is open (VAULT-MESSAGING §3.6.5). Mirrors vettid-android `OwnerCheckMode`.
public enum OwnerCheckMode: Equatable, Sendable {
    /// Past the deadline: the app is gated; never dismissible, only the check or locking the vault.
    case gated
    /// The member checks early ("check now"): resets the clock; may be cancelled.
    case voluntary
    /// Turning the hold off, which only a check may do (§3.6.7); may be cancelled.
    case holdOff
}

/// How long the hold stays off (§3.6.7: an optional end date at most 30 days ahead). Mirrors vettid-android
/// `HoldOffChoice`.
public enum HoldOffChoice: CaseIterable, Equatable, Sendable {
    case untilTurnedOn, oneDay, threeDays, oneWeek, thirtyDays

    public var days: Int? {
        switch self {
        case .untilTurnedOn: nil
        case .oneDay: 1
        case .threeDays: 3
        case .oneWeek: 7
        case .thirtyDays: 30
        }
    }
}

/// What the check screen says about the last answer. Mirrors vettid-android `OwnerCheckMessage`.
public enum OwnerCheckMessage: Equatable, Sendable {
    case badPin(checksLeft: Int?)
    case badPassword(checksLeft: Int?)
    case backoff
    case failed(FailureKind, code: String?)
}

/// What the gated check shows of what is waiting (§3.6.5). [counts] nil: the vault has not said yet (no `vault.held` and no
/// `owner_check.waiting` so far), which is never shown as zero. [held] nil: the hold is not known either. Mirrors
/// vettid-android `WaitingCardModel`.
public struct WaitingCardModel: Equatable, Sendable {
    public let counts: WaitingCounts?
    public let held: Bool?

    public init(counts: WaitingCounts?, held: Bool?) {
        self.counts = counts
        self.held = held
    }

    /// The waiting card whenever the check gates the app (``OwnerCheckMode/gated``), also while the phone's clock has
    /// passed the deadline before the vault said so (`state` still `ok`); never for a voluntary check or the hold-off.
    public static func of(_ mode: OwnerCheckMode, _ v: OwnerCheckView?, now: Date) -> WaitingCardModel? {
        guard mode == .gated else { return nil }
        let held: Bool? = switch v?.state {
        case nil: nil
        case .held?: true
        case .due?: false
        case .ok?: v?.holdOff(now) == false
        }
        return WaitingCardModel(counts: v?.waiting, held: held)
    }
}

/// (Release L, VAULT-MESSAGING §3.6.8) When the vault locks itself if no check is passed, as it last said: on the gated check
/// (held, or due with the hold off) only; nil for a vault before L, and once that time has passed (a call in progress delays
/// the lock; the line would name a time gone by). Mirrors vettid-android `idleLockAtOf`.
public func idleLockAtOf(_ mode: OwnerCheckMode, _ v: OwnerCheckView?, now: Date) -> Date? {
    guard mode == .gated, let at = v?.idleLockAt, now < at else { return nil }
    return at
}

/// The owner-check screen's state. The PIN is here only from the member's "Check" until the answer; the password only
/// until the answer (§3.6.5: neither entry is kept beyond it). Never printed: the description names no secret. Mirrors
/// vettid-android `OwnerCheckUiState`.
public struct OwnerCheckScreenState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A vault PIN is 6–32 digits (§3.6.1: `bad_request` otherwise).
    public static let minPin = 6
    public static let maxPin = 32

    public var mode: OwnerCheckMode = .gated
    public var view: OwnerCheckView?
    public var pin = ""
    public var password = ""
    public var holdOff: HoldOffChoice = .oneWeek
    public var busy = false
    public var message: OwnerCheckMessage?
    /// A running backoff's wait, when the vault said how long.
    public var waitSeconds: Int64 = 0
    /// The check passed: the screen closes.
    public var passed = false
    public var locking = false
    /// (Release R, §11.14.5) The vault could not record that the member was here: the presence notice.
    public var presenceUnrecorded = false
    /// The check passed with the presence not recorded: the screen stays with the notice until the member goes on.
    public var passedUnrecorded = false
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale: the screen shows the scaled waits, and on staging its note.
    public var timeScale: UInt64 = 1
    /// (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5 "Ask only for what is used") The unlock's PIN was accepted and the check after
    /// it failed on the password (or backed off): the PIN is kept in ``pin`` only while this screen is in front, and only the
    /// password is asked for, with "Check in".
    public var pinKept = false
    /// The tries left after the wrong password that followed the unlock (``pinKept``): the approved line under the counts.
    public var unlockedWrong: Int?
    /// The check after the unlock ran into a backoff (``pinKept``): the vault is open, the password is asked for.
    public var unlockedOpen = false
    /// The vault locked after ten wrong checks (§3.6.4): the lock text, and no check is sent.
    public var locked = false

    public init(mode: OwnerCheckMode = .gated, view: OwnerCheckView? = nil, timeScale: UInt64 = 1) {
        self.mode = mode
        self.view = view
        self.timeScale = timeScale
    }

    /// What the member waits between checks: the interval (real units) at the vault's time scale.
    public var intervalText: String {
        TimeScales.text(TimeInterval(view?.intervalSeconds ?? OwnerCheckView.maxIntervalSeconds), by: timeScale)
    }

    /// The presence notice's quiet period (§11.14.5) at the vault's time scale on a scaled vault ("3 hours" on staging);
    /// nil in real time, where the notice says the approved "three days" (the owner's decision of 2026-10-19).
    public var scaledQuietText: String? { TimeScales.scaledText(TimeScales.recoveryQuiet, by: timeScale) }

    /// "Staging: 1 day = 1 hour" on a staging vault; nil otherwise.
    public var stagingNote: String? { TimeScales.stagingNote(timeScale) }

    /// Whether the check may be sent now (the PIN's length is the keypad's, checked by the screen).
    public var entriesAllowed: Bool { !busy && !locking && !locked && waitSeconds == 0 }

    public var submitAllowed: Bool { entriesAllowed && !locked && pin.count >= Self.minPin && !password.isEmpty }

    /// The checks left before the vault locks, to show: from the last answer, else from what the vault said.
    public var checksLeft: Int? {
        switch message {
        case .badPin(let left), .badPassword(let left): left
        default: view.flatMap { $0.failures > 0 ? $0.checksLeft : nil }
        }
    }

    public var description: String {
        "OwnerCheckScreenState(mode: \(mode), busy: \(busy), message: \(message.map { "\($0)" } ?? "nil"), "
            + "wait: \(waitSeconds), passed: \(passed))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the check screen can ask for: ``OwnerCheckViewModel``, or ``NoOwnerCheckActions`` in previews and the screen
/// catalog. Mirrors vettid-android `OwnerCheckActions`.
@MainActor
public protocol OwnerCheckActions: AnyObject, Sendable {
    /// The PIN from the keypad, handed over once, right before ``submit()``.
    func setPin(_ v: String)
    func setPassword(_ v: String)
    func setHoldOff(_ choice: HoldOffChoice)
    func submit()
    func lockVault()
    /// After a check that passed with the presence notice: the member read it; the screen closes.
    func acknowledgePresence()
    /// The app left the foreground or the iPhone is locking: typed secrets are dropped.
    func forgetSecrets()
}

/// Actions that do nothing: the screen rendered with sample states.
@MainActor
public final class NoOwnerCheckActions: OwnerCheckActions {
    public init() {}

    public func setPin(_ v: String) {}
    public func setPassword(_ v: String) {}
    public func setHoldOff(_ choice: HoldOffChoice) {}
    public func submit() {}
    public func lockVault() {}
    public func acknowledgePresence() {}
    public func forgetSecrets() {}
}

/// The daily owner check (VAULT-MESSAGING §3.6.5): the PIN and the credential password on one screen, sent together in
/// one `vault.owner-check`, both dropped from memory once the vault answered. Shows which entry was wrong, the checks left
/// before the vault locks (10 − `failures`) and a running backoff; while the vault is held, only the `vault.held` counts
/// and the lock action besides (the held screen). Turning the hold off rides on a check (§3.6.7). Mirrors vettid-android
/// `OwnerCheckViewModel`.
@MainActor
@Observable
public final class OwnerCheckViewModel: OwnerCheckActions {
    public private(set) var state: OwnerCheckScreenState

    @ObservationIgnored private let repo: any OwnerCheckRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let tick: @Sendable () async throws -> Void
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWork = 0

    public init(
        repo: any OwnerCheckRepository,
        vault: any VaultRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.repo = repo
        self.vault = vault
        self.now = now
        self.tick = tick
        state = OwnerCheckScreenState(view: repo.ownerCheck, timeScale: repo.timeScale)
        followers.add(follow(self, read: { $0.repo.ownerCheck }, apply: { $0.state.view = $1 }))
        followers.add(follow(self, read: { $0.repo.presenceUnrecorded }, apply: { $0.state.presenceUnrecorded = $1 }))
        // IOS-PLAN §6.6: the PIN kept for the password-only retry is forgotten when the app leaves the front (the app, not
        // this screen); then the same screen asks for both.
        followers.add(follow(self, read: { $0.repo.inFront }, apply: { if !$1 { $0.dropKeptPin() } }))
        // VAULT-MESSAGING §3.6.4: the tenth failed check locks the vault, whether or not `vault.locking` has arrived.
        followers.add(follow(
            self, read: { $0.repo.lockedByOwnerCheck }, apply: { if $1 { $0.enterLocked() } else { $0.state.locked = false } }
        ))
    }

    /// The accepted PIN, the password and the lines that depend on them go; the screen asks for both again.
    private func dropKeptPin() {
        state.pin = ""
        state.password = ""
        state.pinKept = false
        state.unlockedOpen = false
    }

    /// Locked by failed checks: only the lock text shows, never "Your vault is unlocked" beside it, and no check is sent.
    private func enterLocked() {
        dropKeptPin()
        state.locked = true
        state.unlockedWrong = nil
        state.message = nil
    }

    deinit {
        followers.cancelAll()
        ticker?.cancel()
    }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        let id = nextWork
        nextWork += 1
        work[id] = Task { [weak self] in
            await body()
            self?.work[id] = nil
        }
    }

    /// TEST ONLY: returns once the model's tasks have run.
    func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            while let (id, task) = work.first {
                await task.value
                work[id] = nil
            }
        }
    }

    /// Opens the screen for [mode], with nothing entered; a check sent right after an unlock says how it went.
    public func start(_ mode: OwnerCheckMode) {
        ticker?.cancel()
        let after = repo.unlockCheckOutcome
        repo.consumeUnlockCheckOutcome()
        state = OwnerCheckScreenState(mode: mode, view: repo.ownerCheck, timeScale: repo.timeScale)
        state.message = after.flatMap(Self.message)
        state.presenceUnrecorded = repo.presenceUnrecorded
        // A check that failed on the password right after the unlock: the PIN is kept, the password asked (§3.6.5).
        let retry = mode == .gated && (after.map(Self.isRetry) ?? false)
        let kept = retry ? repo.takeUnlockPin() : nil
        if let kept {
            state.pin = kept
            state.pinKept = true
            if case .badPassword(let left)? = after, let left, left > 0 {
                state.unlockedWrong = left
                state.message = nil
            }
            if case .backoff? = after { state.unlockedOpen = true }
        }
        if repo.lockedByOwnerCheck { enterLocked() }
        if case .backoff(let wait)? = after { startBackoff(wait) }
        launch { [repo] in try? await repo.refreshOwnerCheck() }
    }

    /// Leaves the screen without a check (not while gated): forgets what was entered.
    public func cancel() {
        ticker?.cancel()
        let s = state
        state = OwnerCheckScreenState(mode: s.mode, view: s.view)
        state.presenceUnrecorded = s.presenceUnrecorded
    }

    public func acknowledgePresence() {
        if state.passedUnrecorded { state.passed = true }
    }

    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(OwnerCheckScreenState.maxPin))
        state.message = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.message = nil
    }

    public func setHoldOff(_ choice: HoldOffChoice) { state.holdOff = choice }

    public func forgetSecrets() { dropKeptPin() }

    public func submit() {
        let s = state
        guard s.submitAllowed else {
            // Refused here: a PIN handed over for it does not stay in memory (the one kept for the retry stays).
            if !s.pinKept { state.pin = "" }
            return
        }
        let holdOff: HoldOff? = s.mode == .holdOff
            ? HoldOff(until: s.holdOff.days.map { now().addingTimeInterval(Double($0) * 86_400) }) : nil
        state.busy = true
        state.message = nil
        launch { [self] in
            let r: OwnerCheckOutcome
            do {
                r = try await repo.check(pin: s.pin, password: s.password, holdOff: holdOff)
            } catch let e as VaultFailure {
                r = .failed(e.kind, code: e.code)
            } catch {
                r = .failed(.other, code: nil)
            }
            // §3.6.5: neither entry is kept beyond the answer. §11.14.5: a check that passed without the presence recorded
            // keeps the screen, with the notice, until the member goes on.
            let passed = r == .passed
            let unrecorded = passed && repo.presenceUnrecorded
            // The unlock's PIN stays for another try of the password only after a wrong password (a try left), a backoff or
            // a failure that never reached the vault's verdict; it is not kept once the vault locked.
            // Decided from the state as it is now: a PIN dropped while the check was on its way (the app left the front) does
            // not come back when the answer lands.
            let keep = state.pinKept && Self.keepsPin(r) && !repo.lockedByOwnerCheck && repo.inFront
            var left: Int?
            if keep, case .badPassword(let n) = r, let n, n > 0 { left = n }
            state.busy = false
            state.pin = keep ? state.pin : ""
            state.password = ""
            state.passed = passed && !unrecorded
            state.passedUnrecorded = unrecorded
            if passed { state.presenceUnrecorded = repo.presenceUnrecorded }
            state.pinKept = keep
            state.unlockedWrong = left
            state.unlockedOpen = keep && Self.isBackoff(r)
            state.message = left != nil ? nil : Self.message(r)
            if case .backoff(let wait) = r { startBackoff(wait) }
            if repo.lockedByOwnerCheck { enterLocked() }
        }
    }

    public func lockVault() {
        guard !state.locking else { return }
        state.locking = true
        // The kept PIN goes with the lock; a lock that fails leaves the screen asking for both again.
        dropKeptPin()
        launch { [self] in
            do {
                try await vault.lock()
            } catch {
                state.locking = false
            }
        }
    }

    /// A check that failed on the password or backed off, right after the unlock.
    static func isRetry(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword, .backoff: true
        default: false
        }
    }

    static func isBackoff(_ r: OwnerCheckOutcome) -> Bool {
        if case .backoff = r { return true }
        return false
    }

    /// Whether the kept PIN stays after the answer [r] to a retry: a wrong password, a backoff, or a failure that is not the
    /// vault's verdict on the entries.
    static func keepsPin(_ r: OwnerCheckOutcome) -> Bool {
        switch r {
        case .badPassword, .backoff, .failed: true
        default: false
        }
    }

    static func message(_ r: OwnerCheckOutcome) -> OwnerCheckMessage? {
        switch r {
        case .passed: nil
        case .badPin(let left): .badPin(checksLeft: left)
        case .badPassword(let left): .badPassword(checksLeft: left)
        case .backoff: .backoff
        case .failed(let kind, let code): .failed(kind, code: code)
        }
    }

    private func startBackoff(_ seconds: Int64) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        state.waitSeconds = seconds
        let tick = tick
        ticker = Task { @MainActor [weak self] in
            while (self?.state.waitSeconds ?? 0) > 0 {
                do {
                    try await tick()
                } catch {
                    return
                }
                guard let self else { return }
                state.waitSeconds = max(state.waitSeconds - 1, 0)
            }
        }
    }
}

/// What the app's shell shows of the daily owner check (§3.6.5) at one moment: re-read as time passes, so that the deadline
/// gates on its own. Mirrors vettid-android `OwnerCheckGateState`.
public struct OwnerCheckGate: Equatable, Sendable {
    /// Past the deadline: the check comes before any other use of the app (never over an action in progress).
    public var gated: Bool
    /// Within the hour before the deadline: the early warning, with "check now".
    public var warning: Bool
    /// The hold is off (§3.6.7): the persistent indicator, with its end date if any.
    public var holdOff: Bool
    public var deadline: Date?
    public var holdOffUntil: Date?
    /// Unread `owner_check.*` feed items (the feed comes with I2.3).
    public var notices: [OwnerCheckNotice]
    /// (Release R, §11.14.5) The vault could not record that the member was here: the presence notice.
    public var presenceUnrecorded: Bool
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale now, for the presence notice's quiet period and the note.
    public var timeScale: UInt64 = 1

    public init(
        gated: Bool,
        warning: Bool,
        holdOff: Bool,
        deadline: Date? = nil,
        holdOffUntil: Date? = nil,
        notices: [OwnerCheckNotice] = [],
        presenceUnrecorded: Bool = false
    ) {
        self.gated = gated
        self.warning = warning
        self.holdOff = holdOff
        self.deadline = deadline
        self.holdOffUntil = holdOffUntil
        self.notices = notices
        self.presenceUnrecorded = presenceUnrecorded
    }

    public static func of(
        _ v: OwnerCheckView?,
        now: Date,
        notices: [OwnerCheckNotice] = [],
        presenceUnrecorded: Bool = false,
        timeScale: UInt64 = 1
    ) -> OwnerCheckGate {
        var g = OwnerCheckGate(
            gated: v?.gated(now) == true, warning: v?.warning(now) == true, holdOff: v?.holdOff(now) == true,
            deadline: v?.deadline, holdOffUntil: v?.holdOffUntil, notices: notices, presenceUnrecorded: presenceUnrecorded
        )
        g.timeScale = timeScale
        return g
    }

    /// The presence notice's quiet period (§11.14.5) at the vault's time scale on a scaled vault ("3 hours" on staging);
    /// nil in real time, where the notice says the approved "three days" (the owner's decision of 2026-10-19).
    public var scaledQuietText: String? { TimeScales.scaledText(TimeScales.recoveryQuiet, by: timeScale) }

    /// How long before the deadline the early warning starts (§3.6.5, S2) on a scaled vault ("150 seconds" on staging);
    /// nil in real time, where the warning says the approved "within the hour".
    public var scaledWarningText: String? { TimeScales.scaledText(TimeScales.ownerCheckWarning, by: timeScale) }

    /// "Staging: 1 day = 1 hour" on a staging vault; nil otherwise.
    public var stagingNote: String? { TimeScales.stagingNote(timeScale) }

    /// The early warning shows: within the hour before the deadline, not past it.
    public var warningShown: Bool { warning && !gated }

    /// Whether the shell's owner-check banners show anything (vettid-android `bannerShown`).
    public var bannerShown: Bool { !notices.isEmpty || warningShown || holdOff || presenceUnrecorded }
}
