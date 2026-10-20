import Foundation
import Observation
import VettIDData

/// The vault unlock (VAULT-MESSAGING §11.4): first the release check (§11.10.6: refuse an older release, announce a newer
/// one before the PIN, offer the newest active release; IOS-PLAN ID8: refuse a release before R), then the PIN, the
/// enclave's answer and its backoff (§11.8), the recovery-pending refusal (§11.11.4) and the state-rollback warning
/// (§13.2). An unlock the vault did not recognise (an unreadable result), or a phone that no longer holds the vault's keys
/// (`device_secret`), offers "Erase VettID from this phone", only after a confirmation; a phone sent here by repeated
/// relay refusals is told so, and the refusals alone offer nothing. A vault past its owner-check deadline, or locked after
/// ten failed checks, asks for the password with the PIN (§3.6.5). What's new above the offer is information only: it
/// never holds the unlock up. Mirrors vettid-android `UnlockViewModel`.
@MainActor
@Observable
public final class UnlockViewModel: UnlockActions {
    public private(set) var state: UnlockState

    @ObservationIgnored let vault: any VaultRepository
    @ObservationIgnored let account: any AccountRepository
    @ObservationIgnored private let releaseNotes: (any ReleaseNotesRepository)?
    @ObservationIgnored private var notesTask: Task<Void, Never>?
    /// One second of a countdown (a virtual clock in the tests).
    @ObservationIgnored private let tick: @Sendable () async throws -> Void
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private let countdowns = TaskBag()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var serviceTicker: Task<Void, Never>?
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWork = 0

    public init(
        vault: any VaultRepository,
        account: any AccountRepository,
        ownerCheck: (any OwnerCheckRepository)? = nil,
        releaseNotes: (any ReleaseNotesRepository)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        recheck: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(15)) }
    ) {
        self.vault = vault
        self.account = account
        self.releaseNotes = releaseNotes
        self.tick = tick
        let hint = account.account?.emailHint
        state = UnlockState(email: hint?.isEmpty == false ? hint : nil, phoneSecret: vault.usesPhoneSecret)
        retryPreflight()
        followers.add(follow(self, read: { $0.vault.refusedByVault }, apply: { $0.state.refused = $1 }))
        followers.add(follow(self, read: { $0.vault.lockNotice }, apply: { $0.state.lock = $1 }))
        followers.add(follow(self, read: { $0.vault.transferKeptSince }, apply: { $0.state.keptTransfer = $1 != nil }))
        followers.add(follow(self, read: { $0.vault.timeScale }, apply: { $0.state.timeScale = $1 }))
        followers.add(follow(self, read: { $0.vault.finishMoveFailure }, apply: { $0.state.moveFailure = $1 }))
        // §11.14.9 "A lost answer" step 5: the previous PIN, then the new one.
        followers.add(follow(self, read: { $0.vault.unlockPinStep }, apply: { $0.state.pinStep = $1 }))
        followers.add(follow(self, read: { $0.vault.releaseUpdateHeld }, apply: { $0.state.updateHeld = $1 }))
        followers.add(follow(self, read: { $0.vault.unconfirmedMove }, apply: { $0.state.moveUnconfirmed = $1 }))
        if let ownerCheck {
            followers.add(follow(
                ownerCheck,
                read: { OwnerCheckFlags(due: $0.ownerCheck?.gated(now()) == true, locked: $0.lockedByOwnerCheck) },
                apply: { [weak self] _, f in self?.ownerCheck(due: f.due, lockedByChecks: f.locked) }
            ))
            // The deadline passes by itself while the screen is open: the password is then asked for too.
            followers.add(Task { @MainActor [weak self, weak ownerCheck] in
                while !Task.isCancelled {
                    do {
                        try await recheck()
                    } catch {
                        return
                    }
                    guard let self, let repo = ownerCheck else { return }
                    self.ownerCheck(due: repo.ownerCheck?.gated(now()) == true, lockedByChecks: repo.lockedByOwnerCheck)
                }
            })
        }
    }

    deinit {
        followers.cancelAll()
        countdowns.cancelAll()
        notesTask?.cancel()
    }

    /// The owner check's state, from its repository (the vault past its deadline, or locked after ten checks).
    func ownerCheck(due: Bool, lockedByChecks: Bool) {
        state.checkDue = due || lockedByChecks
        state.lockedByOwnerCheck = lockedByChecks
    }

    // MARK: - Tasks

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        let id = nextWork
        nextWork += 1
        work[id] = Task { [weak self] in
            await body()
            self?.work[id] = nil
        }
    }

    /// TEST ONLY: returns once the model's tasks and the reactions to the repositories' changes have run.
    func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            while let (id, task) = work.first {
                await task.value
                work[id] = nil
            }
            await notesTask?.value
        }
    }

    // MARK: - The release check

    public func retryPreflight() {
        if state.serviceWaitSeconds > 0 { return }
        // The result of an earlier check goes too: no PIN is asked for until this one has verified the vault's software.
        // So does an open erase confirmation: it does not come back by itself.
        state.loading = true
        state.preflightError = nil
        state.preflight = nil
        state.keysGone = false
        state.earlierSecret = false
        state.eraseConfirm = false
        launch { [self] in
            do {
                let p = try await vault.preflight()
                state.loading = false
                state.preflight = p
                state.notes = nil
                loadNotes(p)
            } catch let e as VaultFailure {
                state.loading = false
                state.preflightError = e.kind
                if e.kind == .servicePaused { startServiceWait(e.retryAfterSeconds) }
            } catch {
                state.loading = false
            }
        }
    }

    /// What's new for the offer: information only, it never holds the unlock up.
    private func loadNotes(_ p: PreflightInfo) {
        guard let offer = p.offer, !p.rollback, let repo = releaseNotes else { return }
        notesTask?.cancel()
        notesTask = Task { [weak self] in
            let n = await repo.whatsNew(target: offer, between: p.between)
            guard !Task.isCancelled, let self, self.state.preflight?.offer == offer else { return }
            self.state.notes = n
        }
    }

    public func acknowledgeUpdate() { state.updateAcknowledged = true }

    public func setApproveOffer(_ approve: Bool) { state.approveOffer = approve }

    // MARK: - The PIN and the password

    public func setPin(_ v: String) {
        state.pin = String(v.filter { $0.isASCII && $0.isNumber }.prefix(UnlockState.maxPin))
        state.message = nil
    }

    public func setPassword(_ v: String) {
        state.password = v
        state.message = nil
    }

    public func forgetSecrets() {
        state.pin = ""
        state.password = ""
    }

    public func submit() {
        if state.returnAsksPin { return returnWithPin() }
        attempt(.unlock(cancelRecovery: false))
    }

    public func cancelRecoveryAndUnlock() {
        guard state.cancelAllowed else { return }
        attempt(.unlock(cancelRecovery: true))
    }

    public func submitEarlierSecret() {
        guard state.keysGone, state.earlierSecret else {
            state.pin = ""
            return
        }
        attempt(.earlierSecret)
    }

    public func showSignerHelp(_ show: Bool) { state.signerHelp = show && state.signerRefused }

    // MARK: - The erase

    public func askErase() {
        if state.eraseOffered && !state.erasing { state.eraseConfirm = true }
    }

    public func dismissErase() { state.eraseConfirm = false }

    public func confirmErase() {
        let s = state
        guard s.eraseConfirm, s.eraseOffered, !s.erasing else { return }
        state.eraseConfirm = false
        state.erasing = true
        state.pin = ""
        // The phase becomes signed out at the end: the root shows the welcome screen and drops this screen.
        launch { [self] in
            do {
                try await account.eraseThisPhone()
            } catch let e as VaultFailure {
                // (iPhone) A failed erase is said here; the screen stays as it was.
                state.erasing = false
                state.message = .failed(e.kind, code: e.code)
            } catch {
                state.erasing = false
            }
        }
    }

    // MARK: - The way back to release N (IOS-PLAN §4.3)

    public func askReturn() {
        if state.returnOffered && !state.busy { state.returnConfirm = true }
    }

    public func dismissReturn() { state.returnConfirm = false }

    public func cancelReturn() {
        state.returnAsksPin = false
        state.pin = ""
    }

    public func confirmReturn() {
        state.returnConfirm = false
        guard state.returnOffered, !state.busy else {
            state.pin = ""
            return
        }
        if state.pin.count >= UnlockState.minPinLength {
            returnWithPin()
        } else {
            state.pin = ""
            state.returnAsksPin = true
        }
    }

    /// The PIN goes to release N only here, on the member's confirmed tap: the release update's way back, which the root
    /// shows over this screen.
    private func returnWithPin() {
        let pin = state.pin
        state.pin = ""
        // Not now (a backoff's countdown runs, or a step is busy): the keypad keeps asking, and says why with its countdown.
        guard pin.count >= UnlockState.minPinLength, state.pinAllowed else {
            state.returnAsksPin = true
            return
        }
        state.returnAsksPin = false
        state.message = nil
        // Refused before anything was sent (an update running, the owner check or a change first).
        if !vault.returnToPreviousRelease(pin: pin) { state.message = .failed(.other, code: nil) }
    }

    // MARK: - The lock and the move

    public func retryLock() { vault.retryLock() }

    public func dismissLockNotice() { vault.dismissLockNotice() }

    public func dismissMoveFailure() { vault.acknowledgeFinishMoveFailure() }

    // MARK: - One unlock

    private enum Kind {
        case unlock(cancelRecovery: Bool)
        case earlierSecret
    }

    private func attempt(_ kind: Kind) {
        let s = state
        guard s.submitAllowed, !s.erasing else {
            // Refused here: the PIN handed over for it does not stay in memory.
            if !s.recoveryPending { state.pin = "" }
            return
        }
        state.busy = true
        state.message = nil
        launch { [self] in
            let r = await send(kind, s)
            // §3.6.5: the password is not kept beyond the unlock and the check that follows it.
            state.password = ""
            state.notRecognised = Self.notRecognised(after: r, before: state.notRecognised)
            state.signerRefused = Self.signerRefused(after: r, before: state.signerRefused)
            state.keysGone = Self.keysGone(after: r, before: state.keysGone)
            state.earlierSecret = state.keysGone && vault.earlierSecretOffered && Self.earlierSecretHelps(r)
            apply(r, keptTransfer: s.keptTransfer)
        }
    }

    /// The request [kind] asks for; every failure is an ``UnlockAttempt``.
    private func send(_ kind: Kind, _ s: UnlockState) async -> UnlockAttempt {
        // (§11.14.9; chosen; not in the spec) No approval while a PIN or password change is undecided.
        let offer = s.approveOffer && !vault.releaseUpdateHeld ? s.preflight?.offer : nil
        do {
            switch kind {
            case .earlierSecret:
                return try await vault.unlockWithEarlierSecret(pin: s.pin)
            case .unlock(let cancelRecovery) where cancelRecovery && s.phoneSecret:
                // Release R: after a cancel from the app, the owner check at once, which records the member's presence.
                return try await vault.unlockCancellingRecovery(pin: s.pin, password: s.password, approve: offer)
            case .unlock(let cancelRecovery) where s.checkDue:
                return try await vault.unlockWithCheck(pin: s.pin, password: s.password, approve: offer, cancelRecovery: cancelRecovery)
            case .unlock(let cancelRecovery):
                return try await vault.unlock(pin: s.pin, approve: offer, cancelRecovery: cancelRecovery)
            }
        } catch let e as VaultFailure {
            return .failed(e.kind, code: e.code, retryAfterSeconds: e.retryAfterSeconds)
        } catch {
            return .failed(.other, code: nil)
        }
    }

    private func apply(_ r: UnlockAttempt, keptTransfer: Bool) {
        state.busy = false
        switch r {
        // §11.7.1: not a PIN failure: no "wrong PIN" text, no count, no backoff. The notice says what to do.
        case .signerRefused:
            state.pin = ""
        case .success:
            state.pin = ""
            state.recoveryPending = false
        // §11.14.9 step 5: the vault holds the PIN change's candidate; the new PIN is asked for (nothing was counted).
        case .newPinNeeded:
            state.pin = ""
            state.pinStep = .new
        case .badPin(let wait):
            state.pin = ""
            state.message = .badPin
            startBackoff(wait)
        case .backoff(let wait):
            state.pin = ""
            startBackoff(wait)
        // The PIN stays in memory so that "Cancel the recovery and unlock" can send it again.
        case .recoveryPending:
            state.recoveryPending = true
        case .stateRollback:
            state.pin = ""
            state.stateRollback = true
        case .updateRefused(let code):
            state.pin = ""
            state.message = .updateRefused(code: code)
        case .failed(let kind, let code, let wait):
            state.pin = ""
            state.message = UnlockMessage.of(kind, code: code, keptTransfer: keptTransfer)
            // A paused service (503, never proof of anything): wait as it asked, no automatic retry.
            if kind == .servicePaused { startServiceWait(wait) }
        }
    }

    /// An unreadable answer: the vault may not know this phone. A sealed answer shows that it does; other failures say
    /// nothing either way. The member API refusing this phone's app key (`401`) is no proof either, but the member may then
    /// erase VettID here too.
    static func notRecognised(after r: UnlockAttempt, before: Bool) -> Bool {
        guard case .failed(let kind, let code, _) = r else { return false }
        // A sealed `unknown_device` is not here: it is the proof of a replacement, and the phone was wiped already
        // (``HolderPolicy``).
        return code == UnlockState.codeUnreadable || kind == .unauthorized || before
    }

    /// The keys-gone offer: set by `device_secret`, kept through failures that never reached the vault, cleared by any
    /// other answer of the vault.
    static func keysGone(after r: UnlockAttempt, before: Bool) -> Bool {
        guard case .failed(let kind, _, _) = r else { return false }
        if kind == .deviceSecret { return true }
        return UnlockMessage.transientFailures.contains(kind) ? before : false
    }

    /// Whether an earlier phone secret could help (IOS-PLAN §6.3 item 5): not when the App Attest key is gone (§6.2),
    /// which no secret replaces.
    static func earlierSecretHelps(_ r: UnlockAttempt) -> Bool {
        guard case .failed(_, let code, _) = r else { return true }
        return code != VaultFailure.codeAppAttestKeyGone
    }

    /// The `signer_refused` notice: set by that answer, cleared by any other sealed answer, kept through failures.
    static func signerRefused(after r: UnlockAttempt, before: Bool) -> Bool {
        switch r {
        case .signerRefused: true
        case .failed: before
        default: false
        }
    }

    // MARK: - Countdowns

    private func startBackoff(_ seconds: Int64) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        state.waitSeconds = seconds
        ticker = countdown(\.waitSeconds)
    }

    /// Counts ``UnlockState/serviceWaitSeconds`` down; the member tries again when it reaches 0.
    private func startServiceWait(_ seconds: Int64) {
        guard seconds > 0 else { return }
        serviceTicker?.cancel()
        state.serviceWaitSeconds = seconds
        serviceTicker = countdown(\.serviceWaitSeconds)
    }

    private func countdown(_ field: WritableKeyPath<UnlockState, Int64> & Sendable) -> Task<Void, Never> {
        let tick = tick
        let task = Task { @MainActor [weak self] in
            while (self?.state[keyPath: field] ?? 0) > 0 {
                do {
                    try await tick()
                } catch {
                    return
                }
                guard let self else { return }
                state[keyPath: field] = max(state[keyPath: field] - 1, 0)
            }
        }
        countdowns.add(task)
        return task
    }
}

/// What the unlock screen follows of the owner check.
private struct OwnerCheckFlags: Equatable, Sendable {
    let due: Bool
    let locked: Bool
}
