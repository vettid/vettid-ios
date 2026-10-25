import Foundation
import Observation
import VettIDCrypto

/// The vault's owner-check state (VAULT-MESSAGING §3.6, `vault.status` `owner_check.state`). Mirrors vettid-android
/// `OwnerCheckState`.
public enum OwnerCheckState: String, Codable, Equatable, Sendable {
    /// Before the deadline.
    case ok
    /// Past the deadline with the hold off (§3.6.7): the app is gated all the same; the rest of the vault runs.
    case due
    /// Past the deadline with the hold on (§3.6.3).
    case held
}

/// `vault.held`'s counts of what arrived since the deadline (§3.6.3): no names, no content.
public struct WaitingCounts: Codable, Equatable, Sendable {
    public var messages: Int
    public var requests: Int
    public var calls: Int
    public var other: Int

    public init(messages: Int = 0, requests: Int = 0, calls: Int = 0, other: Int = 0) {
        self.messages = messages
        self.requests = requests
        self.calls = calls
        self.other = other
    }

    public var isEmpty: Bool { messages == 0 && requests == 0 && calls == 0 && other == 0 }
}

/// The daily owner check as this app knows it (§3.6): from `vault.status`, the check's answers, `vault.held`,
/// `sync.event{owner_check}` and `owner_check_required` refusals; kept on the phone so that a locked vault past its
/// deadline can ask for the PIN and the password on one screen (§3.6.5). Mirrors vettid-android `OwnerCheckView`.
public struct OwnerCheckView: Equatable, Sendable {
    public static let maxFailures = 10
    /// `owner_check.interval_seconds`: 1–24 h (§3.6.2).
    public static let minIntervalSeconds: Int64 = 3_600
    public static let maxIntervalSeconds: Int64 = 86_400
    /// The longest a hold may stay off (§3.6.7).
    public static let maxHoldOff: TimeInterval = 30 * 86_400
    /// §3.6.5: the reference app warns from 1 h ahead (divided by ``timeScale``, STAGING-TIME-SCALE S2).
    public static let warningAhead: TimeInterval = TimeScales.ownerCheckWarning

    public var state: OwnerCheckState
    public var deadline: Date?
    public var intervalSeconds: Int64
    /// Consecutive failed checks (§3.6.4); at ``maxFailures`` the vault locks.
    public var failures: Int
    /// `owner_check.hold` (§3.6.7).
    public var hold: Bool
    /// When a hold turned off comes back on by itself; nil: until the member turns it on.
    public var holdOffUntil: Date?
    /// The latest `vault.held` counts, while gated; nil: the vault has not said (never zero for unknown).
    public var waiting: WaitingCounts?
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale when this deadline was learnt: the early warning starts
    /// ``warningAhead`` divided by it before the deadline, and keeps that time if the scale changes later.
    public var timeScale: UInt64
    /// (VAULT-MESSAGING §3.6.8, release L) When the vault locks itself if no check is passed, as it last said
    /// (`vault.status`, `vault.held`); nil from a vault before L, and until it said again after a check moved the deadline.
    public var idleLockAt: Date?

    public init(
        state: OwnerCheckState,
        deadline: Date?,
        intervalSeconds: Int64 = OwnerCheckView.maxIntervalSeconds,
        failures: Int = 0,
        hold: Bool = true,
        holdOffUntil: Date? = nil,
        waiting: WaitingCounts? = nil,
        timeScale: UInt64 = TimeScale.real,
        idleLockAt: Date? = nil
    ) {
        self.state = state
        self.deadline = deadline
        self.intervalSeconds = intervalSeconds
        self.failures = failures
        self.hold = hold
        self.holdOffUntil = holdOffUntil
        self.waiting = waiting
        self.timeScale = timeScale
        self.idleLockAt = idleLockAt
    }

    /// How long past the deadline the vault locks itself, as it last said (``idleLockAt`` less ``deadline``, on the vault's
    /// clock and in its time); nil when either is not known.
    public var idleAfterSeconds: Int64? {
        guard let idleLockAt, let deadline else { return nil }
        let s = Int64(idleLockAt.timeIntervalSince(deadline).rounded())
        return s > 0 ? s : nil
    }

    /// Past the deadline: the app may send only the check (§3.6.3), whether or not the hold is on.
    public func gated(_ now: Date) -> Bool { state != .ok || deadline.map { now >= $0 } == true }

    /// From ``warningAhead`` (at ``timeScale``) before the deadline until it (§3.6.5).
    public func warning(_ now: Date) -> Bool {
        guard let deadline, !gated(now) else { return false }
        return now >= deadline.addingTimeInterval(-TimeScale.scaled(Self.warningAhead, by: timeScale))
    }

    /// The check interval at ``timeScale``: what the member waits between checks (the setting stays in real units,
    /// STAGING-TIME-SCALE §3 rule 3).
    public var scaledIntervalSeconds: TimeInterval { TimeScale.scaled(TimeInterval(intervalSeconds), by: timeScale) }

    /// Whether the hold is off now (an end date in the past means it came back on).
    public func holdOff(_ now: Date) -> Bool { !hold && (holdOffUntil.map { now < $0 } ?? true) }

    /// Failed checks left before the vault locks (10 − `failures`, §3.6.5).
    public var checksLeft: Int { max(Self.maxFailures - failures, 0) }
}

/// (VAULT-MESSAGING §3.6.8, release L) The vault locked itself because no check was passed in time
/// (`vault.locking{reason: "idle"}`, or, without the notice, a locked vault past the ``OwnerCheckView/idleLockAt`` the app
/// last read). ``afterSeconds``: how long past the deadline that was, when known ("You hadn't checked in for 7 days").
/// Mirrors vettid-android `IdleLocked`.
public struct IdleLocked: Equatable, Sendable, Codable {
    public let afterSeconds: Int64?

    public init(afterSeconds: Int64?) { self.afterSeconds = afterSeconds }
}

/// (Release L) `idle_lock.after_seconds` (§10.8), as the app knows it: ``seconds`` is what is set; ``inForceSeconds`` what
/// the vault uses until the next successful check when a longer value was set since the last one (the vault keeps the
/// lowest value since then; owner decision 2026-10-23), else ``seconds``. Mirrors vettid-android `IdleLockSetting`.
public struct IdleLockSetting: Equatable, Sendable {
    public let seconds: Int64
    public let inForceSeconds: Int64

    public init(seconds: Int64, inForceSeconds: Int64? = nil) {
        self.seconds = seconds
        self.inForceSeconds = inForceSeconds ?? seconds
    }

    /// A longer value than the one in force was set: it takes effect after the next check.
    public var afterNextCheck: Bool { seconds > inForceSeconds }

    /// 1 hour to 30 days, default 7 days, no "never" (§3.6.8, VAULT-LOCK L11, L12).
    public static let minSeconds: Int64 = 3_600
    public static let maxSeconds: Int64 = 2_592_000
    public static let defaultSeconds: Int64 = 604_800
    /// The choices (ANDROID-PLAN §4 "Locking the vault" part 2): 1 hour, 1 day, 7 days, 14 days, 30 days.
    public static let choices: [Int64] = [3_600, 86_400, 604_800, 1_209_600, 2_592_000]
}

/// The answer to a check (§3.6.1). Mirrors vettid-android `OwnerCheckOutcome`.
public enum OwnerCheckOutcome: Equatable, Sendable {
    case passed
    /// The PIN was wrong ([checksLeft] before the vault locks, when known).
    case badPin(checksLeft: Int?)
    /// The PIN was right and the password wrong.
    case badPassword(checksLeft: Int?)
    /// A PIN or password backoff runs; [retryAfterSeconds] 0 when the vault did not say how long.
    case backoff(retryAfterSeconds: Int64)
    case failed(FailureKind, code: String?)
}

/// An `owner_check.*` activity-feed item (§3.6.4, §3.6.7) the app shows once the vault is open. The feed that fills them
/// comes with the Notifications screen (IOS-PLAN §8 I2.3). Mirrors vettid-android `OwnerCheckNotice`.
public struct OwnerCheckNotice: Equatable, Sendable {
    public let itemID: String
    /// `owner_check.failed`, `owner_check.locked` or `owner_check.hold_changed`.
    public let kind: String
    /// `pin` / `password`, the failure count, or `on` / `off` / `off_until:<ts>` / `on:expired`.
    public let ref: String?
    public let at: Date?
    public let urgent: Bool

    public init(itemID: String, kind: String, ref: String?, at: Date?, urgent: Bool) {
        self.itemID = itemID
        self.kind = kind
        self.ref = ref
        self.at = at
        self.urgent = urgent
    }
}

/// Turning the hold off (§3.6.7): [until] at most 30 days ahead, or nil (until the member turns it on).
public struct HoldOff: Equatable, Sendable {
    public let until: Date?

    public init(until: Date?) { self.until = until }
}

/// The daily owner check (§3.6) for the app's screens. Every failure is a ``VaultFailure`` or an ``OwnerCheckOutcome``.
/// Mirrors vettid-android `OwnerCheckRepository`.
@MainActor
public protocol OwnerCheckRepository: AnyObject, Observable, Sendable {
    /// Nil until the vault reported its owner check.
    var ownerCheck: OwnerCheckView? { get }

    /// The vault locked after ten consecutive failed checks (`vault.locking{reason: "owner_check"}`, §3.6.4).
    var lockedByOwnerCheck: Bool { get }

    /// (Release L, §3.6.8) The vault locked itself (`vault.locking{reason: "idle"}`); nil otherwise. Kept on the phone until
    /// the next unlock. Without the notice, see ``idleLockedNow(_:)``. Default: nil.
    var idleLocked: IdleLocked? { get }

    /// (Release L) The idle-lock setting; nil for a vault that does not have it (before L) or before it was read
    /// (``refreshIdleLockSetting()``). Default: nil.
    var idleLockSetting: IdleLockSetting? { get }

    /// (Release L) Why the locked vault is locked, if it locked itself: the notice (``idleLocked``), or, lacking it (the
    /// phone was off), a time past the ``OwnerCheckView/idleLockAt`` the app last read ("the app says why from the notice
    /// or, lacking it, from `idle_lock_at` as it last read it", §3.6.8), unless the member locked the vault on this phone
    /// since or it locked for another reason (``onLockedHere()``).
    func idleLockedNow(_ now: Date) -> IdleLocked?

    /// (Release L) The member locked the vault on this phone: a later unlock screen does not say it locked itself.
    func onLockedHere()

    /// Reads `idle_lock.after_seconds` (`settings.get`); quiet for a vault before L, which does not list it.
    func refreshIdleLockSetting() async throws

    /// Sets `idle_lock.after_seconds` (one of ``IdleLockSetting/choices``): a shorter value applies at once, a longer one
    /// from the next successful check (§3.6.8).
    func setIdleLockAfter(seconds: Int64) async throws

    /// The answer to the check sent right after an unlock past the deadline, for the check screen to show.
    var unlockCheckOutcome: OwnerCheckOutcome? { get }

    /// Unread `owner_check.*` feed items. Default: none.
    var notices: [OwnerCheckNotice] { get }

    /// Re-reads `vault.status`.
    func refreshOwnerCheck() async throws

    /// Sends the check with [pin] and [password]. [holdOff] turns the hold off (§3.6.7), until its date or, without
    /// one, until the member turns it on.
    func check(pin: String, password: String, holdOff: HoldOff?) async throws -> OwnerCheckOutcome

    /// `owner_check.interval_seconds` (§3.6.2): shorter at once, longer from the next check.
    func setCheckInterval(seconds: Int64) async throws

    /// Turns the hold back on (`settings.set`, no check needed, §3.6.7).
    func turnHoldOn() async throws

    func consumeUnlockCheckOutcome()

    /// (Release R, §11.14.5) The last check passed but the vault could not record that the member was here
    /// (`recovery.present_recorded: false`): the presence notice shows until a later answer or `vault.status` says the
    /// presence was recorded. Default: false.
    var presenceUnrecorded: Bool { get }

    /// (Release R, ANDROID-PLAN "Other screens") An unlock that cancelled a recovery sent its owner check and that check
    /// did not pass: the owner-check screen is to be shown at once, so that the member's presence is recorded. Default:
    /// false.
    var checkAfterCancel: Bool { get }

    func consumeCheckAfterCancel()

    /// (STAGING-TIME-SCALE §5.2) The vault's time scale, for the screens' scaled times and the staging note. Default: 1.
    var timeScale: UInt64 { get }

    /// Marks the notices read.
    func dismissNotices() async throws
}

public extension OwnerCheckRepository {
    var idleLocked: IdleLocked? { nil }
    var idleLockSetting: IdleLockSetting? { nil }
    func onLockedHere() {}
    func refreshIdleLockSetting() async throws {}
    func setIdleLockAfter(seconds: Int64) async throws {}

    var notices: [OwnerCheckNotice] { [] }
    var presenceUnrecorded: Bool { false }
    var checkAfterCancel: Bool { false }
    var timeScale: UInt64 { 1 }
    func consumeCheckAfterCancel() {}
    func dismissNotices() async throws {}

    func check(pin: String, password: String) async throws -> OwnerCheckOutcome {
        try await check(pin: pin, password: password, holdOff: nil)
    }
}
