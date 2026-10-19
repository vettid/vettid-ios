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
        do {
            offer = try await ops.offer()
            offerKnown = true
        } catch {
            // Display only: the last offer stays.
        }
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
        progress = nil
        dismissal = nil
    }

    public var pinGeneration: Int { ops.pinGeneration() }

    public func start(pin: String, offer o: ReleaseUpdateOffer, generation: Int?) -> Bool {
        // Neither the owner check (§3.6.5) nor an undecided PIN or password change (§11.14.9) comes first.
        if running || ops.ownerCheckDue() || ops.changeHold() != nil || pin.isEmpty { return false }
        progress = UpdateProgress(step: .locking, from: o.current, to: o.target)
        // The PIN as the keypad took it: a change that moves which PIN the vault expects before an unlock goes out stops it.
        let pin = taken(pin, generation)
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
        launch { [self] in
            set { $0.step = .abandoning; $0.failure = nil; $0.failureCode = nil }
            let r = await withStart { s in await self.ops.unlock(pin: pin, approve: nil, abandon: true, afterMove: false, onStarting: s) }
            switch r {
            case .abandoned, .opened:
                set { $0.step = .abandoned; $0.vaultOpen = true; $0.canAbandon = false }
            default:
                newReleaseFailed(r)
            }
        }
    }

    public func finish() {
        // Never in the middle of an unlock: its answer decides what the vault is.
        if running { return }
        job = nil
        let done = progress?.step == .done
        progress = nil
        if done { offer = nil }
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
