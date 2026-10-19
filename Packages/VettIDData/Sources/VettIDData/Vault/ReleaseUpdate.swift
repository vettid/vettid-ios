import Foundation
import Observation

// The proactive release update (RELEASE-UPDATES §2; VAULT-MESSAGING §11.10.3, §11.10.4, §11.10.6): the offer the app
// shows, the one-step update's steps and outcome, and what it needs from the vault. Mirrors vettid-android
// `core/data/.../vault/ReleaseUpdate.kt`.

/// What the release notice says (ANDROID-PLAN "Vault update"). Mirrors vettid-android `UpdateNoticeKind`.
public enum UpdateNoticeKind: Equatable, Sendable {
    /// A newer `active` release is listed.
    case available
    /// The vault's release is `retired`, or `deprecated` with an `ends_at`: the warning with the end date.
    case ending
    /// The vault's release is `removed` and open only for a rescue (§11.10.5): only the move is offered.
    case ended
}

/// An update the member can approve (VAULT-MESSAGING §11.10.3, §11.10.6): the manifest the app trusts (the published
/// one, or an installed canary manifest under the selection rule of §11.10.1) lists an `active` release newer than
/// [current], the release this phone last unlocked into. Mirrors vettid-android `ReleaseUpdateOffer`.
public struct ReleaseUpdateOffer: Equatable, Sendable {
    public static let statusActive = "active"
    public static let statusDeprecated = "deprecated"
    public static let statusRetired = "retired"
    public static let statusRemoved = "removed"

    public var current: ReleaseView
    public var target: ReleaseView
    /// The manifest's releases between [current] and [target]: What's new lists their summaries.
    public var between: [ReleaseView]

    public init(current: ReleaseView, target: ReleaseView, between: [ReleaseView] = []) {
        self.current = current
        self.target = target
        self.between = between
    }

    public var kind: UpdateNoticeKind {
        switch current.status {
        case Self.statusRemoved: .ended
        case Self.statusRetired: .ending
        case Self.statusDeprecated where current.endsAt != nil: .ending
        default: .available
        }
    }

    /// The current release's end, shown for `deprecated` and `retired` releases (§11.10.1 `ends_at`).
    public var endsAt: Date? { current.endsAt }

    /// The offer for a vault sealed to [sealed] when [newest] is the manifest's newest `active` release; or none.
    public static func of(sealed: ReleaseView?, newest: ReleaseView?, between: [ReleaseView] = []) -> ReleaseUpdateOffer? {
        guard let sealed, let newest, newest.status == statusActive, newest.number > sealed.number else { return nil }
        return ReleaseUpdateOffer(
            current: sealed, target: newest, between: between.filter { $0.number > sealed.number && $0.number < newest.number }
        )
    }
}

/// One unlock of the update (``VaultManager`` in the app; a fake in tests). Mirrors vettid-android `UpdateStepResult`.
public enum UpdateStepResult: Equatable, Sendable {
    /// Unlocked, without an `update` member.
    case opened
    /// `update: moved`: the vault is sealed to the target and locked itself (§11.10.4 step 8).
    case moved
    /// `update: abandoned`: back on the previous release, unlocked (§11.10.4).
    case abandoned
    /// Unlocked, the update refused with [code] (`target`, `downgrade`, `approval`, `seal_key`, `pending`, `write`).
    case refused(String)
    case badPin(retryAfterSeconds: Int64)
    case backoff(retryAfterSeconds: Int64)
    case failed(FailureKind, code: String?, retryAfterSeconds: Int64 = 0)
}

/// What the update needs from the vault. Mirrors vettid-android `ReleaseUpdateOps`.
@MainActor
public protocol ReleaseUpdateOps: AnyObject {
    /// The offer for the vault as this phone knows it, from the manifest it trusts; nil for none.
    func offer() async throws -> ReleaseUpdateOffer?

    /// The owner check is due or held (§3.6.5): the check comes first, the update never bypasses it.
    func ownerCheckDue() -> Bool

    /// Locks the vault and waits (bounded) until the member API no longer sees it unlocked.
    func lock() async throws

    /// One unlock with [pin]: approving [approve] (§11.10.3) when non-nil, or abandoning the unconfirmed move ([abandon],
    /// §11.10.4); never following a move by itself. [onStarting] hears `503 release_starting`.
    func unlock(pin: String, approve: ReleaseView?, abandon: Bool, onStarting: @escaping @MainActor () -> Void) async -> UpdateStepResult

    /// An unconfirmed move can be abandoned: this phone knows the release it moved from.
    func canAbandon() -> Bool

    /// The release number this phone last unlocked into (0 when it has none).
    func releaseNumber() -> UInt64

    /// (VAULT-MESSAGING §11.14.9) Why the update is held, in the change gate's words (``FailureKind/changeChecking``,
    /// ``FailureKind/changeUnresolved``): a PIN or password change is undecided, or on its way. The update then neither
    /// starts nor retries nor abandons: its lock and unlock would send a PIN that may be the wrong one of two. Nil when
    /// it is not held.
    func changeHold() -> FailureKind?
}

public extension ReleaseUpdateOps {
    func changeHold() -> FailureKind? { nil }
}

/// The member dismissed the notice of [release] ([kind]) at [at]. Mirrors vettid-android `ReleaseDismissal`.
public struct ReleaseDismissal: Equatable, Sendable {
    public var release: UInt64
    public var kind: UpdateNoticeKind
    public var at: Date

    public init(release: UInt64, kind: UpdateNoticeKind, at: Date) {
        self.release = release
        self.kind = kind
        self.at = at
    }
}

/// When the shell shows the release banner. Mirrors vettid-android `ReleaseNotices` (the local notification comes with
/// phase P, IOS-PLAN §6.7).
public enum ReleaseNotices {
    /// A dismissed banner comes back after 24 h, whatever the kind (owner decision 2026-10-09).
    public static let dismissFor: TimeInterval = 24 * 3600

    /// Whether the banner shows for [offer] at [now]: always without a dismissal of this release and kind (a notice that
    /// turns from "available" into an end-date warning shows again), and again ``dismissFor`` after one. A dismissal "in
    /// the future" (the clock was set back) does not hide it either.
    public static func bannerVisible(_ offer: ReleaseUpdateOffer?, _ dismissal: ReleaseDismissal?, now: Date) -> Bool {
        guard let offer else { return false }
        guard let d = dismissal, d.release == offer.target.number, d.kind == offer.kind else { return true }
        return now < d.at || now >= d.at.addingTimeInterval(dismissFor)
    }
}

/// A request to open the update screen once the vault is open (on Android, a tap on the "Vault updates" notification;
/// on the iPhone its notification comes with phase P, IOS-PLAN §6.7). Mirrors vettid-android `ReleaseUpdateInbox`.
@MainActor
@Observable
public final class ReleaseUpdateInbox {
    public private(set) var pending = false

    public init() {}

    public func offer() { pending = true }

    public func consume() { pending = false }
}

/// Where the one-step update stands (owner decision 2026-10-09). Mirrors vettid-android `UpdateStep`.
public enum UpdateStep: Equatable, Sendable {
    /// Locking the vault before the unlock that carries the approval.
    case locking
    /// The unlock with the approved `release_update` is out.
    case approving
    /// Moved: the unlock that reaches the new release is out.
    case reopening
    /// The vault runs the new release and is open.
    case done
    /// The vault refused the update; it stayed on its release and is open again.
    case refused
    /// The PIN was wrong (or the enclave's backoff runs): the vault is locked on its release; nothing moved.
    case badPin
    /// Nothing moved, but the update did not go through (network, service); the vault may be locked.
    case failed
    /// Moved, but the new release did not open the vault: try again, or return to the previous release.
    case newReleaseFailed
    /// Returning to the previous release (§11.10.4 abandonment).
    case abandoning
    /// Back on the previous release, open.
    case abandoned

    /// A step that runs (no input from the member).
    public var running: Bool { [.locking, .approving, .reopening, .abandoning].contains(self) }
}

/// The update's state for the screens. The PIN is never part of it. Mirrors vettid-android `UpdateProgress`.
public struct UpdateProgress: Equatable, Sendable {
    public var step: UpdateStep
    public var from: ReleaseView
    public var to: ReleaseView
    /// The routed release is starting (`503 release_starting`, §11.10.5): the wait may take minutes.
    public var starting = false
    public var refusal: String?
    public var failure: FailureKind?
    public var failureCode: String?
    /// Seconds the enclave's backoff asks to wait before the next PIN (§11.8).
    public var waitSeconds: Int64 = 0
    /// The vault is open (on [from] after a refusal or an abandonment, on [to] when done).
    public var vaultOpen = false
    /// "Return to release N" is offered (only while the move is unconfirmed).
    public var canAbandon = false

    public init(
        step: UpdateStep, from: ReleaseView, to: ReleaseView, failure: FailureKind? = nil, waitSeconds: Int64 = 0,
        canAbandon: Bool = false
    ) {
        self.step = step
        self.from = from
        self.to = to
        self.failure = failure
        self.waitSeconds = waitSeconds
        self.canAbandon = canAbandon
    }

    /// A step that waits for the member (a PIN, a choice, or "Continue").
    public var waiting: Bool { !step.running }
}

/// The proactive release update: the offer the shell and Settings show, and the one-step update. Mirrors vettid-android
/// `ReleaseUpdateRepository`.
@MainActor
public protocol ReleaseUpdateRepository: AnyObject, Observable, Sendable {
    var offer: ReleaseUpdateOffer? { get }

    /// ``offer`` has been read from the manifest at least once in this process (before that, nil means "not known").
    var offerKnown: Bool { get }

    /// Non-nil while an update is under way or its outcome is shown; the root shows it over every phase.
    var progress: UpdateProgress? { get }

    /// (§11.14.9) Why the update is held while a PIN or password change is undecided; nil when it is not.
    var changeHold: FailureKind? { get }

    /// The banner's last dismissal (in memory: after a restart the banner shows again; chosen; not in the spec, where
    /// vettid-android keeps it in its preferences).
    var dismissal: ReleaseDismissal? { get }

    /// The member closed the banner at [at]: hidden for ``ReleaseNotices/dismissFor`` at most.
    func dismissBanner(at: Date)

    /// Reads the offer again (the manifest; quiet on failure: the last offer stays).
    func refreshOffer() async

    /// Whether the owner check must come first (§3.6.5).
    func ownerCheckDue() -> Bool

    /// The member approved [offer] with [pin] ("Approve and update"): locks, unlocks with the approval, and after `moved`
    /// unlocks again with the same PIN. False when it cannot start (an update runs, or the check is due).
    func start(pin: String, offer: ReleaseUpdateOffer) -> Bool

    /// ``UpdateStep/badPin`` or ``UpdateStep/failed``: the approved update again; ``UpdateStep/newReleaseFailed``: the
    /// unlock again.
    func retry(pin: String)

    /// ``UpdateStep/newReleaseFailed`` with ``UpdateProgress/canAbandon``: back to the previous release (§11.10.4).
    func abandon(pin: String)

    /// Leaves the outcome (or gives up): the app follows the vault's phase again. Ignored while a step runs.
    func finish()
}
