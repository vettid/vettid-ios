import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDVault

/// What the one-step release update needs from the vault manager (``ReleaseUpdateOps``): the offer from the manifest
/// this phone trusts, the owner check, the lock and the unlocks of the update. Mirrors vettid-android
/// `VaultManager.UpdateOps`.
@MainActor
final class VaultReleaseUpdateOps: ReleaseUpdateOps {
    private let ref: ManagerRef

    init(ref: ManagerRef) {
        self.ref = ref
    }

    private var manager: VaultManager {
        get throws {
            guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
            return m
        }
    }

    func offer() async throws -> ReleaseUpdateOffer? { try await manager.releaseOffer() }

    func ownerCheckDue() -> Bool { ref.manager?.ownerCheckGates() ?? false }

    func lock() async throws { try await manager.lockForUpdate() }

    func unlock(
        pin: TakenPin, approve: ReleaseView?, abandon: Bool, afterMove: Bool, onStarting: @escaping @MainActor () -> Void
    ) async -> UpdateStepResult {
        guard let m = ref.manager else { return .failed(.other, code: "session_dropped") }
        return await m.updateUnlock(pin: pin, approve: approve, abandon: abandon, afterMove: afterMove, onStarting: onStarting)
    }

    func canAbandon() -> Bool { ref.manager?.session?.device.altState.previousRelease.isEmpty == false }

    func releaseNumber() -> UInt64 { ref.manager?.session?.device.altState.releaseNumber ?? 0 }

    func timeScale() -> UInt64 { ref.manager?.timeScale ?? 1 }

    func changeHold() -> FailureKind? { ref.manager?.releaseUpdateHold() }

    func pinGeneration() -> Int { ref.manager?.phoneSecrets.pinGeneration ?? 0 }
}

// The proactive release update (RELEASE-UPDATES §2, VAULT-MESSAGING §11.10): the offer read after every unlock and on
// the return to the foreground, and the update's own lock and unlocks. Mirrors vettid-android `VaultManager`'s
// `UpdateOps` and `releaseUpdate`.
extension VaultManager {
    /// The code of an update whose lock is not confirmed: it does not move on.
    public nonisolated static let codeUpdateLockPending = "lock_pending"
    /// The code of an abandonment with no previous release known.
    nonisolated static let codeNoPreviousRelease = "no_previous_release"
    /// How long the update waits for the member API to see the vault locked: 15 polls a second apart (vettid-android's
    /// `LOCKED_WAIT_MS`).
    nonisolated static let lockedPolls = 15
    nonisolated static let lockedPoll: Duration = .seconds(1)
    /// The code of an update step refused because a PIN or password change is undecided.
    nonisolated static let codeChangeHeld = ReleaseUpdateManager.codeChangeHeld
    /// (VAULT-MESSAGING §11.14.9 step 2; chosen; not in the spec) The code of an unlock of a flow with a PIN typed on its
    /// own screen (the release update, "Finish the move") refused with nothing sent: which PIN the vault expects may have
    /// changed since the PIN was taken (``PhoneSecrets/pinGeneration``). The PIN is asked for again, with the "earlier
    /// request" text (``FailureKind/credentialUnsettled``); no PIN attempt is spent.
    public nonisolated static let codePinTakenBefore = "pin_taken_before_change"

    /// The refusal of an unlock whose PIN was taken at [generation] when ``PhoneSecrets/pinGeneration`` moved since; nil
    /// when it may go out.
    nonisolated func pinTakenBefore(_ generation: Int?) -> VaultFailure? {
        guard let generation, phoneSecrets.pinGeneration != generation else { return nil }
        return VaultFailure(.credentialUnsettled, code: Self.codePinTakenBefore)
    }

    /// (VAULT-MESSAGING §11.14.9 step 2) Whether a release update, the unlock screen's approval and "Finish the move" are
    /// held (``releaseUpdateHold()``).
    public var releaseUpdateHeld: Bool { releaseUpdateHold() != nil }

    /// (VAULT-MESSAGING §11.14.9 step 2) Why a release update is held, if it is, in the change gate's words: the one
    /// hold of every flow that unlocks with a PIN typed outside the unlock screen's two prompts (the release update, the
    /// unlock screen's approval, "Finish the move"; ``moveHold()``). A change on its way, or undecided while the vault
    /// answers, is ``FailureKind/changeChecking`` (``FailureKind/changeCheckingPassword`` after a password change);
    /// undecided while it cannot be reached (or a records file that cannot be read), ``FailureKind/changeUnresolved``;
    /// an uncertain PIN (step 3), ``FailureKind/pinUncertain``. Nil when nothing holds it. Reads ``changeCheck`` and
    /// ``unlockPinStep``, so that the screens follow it.
    func releaseUpdateHold() -> FailureKind? {
        _ = changeCheck?.status
        _ = unlockPinStep
        return moveHold()?.kind
    }

    /// The offer for the vault as this phone knows it: the release it last unlocked into, in the manifest it trusts (the
    /// published one or the installed canary manifest, §11.10.1), and the newest `active` release.
    func releaseOffer() async throws -> ReleaseUpdateOffer? {
        try await guarded {
            guard let s = try await storedSession(), s.device.deviceID != nil else { return nil }
            let st = s.device.altState
            guard st.releaseNumber != 0 else { return nil }
            let m = try await s.alt.manifest(seen: st.manifestSerial)
            let sealed = (st.release.isEmpty ? nil : m.byPcr0(st.release)) ?? m.byNumber(st.releaseNumber)
            let current = sealed.flatMap { $0.number == st.releaseNumber ? Self.view($0) : nil }
            let newest = m.newest()
            let between = current.flatMap { c in
                newest.map { n in m.releases.filter { $0.number > c.number && $0.number < n.number }.map(Self.view) }
            } ?? []
            return ReleaseUpdateOffer.of(sealed: current, newest: newest.map(Self.view), between: between)
        }
    }

    /// The owner check is due or held (§3.6.5), or the vault locked after ten failed checks.
    func ownerCheckGates() -> Bool {
        ownerChecks.ownerCheck?.gated(config.now()) == true || ownerChecks.lockedByOwnerCheck
    }

    /// The update's lock: the member's lock, and an update moves on only from a vault known to be locked; then a bounded
    /// wait until the member API no longer sees it unlocked (the next unlock goes to the instance that holds it).
    func lockForUpdate() async throws {
        try await lock()
        if lockGuard.pending { throw VaultFailure(.noResponse, code: Self.codeUpdateLockPending) }
        let sleep = config.releaseUpdateSleep
        for _ in 0..<Self.lockedPolls {
            guard (try? await vaultStatus())?.state == Self.stateUnlocked else { return }
            try await sleep(Self.lockedPoll)
        }
    }

    /// One unlock of the update: approving [approve] or abandoning the unconfirmed move, never following a move. Nothing
    /// is sent once which PIN the vault expects moved since [pin] was taken: checked here and again right before each
    /// request is posted (``UnlockRoute/pinTaken``).
    func updateUnlock(
        pin: TakenPin, approve: ReleaseView?, abandon: Bool, afterMove: Bool = false, onStarting: @escaping @MainActor () -> Void
    ) async -> UpdateStepResult {
        // (§11.14.9) Nothing is sent while a PIN or password change is undecided: the PIN may be the wrong one of two.
        if let hold = releaseUpdateHold() {
            kickChangeCheck()
            return .failed(hold, code: Self.codeChangeHeld)
        }
        if let moved = pinTakenBefore(pin.generation) { return .failed(moved.kind, code: moved.code) }
        var release: String?
        if abandon {
            let previous = session?.device.altState.previousRelease ?? ""
            guard !previous.isEmpty else { return .failed(.notSupported, code: Self.codeNoPreviousRelease) }
            release = previous
        }
        let options = UnlockOptions(approve: approve.map { Approval(toPcr0: $0.pcr0, toRelease: $0.number) }, abandon: abandon)
        let starting: @Sendable (Int) -> Void = { _ in Task { @MainActor in onStarting() } }
        // The update never moves the unlock's PIN steps (§11.14.9 step 5): a change undecided is refused above.
        var route = UnlockRoute(followMove: false, release: release, onStarting: starting, pinSteps: false, afterMove: afterMove)
        route.pinTaken = pin.generation
        var o = await unlockOutcome(pin: pin.pin, options: options, route: route)
        if abandon, case .failed(_, let code, _) = o.attempt, code == MemberApiError.vaultBusy {
            // §11.10.5: an instance of the new release holds the vault; lock it first, then return. Not with a PIN taken
            // before a change: nothing is locked or sent then.
            if let moved = pinTakenBefore(pin.generation) { return .failed(moved.kind, code: moved.code) }
            try? await lock()
            o = await unlockOutcome(pin: pin.pin, options: options, route: route)
        }
        return Self.stepResult(o)
    }

    nonisolated static func stepResult(_ o: UnlockStepOutcome) -> UpdateStepResult {
        if o.moved { return .moved }
        if o.abandoned { return .abandoned }
        return stepResult(o.attempt)
    }

    nonisolated static func stepResult(_ a: UnlockAttempt) -> UpdateStepResult {
        switch a {
        case .success: return .opened
        case .updateRefused(let code): return .refused(code)
        case .badPin(let wait): return .badPin(retryAfterSeconds: wait)
        case .backoff(let wait): return .backoff(retryAfterSeconds: wait)
        case .failed(let kind, let code, let wait): return .failed(kind, code: code, retryAfterSeconds: wait)
        case .recoveryPending: return .failed(.other, code: "recovery_pending")
        case .signerRefused: return .failed(.signerRefused, code: VaultDevice.codeSignerRefused)
        case .stateRollback: return .failed(.rollback, code: "state_rollback")
        // (iPhone; chosen; not in the spec) An unresolved PIN change asks the unlock screen for the new PIN: the update
        // does not go on with this one.
        case .newPinNeeded: return .failed(.changeUnresolved, code: "new_pin_needed")
        }
    }
}
