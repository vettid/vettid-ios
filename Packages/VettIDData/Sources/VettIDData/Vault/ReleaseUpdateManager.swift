import Foundation
import Observation

/// The one-step update (owner decision 2026-10-09): no manual lock. Locks the vault, sends the unlock with the approved
/// `release_update` (§11.10.3, built as the unlock screen's), and after `update: moved` unlocks again with the same PIN,
/// which reaches the new release (§11.10.6). Waits while a release starts (`503 release_starting`, ``maxStartRetries``
/// times beyond the member API client's own wait); a refusal leaves the vault on its release, unlocked again by that same
/// unlock; a new release that does not open the vault offers the way back while the move is unconfirmed (§11.10.4). The
/// PIN is held only while a step runs and dropped when it ends.
///
/// Nothing here sends an approval except ``start(pin:offer:)`` (and ``retry(pin:)`` of a start that failed before
/// anything moved): the offer, its refresh and the notices never touch the vault. Mirrors vettid-android
/// `ReleaseUpdateManager`.
@MainActor
@Observable
public final class ReleaseUpdateManager: ReleaseUpdateRepository {
    /// The member API's `503 release_starting` (§11.10.5).
    public nonisolated static let codeReleaseStarting = "release_starting"
    /// ``UpdateProgress/refusal`` when the vault opened without saying anything of the update.
    public nonisolated static let codeNotMoved = "not_moved"
    /// ``UpdateProgress/failureCode`` when a step was refused because a PIN or password change is undecided.
    public nonisolated static let codeChangeHeld = "change_held"
    /// Further waits after the API client's own: a release that cannot start is a failure.
    public nonisolated static let maxStartRetries = 5
    nonisolated static let maxStartWait: Int64 = 60
    nonisolated static let maxMovedAgain = 2

    public private(set) var offer: ReleaseUpdateOffer?
    public private(set) var offerKnown = false
    /// The vault opened and the manifest has not been read since (``vaultOpened()``).
    public private(set) var checking = false
    /// The check's last read failed, and how (it is read again, ``retryChecking(_:)``): the checking screen says it.
    public private(set) var checkFailure: FailureKind?
    /// The check's read failed at least once.
    public var checkFailed: Bool { checkFailure != nil }
    /// Told when ``holdsFeatures`` changes (not by ``clear()`` or ``vaultClosed()``): the vault manager reads the lists when
    /// it ends with the vault open.
    @ObservationIgnored public var onHoldsChange: (@MainActor (Bool) -> Void)?
    /// Told when a check that never failed ends with a read (one that failed is followed by ``onHoldsChange``).
    @ObservationIgnored public var onCheckEnded: (@MainActor () -> Void)?
    @ObservationIgnored private var lastHolds = false
    /// Counts the openings and the clears: a manifest read begun before the latest of them neither ends its check nor sets
    /// an offer.
    @ObservationIgnored private var generation = 0
    /// The next read while a check failed (``retryChecking(_:)``).
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Names each retry, so that one ending clears only its own handle (not a later one of the same check).
    @ObservationIgnored private var retryID = 0
    /// Between reads while a check fails: 2, 5, 15 and 30 seconds, then every minute.
    nonisolated static let checkRetries: [Int64] = [2, 5, 15, 30, 60]

    /// No release but the current one is used (owner decision 2026-11-17): the vault is not on the newest `active` release
    /// of the manifest this phone trusts. An offer counts only for the release the vault is on now: one read before the
    /// vault moved does not. While this holds, the vault's features take no event that only changes a list
    /// (``VaultManager/featuresGated()``), and their lists are read when it ends.
    public var behind: Bool {
        guard let o = offer else { return false }
        return o.current.number == ops.releaseNumber()
    }

    /// What the member sees and what can reach them: only the update and the ways to leave the vault, no call and no
    /// notification. While the vault is ``behind``, and also while the manifest is first read after an opening
    /// (``checking``), so that nothing of the open app shows before the release is known (the lists read meanwhile are
    /// neither shown nor acted on). A manifest that
    /// cannot be read or checked keeps the check, read again with a backoff until it is (owner decision 2026-11-17: fail
    /// closed); meanwhile only the ways to leave the vault are open.
    public var required: Bool { checking || behind }

    /// The vault's features take no event that only changes a list and read nothing (``VaultManager/featuresGated()``):
    /// while the vault is ``behind``, and while a check whose read failed goes on (``checkFailed``: it may last). During a
    /// check that has not failed, the opening's own reads run as before, shown and acted on only once it ends.
    public var holdsFeatures: Bool { behind || (checking && checkFailed) }

    /// The vault opened (an unlock, the end of onboarding, a start while open): ``required`` until the manifest is read.
    public func vaultOpened() {
        generation += 1
        retry?.cancel()
        retry = nil
        checking = true
        checkFailure = nil
        // Not told: the opening reads its lists itself (``VaultManager/onOpened()``); a lift told here would read them twice.
        lastHolds = holdsFeatures
    }

    /// The vault is no longer open (a lock, a sign-out): the check ends and is not read again; the next opening checks anew.
    /// Nothing is told: nothing is read for a vault that is not open.
    public func vaultClosed() {
        generation += 1
        retry?.cancel()
        retry = nil
        checking = false
        checkFailure = nil
        lastHolds = holdsFeatures
    }

    private func noteBehind() {
        let now = holdsFeatures
        guard now != lastHolds else { return }
        lastHolds = now
        onHoldsChange?(now)
    }
    public private(set) var progress: UpdateProgress?
    public private(set) var dismissal: ReleaseDismissal?

    @ObservationIgnored private let ops: any ReleaseUpdateOps
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var job: Task<Void, Never>?

    /// [sleep]: the wait between tries while a release starts (a virtual clock in the tests).
    public init(ops: any ReleaseUpdateOps, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.ops = ops
        self.sleep = sleep
    }

    public func refreshOffer() async {
        let begun = generation
        let read: ReleaseUpdateOffer??
        var failure: FailureKind = .network
        var error: (any Error)?
        do { read = .some(try await ops.offer()) } catch let e {
            read = nil
            error = e
            failure = (e as? VaultFailure)?.kind ?? .network
        }
        // Begun before the latest opening or clear: that one's own read decides.
        guard begun == generation else { return }
        guard let read else {
            // A failed read keeps the last offer (it counts only for the release the vault is on, ``behind``); during the
            // check it is tried again, the check kept, and the features held meanwhile.
            if checking {
                checkFailure = failure
                noteBehind()
                retryChecking(begun)
            } else if let error, Self.unverified(error) {
                // A manifest that no longer verifies, or no longer checks the vault's release, after this opening's check
                // passed: held as the first check is (fail closed), and read again. A read that could not reach the
                // manifest keeps the last verified answer.
                checking = true
                checkFailure = failure
                noteBehind()
                retryChecking(begun)
            }
            return
        }
        let ended = checking && checkFailure == nil
        offer = read
        offerKnown = true
        checking = false
        checkFailure = nil
        // The check is over: so are its retries (a later failure that holds again starts its own).
        retry?.cancel()
        retry = nil
        noteBehind()
        if ended { onCheckEnded?() }
    }

    /// The check's read failed: read again after the next wait, unless an opening or a clear came meanwhile.
    private func retryChecking(_ begun: Int) {
        guard retry == nil else { return }
        let waits = Self.checkRetries
        let sleep = self.sleep
        retryID += 1
        let id = retryID
        retry = Task { [weak self] in
            var attempt = 0
            while let self, self.checking, self.generation == begun, !Task.isCancelled {
                do { try await sleep(.seconds(waits[min(attempt, waits.count - 1)])) } catch { return }
                // Ended meanwhile (Try again, a foreground read): out of the loop, so that the handle is cleared below.
                guard self.checking, self.generation == begun else { break }
                attempt += 1
                await self.refreshOfferOnce(begun)
            }
            // Only this retry's own handle: a newer one's stays.
            if let self, self.retryID == id { self.retry = nil }
        }
    }

    /// Every failure but one that could not reach the manifest (``unreachable``): a manifest that did not verify (its
    /// signature, key or serial), one that cannot check the vault's release (not recorded, or listed under another number
    /// with nothing newer), or anything unexpected. As vettid-android's `ReleaseCheckFailure`.
    nonisolated static func unverified(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let f = error as? VaultFailure else { return true }
        return !unreachable.contains(f.kind)
    }

    /// The manifest, or the vault, could not be reached: the last verified answer stands.
    nonisolated static let unreachable: Set<FailureKind> = [
        .network, .offline, .noResponse, .manifestUnavailable, .vaultUnavailable, .servicePaused, .rateLimited,
        // No answer just after the clock went back (``VaultManager`` names it so): still no answer.
        .clockOff,
    ]

    /// The vault's release could not be checked against the manifest (``VaultManager/releaseOffer()``).
    public nonisolated static let codeReleaseUnchecked = "release_unchecked"

    /// One read of the check's retry.
    private func refreshOfferOnce(_ begun: Int) async {
        let read: ReleaseUpdateOffer?
        // (Not `try?`: a read that answered "nothing newer" is not a failed one.)
        do { read = try await ops.offer() } catch {
            // Only while this check goes on: a Try again that answered meanwhile ended it.
            if begun == generation, checking { checkFailure = (error as? VaultFailure)?.kind ?? .network }
            return
        }
        guard begun == generation else { return }
        offer = read
        offerKnown = true
        checking = false
        checkFailure = nil
        noteBehind()
    }

    public func ownerCheckDue() -> Bool { ops.ownerCheckDue() }

    public var changeHold: FailureKind? { ops.changeHold() }

    public func dismissBanner(at: Date) {
        guard let o = offer else { return }
        let hidden = TimeScales.scaled(ReleaseNotices.dismissFor, by: ops.timeScale())
        dismissal = ReleaseDismissal(release: o.target.number, kind: o.kind, at: at, hiddenFor: hidden)
    }

    /// A wipe or a forget of this phone's vault: no offer, no update, no dismissal is kept.
    public func clear() {
        job?.cancel()
        job = nil
        offer = nil
        offerKnown = false
        checking = false
        checkFailure = nil
        progress = nil
        dismissal = nil
        generation += 1
        retry?.cancel()
        retry = nil
        // Nothing is told: the vault is being wiped or forgotten, and no list is to be read for it.
        lastHolds = false
    }

    public var pinGeneration: Int { ops.pinGeneration() }

    public func start(pin: String, offer o: ReleaseUpdateOffer, generation: Int?) -> Bool {
        // Neither the owner check (§3.6.5) nor an undecided PIN or password change (§11.14.9) comes first.
        if running || ops.ownerCheckDue() || ops.changeHold() != nil || pin.isEmpty { return false }
        progress = UpdateProgress(step: .locking, from: o.current, to: o.target)
        // The PIN as the keypad took it: a change that moves which PIN the vault expects before an unlock goes out stops it.
        let pin = taken(pin, generation)
        // Checked before the lock too: a PIN taken before a change neither locks the vault nor is sent.
        if refusedAsTakenBefore(pin) || refusedWithoutUserGuid() { return true }
        launch { [self] in
            do {
                try await ops.lock()
            } catch {
                // Nothing changed: the vault was not locked, or not everywhere; the member decides again.
                failedBeforeMove(error, vaultOpen: true)
                return
            }
            await approve(pin, afterFailure: false)
        }
        return true
    }

    public func retry(pin: String, generation: Int?) {
        guard let p = progress, !running, !pin.isEmpty, !refusedWhileChangeHeld() else { return }
        let pin = taken(pin, generation)
        switch p.step {
        case .badPin:
            launch { [self] in await approve(pin, afterFailure: false) }
        case .failed:
            launch { [self] in
                if p.vaultOpen {
                    if refusedAsTakenBefore(pin) || refusedWithoutUserGuid() { return }
                    set { $0.step = .locking; $0.failure = nil; $0.failureCode = nil }
                    do {
                        try await ops.lock()
                    } catch {
                        failedBeforeMove(error, vaultOpen: true)
                        return
                    }
                }
                await approve(pin, afterFailure: true)
            }
        case .newReleaseFailed:
            launch { [self] in await reopen(pin) }
        default:
            break
        }
    }

    public func abandon(pin: String, generation: Int?) {
        guard let p = progress, !running, !pin.isEmpty, p.step == .newReleaseFailed, p.canAbandon, ops.canAbandon(),
              !refusedWhileChangeHeld()
        else { return }
        let pin = taken(pin, generation)
        launch { [self] in await wayBack(pin) }
    }

    public func returnToPrevious(pin: String, generation: Int?) -> Bool {
        guard !running, !pin.isEmpty, let m = ops.unconfirmedMove(), m.failed, !ops.ownerCheckDue(), ops.changeHold() == nil else {
            return false
        }
        progress = UpdateProgress(step: .abandoning, from: m.from, to: m.to, canAbandon: true)
        let pin = taken(pin, generation)
        launch { [self] in await wayBack(pin) }
        return true
    }

    /// The way back (§11.10.4): `abandoned`, or N's `refused` `downgrade` (no move was pending any more), is back on
    /// release N and open; `wrong_release` and N unavailable end it (IOS-PLAN §4.3 point 4).
    private func wayBack(_ pin: TakenPin) async {
        set { $0.step = .abandoning; $0.failure = nil; $0.failureCode = nil }
        let r = await withStart { s in await self.ops.unlock(pin: pin, approve: nil, abandon: true, afterMove: false, onStarting: s) }
        switch r {
        case .abandoned, .opened, .refused("downgrade"):
            set { $0.step = .abandoned; $0.vaultOpen = true; $0.canAbandon = false }
        case .failed(let kind, let code, _) where code == VaultManager.codeReturnConfirmed || code == VaultManager.codeReturnUnavailable:
            set { $0.step = .returnEnded; $0.failure = kind; $0.failureCode = code; $0.vaultOpen = false; $0.canAbandon = false }
        default:
            newReleaseFailed(r)
        }
    }

    public func finish() {
        // Never in the middle of an unlock: its answer decides what the vault is.
        if running { return }
        job = nil
        let done = progress?.step == .done
        progress = nil
        if done { offer = nil }
        noteBehind()
    }

    /// TEST ONLY: returns once the running step has ended.
    public func settle() async { await job?.value }

    // MARK: - Steps

    private var running: Bool { progress?.step.running == true }

    /// [pin] with the generation of which PIN the vault expects when the keypad opened ([generation]), else read as the
    /// screen hands it over.
    private func taken(_ pin: String, _ generation: Int?) -> TakenPin {
        TakenPin(pin: pin, generation: generation ?? ops.pinGeneration())
    }

    /// (§11.14.9 step 2; chosen; not in the spec) [pin] was taken before something moved which PIN the vault expects: the
    /// step fails at once, before any lock, with nothing sent (``VaultManager/codePinTakenBefore``); the vault is as it
    /// was (open), and the PIN is asked for again.
    private func refusedAsTakenBefore(_ pin: TakenPin) -> Bool {
        guard pin.generation != ops.pinGeneration() else { return false }
        set {
            $0.step = .failed
            $0.failure = .credentialUnsettled
            $0.failureCode = VaultManager.codePinTakenBefore
            $0.vaultOpen = true
        }
        return true
    }

    /// (§11.14.9) A change is undecided: nothing is sent, and the step says "still checking".
    private func refusedWhileChangeHeld() -> Bool {
        guard let why = ops.changeHold() else { return false }
        set { $0.failure = why; $0.failureCode = Self.codeChangeHeld }
        return true
    }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        job = Task { @MainActor in await body() }
    }

    private func set(_ f: (inout UpdateProgress) -> Void) {
        guard var p = progress else { return }
        f(&p)
        progress = p
    }

    /// §6.7.1: without the vault's `user_guid` the unlock refuses, so the vault is not locked first: the update fails as
    /// the unlock would have failed it (`no_user_guid`), before this attempt's lock and with nothing sent (the vault as the
    /// step before left it: open, unless a lock that went out and failed left it otherwise).
    private func refusedWithoutUserGuid() -> Bool {
        guard !ops.userGuidUsable() else { return false }
        set {
            $0.step = .failed
            $0.failure = .notSupported
            $0.failureCode = UnlockAttempt.codeNoUserGuid
            $0.vaultOpen = true
        }
        return true
    }

    private func failedBeforeMove(_ error: any Error, vaultOpen: Bool) {
        let f = error as? VaultFailure
        set {
            $0.step = .failed
            $0.failure = f?.kind ?? .other
            $0.failureCode = f?.code
            $0.vaultOpen = vaultOpen
        }
    }

    /// The unlock with the approval of ``UpdateProgress/to``; nothing else sends one. [afterFailure]: "Try again" after a
    /// failure that may have reached the vault (its answer lost).
    private func approve(_ pin: TakenPin, afterFailure: Bool) async {
        guard let to = progress?.to else { return }
        set { $0.step = .approving; $0.failure = nil; $0.failureCode = nil; $0.waitSeconds = 0; $0.refusal = nil }
        let r = await withStart { s in await self.ops.unlock(pin: pin, approve: to, abandon: false, afterMove: false, onStarting: s) }
        switch r {
        case .moved:
            await reopen(pin)
        case .refused(let code):
            // The update was refused; that same unlock opened the vault on its release.
            set { $0.step = .refused; $0.refusal = code; $0.vaultOpen = true }
        case .opened, .abandoned:
            // (iPhone; chosen; not in the spec) An approval sent again after a lost answer reaches the release the first one
            // moved the vault to, which confirms the move and says nothing of the update: done, not "not moved".
            if afterFailure, ops.releaseNumber() >= to.number {
                done()
            } else {
                // Opened without an `update` member (a vault that ignored it): nothing moved.
                set { $0.step = .refused; $0.refusal = Self.codeNotMoved; $0.vaultOpen = true }
            }
        case .badPin(let wait):
            set { $0.step = .badPin; $0.waitSeconds = wait; $0.failure = .badPin }
        case .backoff(let wait):
            set { $0.step = .badPin; $0.waitSeconds = wait; $0.failure = .backoff }
        case .failed(let kind, let code, _):
            set { $0.step = .failed; $0.failure = kind; $0.failureCode = code; $0.vaultOpen = false }
        }
    }

    /// After `moved`: the unlock that reaches the new release, with the same PIN, and no approval.
    private func reopen(_ pin: TakenPin) async {
        set { $0.step = .reopening; $0.failure = nil; $0.failureCode = nil; $0.waitSeconds = 0 }
        var r = await withStart { s in await self.ops.unlock(pin: pin, approve: nil, abandon: false, afterMove: true, onStarting: s) }
        // Routed to the old release still (the API learns the move from its lifecycle event): it completes the recorded
        // move again (§11.10.4 "Failures") and reports `moved`; once more reaches the new release.
        var again = 0
        while r == .moved, again < Self.maxMovedAgain {
            again += 1
            r = await withStart { s in await self.ops.unlock(pin: pin, approve: nil, abandon: false, afterMove: true, onStarting: s) }
        }
        switch r {
        case .opened, .refused: done()
        default: newReleaseFailed(r)
        }
    }

    private func done() {
        set { $0.step = .done; $0.vaultOpen = true; $0.canAbandon = false }
        offer = nil
        noteBehind()
    }

    private func newReleaseFailed(_ r: UpdateStepResult) {
        let kind: FailureKind
        var code: String?
        var wait: Int64 = 0
        switch r {
        case .failed(let k, let c, _):
            kind = k
            code = c
        case .badPin(let w):
            kind = .badPin
            wait = w
        case .backoff(let w):
            kind = .backoff
            wait = w
        default:
            kind = .other
        }
        let canAbandon = ops.canAbandon()
        set {
            $0.step = .newReleaseFailed
            $0.failure = kind
            $0.failureCode = code
            $0.waitSeconds = wait
            $0.vaultOpen = false
            $0.canAbandon = canAbandon
        }
    }

    /// Runs [block], waiting and trying again while the routed release starts (`503 release_starting`).
    private func withStart(
        _ block: @MainActor (@escaping @MainActor () -> Void) async -> UpdateStepResult
    ) async -> UpdateStepResult {
        var tries = 0
        while true {
            let r = await block { [weak self] in self?.set { $0.starting = true } }
            if case .failed(_, let code, let retry) = r, code == Self.codeReleaseStarting, tries < Self.maxStartRetries {
                tries += 1
                set { $0.starting = true }
                do {
                    try await sleep(.seconds(min(max(retry, 1), Self.maxStartWait)))
                } catch {
                    set { $0.starting = false }
                    return r
                }
                continue
            }
            set { $0.starting = false }
            return r
        }
    }
}
