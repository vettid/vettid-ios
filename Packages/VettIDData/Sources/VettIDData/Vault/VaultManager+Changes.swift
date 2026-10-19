import Foundation
import VettIDAltChan
import VettIDVault

// A lost answer to `pin.change` or `credential.password.change` (VAULT-MESSAGING §11.14.9 "A lost answer", IOS-PLAN
// §6.3, ANDROID-PLAN 0.1.45 and 0.1.46 "A lost answer to a PIN or password change"): the change is decided, never
// repeated.
//
// - Before the send, an unresolved change (type, inner id, blob version, `exp`; no secret) is stored with the PIN
//   change's candidate, in the same atomic write (``PhoneSecrets``). The request goes with that id and an `exp` 10
//   minutes after the vault's clock as last seen.
// - No answer is not a failure: the change is decided at once, at every start or reconnection, when the vault opens, and
//   after a pause (30 s doubling up to 5 minutes): the same request sent again while `exp` has not passed (kept in memory
//   only), then `credential.version`. One above the version sent: applied (the blob fetched, UTKs topped up, the
//   candidate made current). The same version in an answer stamped more than a minute after `exp`: not applied. Earlier:
//   undecided. Anything else ends the check without a decision.
// - While it is unresolved, no other change, owner check or credential operation is sent: each is refused at once
//   (``decideFirst(carriesPin:)``, 0.45.0 "The gate"). A check that ends without a decision after a PIN change leaves the
//   PIN uncertain: every operation that carries it is refused until the unlock's two prompts settle it (0.45.0 step 3).
// - Before the send, nothing else is in flight (0.46.0 step 1): every earlier credential request settled (30 s at most),
//   a renew whose answer was lost decided (``settleRenews(_:)``), and `credential.version` confirming the blob, or the
//   vault's blob fetched and the request sent with it, under the credential lock (VAULT-MESSAGING 0.47.0 §11.14.9 step
//   1, "Sent with the vault's current blob"; IOS-PLAN 0.1.6 §6.3); only then is the request fixed and the marker (and
//   candidate) stored, so a restart never decides a marker stored before those checks.
// - An operation that waited for the credential lock while a change went out is refused there (0.47.0 step 2): the gate
//   (``credentialGate(carriesPin:)``) sees a change on its way or unresolved, and the count of changes and renews sent
//   (``VaultDevice/secretsSent``) one already answered and decided.
extension VaultManager {
    /// How long after `exp`, by the vault's clock, the same version means that the change never applied.
    nonisolated static let decidedAfterExp: TimeInterval = 60
    /// The pause before the next check, doubling up to ``lastRecheck``.
    nonisolated static let firstRecheck: TimeInterval = 30
    nonisolated static let lastRecheck: TimeInterval = 300
    /// The code of a change still undecided, or of another credential operation refused while one is.
    public nonisolated static let codeChangeUnresolved = "change_unresolved"
    /// The code of a change that did not apply, decided after its answer was lost (or `stale_credential`).
    public nonisolated static let codeChangeNotApplied = "change_not_applied"

    // MARK: - Sending

    /// Runs the send of a change: [body] stores the marker in [box] once the request is fixed (after the checks of
    /// step 1) and sends it. No answer keeps the request and decides the change now: applied returns; anything else
    /// throws (code ``codeChangeUnresolved`` while undecided). An answer, or a failure before anything was sent, clears
    /// the marker, if one was stored.
    ///
    /// Refused at once, before anything is awaited, while another change is on its way in this process or one is
    /// unresolved: a PIN change and a password change never overlap.
    func changing(_ box: MarkerBox, _ body: () async throws -> Void) async throws {
        if sendingChange { throw VaultFailure(.busy, code: "change_in_flight") }
        if try strictUnresolved() != nil { throw VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved) }
        changeCheck = nil
        heldChange = nil
        sendingChange = true
        do {
            defer { sendingChange = false }
            try await body()
        } catch let u as ChangeUnanswered {
            heldChange = u.held
            refreshPinStep()
            await checkUnresolvedChange(evenLocked: true)
            try outcomeOfCheck()
        } catch is CancellationError {
            // It may have gone out: the marker stays, and a check decides it.
            refreshPinStep()
            kickChangeCheck()
            throw CancellationError()
        } catch let e as VaultOpError where e.code == CredentialOpsCodes.staleCredential {
            // §11.14.9 step 4 (0.45.0): refused before any secret was tested and cached under the request's id, so this
            // change did not apply and no copy of it can; the latest blob was fetched, nothing is resent.
            if let m = box.marker { try? phoneSecrets.clearUnresolved(id: m.id) }
            refreshPinStep()
            throw VaultFailure(.other, code: Self.codeChangeNotApplied, cause: e)
        } catch {
            if let m = box.marker { try? phoneSecrets.clearUnresolved(id: m.id) }
            refreshPinStep()
            throw error
        }
    }

    /// The decision just made, as the change's own result.
    private func outcomeOfCheck() throws {
        switch changeCheck?.status {
        case .applied?: return
        case .notApplied?: throw VaultFailure(.other, code: Self.codeChangeNotApplied)
        case .refused(let kind, let code)?: throw VaultFailure(kind, code: code)
        case .ended?: throw VaultFailure(.other)
        case .checking?, .unreachable?, nil: throw VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved)
        }
    }

    /// The code of an operation refused while the change is undecided and the vault answers (still checking).
    public nonisolated static let codeChangeChecking = "change_checking"

    // MARK: - Deciding

    /// Before any other change, owner check or credential operation (§11.14.9 step 2, 0.45.0 "The gate"): while a change
    /// is unresolved the operation is refused **at once**, before anything is sent and without waiting for the decision,
    /// which is started (or left running) in the background: ``FailureKind/changeUnresolved`` while the last check could
    /// not reach the vault, else ``FailureKind/changeChecking`` (a PIN change) or ``FailureKind/changeCheckingPassword``.
    /// A records file that cannot be read refuses too: the gate never opens on what it cannot see. [carriesPin]: while
    /// the PIN is uncertain (step 3), an operation that carries it is refused (``FailureKind/pinUncertain``).
    func decideFirst(carriesPin: Bool = false) async throws {
        // A change on its way now is answered first (``FailureKind/busy``, as a second change was before).
        if sendingChange { throw VaultFailure(.busy, code: "change_in_flight") }
        guard let marker = try strictUnresolved() else {
            if carriesPin, try strictUncertainPin() != nil { throw VaultFailure(.pinUncertain, code: Self.codePinUncertain) }
            return
        }
        kickChangeCheck()
        if changeCheck?.status == .unreachable { throw VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved) }
        throw VaultFailure(marker.type == .pin ? .changeChecking : .changeCheckingPassword, code: Self.codeChangeChecking)
    }

    /// The code of an operation that carries the PIN, refused while the PIN is uncertain (§11.14.9 step 3).
    public nonisolated static let codePinUncertain = "pin_uncertain"

    /// The uncertain PIN's operation; a records file that cannot be read now throws.
    func strictUncertainPin() throws -> String? {
        do {
            return try phoneSecrets.uncertainPin()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    /// (Release R, §11.14.10) "Finish the move": refused while a change is on its way or unresolved, or the PIN
    /// uncertain (VAULT-MESSAGING 0.46.0 §11.14.9 step 2: only the unlock screen's two prompts send a PIN with a
    /// candidate), with the hold's text; else `vault.lock` and the unlock with this phone's keys, as the default does.
    /// The PIN is taken here: once which PIN the vault expects moved since (``PhoneSecrets/pinGeneration``), the unlock
    /// sends nothing and fails with ``codePinTakenBefore``, and the PIN is asked for again. Its screen, when it comes, must
    /// read ``PhoneSecrets/pinGeneration`` when its keypad opens and pass it (``finishMove(pin:taken:)``), as the update's
    /// screens do, so that a change decided while the member types is covered too.
    public func finishMove(pin: String) async throws -> UnlockAttempt {
        try await finishMove(pin: pin, taken: phoneSecrets.pinGeneration)
    }

    /// "Finish the move" with a PIN taken at ``PhoneSecrets/pinGeneration`` [taken].
    func finishMove(pin: String, taken: Int) async throws -> UnlockAttempt {
        if let hold = moveHold() { throw hold }
        // A PIN taken before a change neither locks the vault nor is sent; checked again after the lock (a change decided
        // meanwhile) and right before the unlock goes out.
        if let moved = pinTakenBefore(taken) { return .failed(moved.kind, code: moved.code) }
        try await lock()
        if let moved = pinTakenBefore(taken) { return .failed(moved.kind, code: moved.code) }
        var route = UnlockRoute()
        route.pinTaken = taken
        return await unlockOutcome(pin: pin, options: UnlockOptions(), route: route).attempt
    }

    /// The one hold of a flow that unlocks with a PIN typed on its own screen (the release update, the unlock screen's
    /// approval, "Finish the move"): a change on its way, or ``changeHold()``.
    func moveHold() -> VaultFailure? {
        sendingChange ? VaultFailure(.changeChecking, code: Self.codeChangeChecking) : changeHold()
    }

    /// Whether a flow that unlocks with a PIN typed outside the unlock screen's two prompts (a release update) must be
    /// held (§11.14.9 step 2, 0.45.0): the gate's failure while a change is unresolved or the PIN uncertain, nil when it
    /// may go on. Never sends anything.
    public func changeHold() -> VaultFailure? {
        do {
            if let marker = try strictUnresolved() {
                if changeCheck?.status == .unreachable { return VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved) }
                return VaultFailure(marker.type == .pin ? .changeChecking : .changeCheckingPassword, code: Self.codeChangeChecking)
            }
            return try strictUncertainPin() == nil ? nil : VaultFailure(.pinUncertain, code: Self.codePinUncertain)
        } catch {
            // A records file that cannot be read holds it too: the hold never lifts on what it cannot see.
            return VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved)
        }
    }

    /// The credential lock's gate (``VaultApi/credentialGate``): a credential operation that passed ``decideFirst()``
    /// and then waited for the lock is refused there when a change began meanwhile (on its way: ``FailureKind/busy``;
    /// unresolved, or a marker that cannot be read: refused too), and one that carries the PIN while the PIN is
    /// uncertain. Never a decision: it only reads.
    func credentialGate(carriesPin: Bool) throws {
        if sendingChange { throw VaultFailure(.busy, code: "change_in_flight") }
        if try strictUnresolved() != nil { throw VaultFailure(.changeUnresolved, code: Self.codeChangeUnresolved) }
        // Defence in depth (§11.14.9 step 3): a payload with the PIN never goes while the PIN is uncertain.
        if carriesPin, try strictUncertainPin() != nil { throw VaultFailure(.pinUncertain, code: Self.codePinUncertain) }
    }

    /// The unresolved change; a records file that cannot be read now throws (``FailureKind/phoneLocked``, …).
    func strictUnresolved() throws -> UnresolvedChange? {
        do {
            return try phoneSecrets.unresolvedChange()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    /// Decides the unresolved change now, if there is one, and asks again after a pause while it stays undecided. A
    /// check that is running is awaited, not repeated. [evenLocked]: asked by the member (an operation, an unlock that
    /// just opened the vault); the automatic checks wait while the vault is locked, where nothing can answer.
    public func checkUnresolvedChange(evenLocked: Bool = false) async {
        await runDecision(evenLocked: evenLocked)
        scheduleRecheck()
    }

    /// A check at a start, a reconnection or the vault opening, in the background.
    func kickChangeCheck() {
        guard deciding == nil, unresolved() != nil else { return }
        Task { [weak self] in await self?.checkUnresolvedChange() }
    }

    /// A change screen waits for the decision ([waiter]; nil: it no longer does). Held weakly: a screen that went away
    /// leaves the decision to the shell's notice.
    public func waitForChangeCheck(_ waiter: AnyObject?) { changeCheckWaiter = waiter }

    /// Whether a change screen is waiting for the decision (the shell's notice then stays hidden).
    public var changeCheckAwaited: Bool { changeCheckWaiter != nil }

    /// The screen showed the decision: it is not shown again.
    public func acknowledgeChangeCheck() {
        if changeCheck?.undecided == false { changeCheck = nil }
    }

    /// A wipe or a forget: nothing of the change is kept in memory, and a decision running now acts on nothing more.
    func forgetChangeCheck() {
        changeGeneration += 1
        deciding?.cancel()
        deciding = nil
        recheck?.cancel()
        recheck = nil
        heldChange = nil
        changeCheck = nil
        newPinAsked = false
        unlockPinStep = .pin
        phoneSecrets.pinMoved()
    }

    /// The unresolved change, nil also when the records cannot be read now (for what is shown; the gate uses
    /// ``strictUnresolved()``).
    func unresolved() -> UnresolvedChange? { (try? phoneSecrets.unresolvedChange()) ?? nil }

    /// Whether [marker] is still the unresolved change of generation [gen]: after every await, a decision acts only then
    /// (a wipe, or another decision, may have ended it meanwhile).
    func stillUnresolved(_ marker: UnresolvedChange, _ gen: Int) -> Bool {
        gen == changeGeneration && !Task.isCancelled && unresolved()?.id == marker.id
    }

    private func runDecision(evenLocked: Bool) async {
        if let running = deciding {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await decideOnce(evenLocked: evenLocked)
        }
        deciding = task
        await task.value
        deciding = nil
    }

    private func scheduleRecheck() {
        guard changeCheck?.undecided == true, unresolved() != nil else {
            recheck?.cancel()
            recheck = nil
            return
        }
        guard recheck == nil else { return }
        let sleep = config.changeCheckSleep
        recheck = Task { [weak self] in
            var pause = Self.firstRecheck
            while !Task.isCancelled {
                do {
                    try await sleep(pause)
                } catch {
                    return
                }
                guard let self else { return }
                await runDecision(evenLocked: false)
                guard changeCheck?.undecided == true, unresolved() != nil else {
                    recheck = nil
                    return
                }
                pause = min(pause * 2, Self.lastRecheck)
            }
        }
    }

    /// One decision (§11.14.9 step 3): the same request again while `exp` has not passed, then `credential.version`.
    private func decideOnce(evenLocked: Bool) async {
        refreshPinStep()
        guard !sendingChange, let marker = unresolved() else { return }
        let gen = changeGeneration
        if changeCheck?.type != marker.type || changeCheck?.undecided != true { changeCheck = ChangeCheck(marker.type, .checking) }
        // A locked vault cannot answer: an unlock decides a PIN change (step 5), and a password change once the vault runs.
        if phase == .locked && !evenLocked { return undecided(marker, reachable: false) }
        let api: VaultApi
        let s: VaultSession
        do {
            s = try await openSession()
            api = try openApi(s)
        } catch {
            if stillUnresolved(marker, gen) { undecided(marker, reachable: false) }
            return
        }
        guard stillUnresolved(marker, gen), await !resendDecided(marker, s, api, gen) else { return }
        let v: StampedCredentialInfo
        do {
            v = try await api.credentialVersionStamped()
        } catch {
            if stillUnresolved(marker, gen) { undecided(marker, reachable: error is VaultOpError) }
            return
        }
        guard stillUnresolved(marker, gen) else { return }
        await decide(marker, v, api, gen)
    }

    /// The same request again while `exp` has not passed (§11.14.9 step 3): true when its answer decided the change, or
    /// a wipe or another decision ended it meanwhile; false without an answer (the version decides).
    private func resendDecided(_ marker: UnresolvedChange, _ s: VaultSession, _ api: VaultApi, _ gen: Int) async -> Bool {
        guard let held = heldChange, held.id == marker.id, s.device.vaultNow() < marker.exp else { return false }
        do {
            let body = try await api.resendChange(held)
            if stillUnresolved(marker, gen) { await applied(marker, api, answer: body, gen) }
        } catch let e as VaultOpError {
            if stillUnresolved(marker, gen) { refused(marker, e) }
        } catch {
            return !stillUnresolved(marker, gen)
        }
        return true
    }

    private func decide(_ marker: UnresolvedChange, _ v: StampedCredentialInfo, _ api: VaultApi, _ gen: Int) async {
        guard v.info.exists, let version = v.info.version, v.info.alarm?.alarmID == nil else { return ended(marker, v.info) }
        if version == marker.version + 1 { return await applied(marker, api, answer: nil, gen) }
        guard version == marker.version else {
            // Another version: this phone's blob is behind the vault's by more than its own retry, so its next credential
            // operation would be taken for a clone (§3.5.9). The latest blob is kept first (chosen; not in the spec).
            try? await api.credentialFetch()
            guard stillUnresolved(marker, gen) else { return }
            return ended(marker, v.info)
        }
        if v.ts > marker.exp.addingTimeInterval(Self.decidedAfterExp) { return notApplied(marker) }
        undecided(marker, reachable: true)
    }

    // MARK: - The decisions

    /// Applied: by the request's own answer (its blob and UTKs kept already; a PIN change's candidate made current only
    /// with `epoch_advanced`), or by the version (the latest blob fetched, UTKs topped up, the candidate made current).
    /// A confirmation that cannot be written is still a success; the marker then stays for the next check or unlock.
    private func applied(_ marker: UnresolvedChange, _ api: VaultApi, answer: [UInt8]?, _ gen: Int) async {
        if answer == nil {
            do {
                try await api.credentialFetch()
            } catch {
                if stillUnresolved(marker, gen) { undecided(marker, reachable: false) }
                return
            }
            try? await api.topUpUTKs()
            guard stillUnresolved(marker, gen) else { return }
        }
        // Decided by the version: its request can no longer apply as anything else.
        if answer == nil { await api.device.settleCredential(marker.id) }
        confirmApplied(marker, epochAdvanced: answer.map(VaultApi.epochAdvanced) ?? true)
        heldChange = nil
        changeCheck = ChangeCheck(marker.type, .applied)
        refreshPinStep()
    }

    /// The change [marker] applied: the PIN change's candidate is made current with [epochAdvanced] and the marker cleared
    /// in the same write. A write that fails is still a success: the marker is then cleared alone, so that the next unlock
    /// asks for the PIN as usual and its `device_secret` confirms the candidate (chosen; not in the spec, which keeps the
    /// marker for the next check); if that fails too, the marker stays for the next check or unlock.
    func confirmApplied(_ marker: UnresolvedChange, epochAdvanced: Bool) {
        guard marker.type == .pin, let op = marker.operation else {
            try? phoneSecrets.clearUnresolved(id: marker.id)
            return
        }
        guard epochAdvanced else {
            try? phoneSecrets.clearUnresolved(id: marker.id)
            return
        }
        // The vault holds the new secret: a new change makes a new record, whether or not this one is current yet.
        pinChangeOperation = nil
        do {
            if let override = confirmPinChangeOverride {
                try override(op)
                try phoneSecrets.clearUnresolved(id: marker.id)
            } else {
                try phoneSecrets.confirmChange(operation: op, clearing: marker.id)
            }
        } catch {
            try? phoneSecrets.clearUnresolved(id: marker.id)
        }
    }

    /// Did not apply and never will: the candidate stays as §11.14.1 rules 3–5 say.
    private func notApplied(_ marker: UnresolvedChange) {
        try? phoneSecrets.clearUnresolved(id: marker.id)
        heldChange = nil
        changeCheck = ChangeCheck(marker.type, .notApplied)
        refreshPinStep()
    }

    /// The resend's own answer refused the change: shown as it is. `stale_credential` (step 4): the latest blob was
    /// fetched and nothing is sent again; the change this request carried did not apply.
    private func refused(_ marker: UnresolvedChange, _ e: VaultOpError) {
        if e.code == CredentialOpsCodes.staleCredential { return notApplied(marker) }
        try? phoneSecrets.clearUnresolved(id: marker.id)
        heldChange = nil
        let f = VaultFailures.map(e) as? VaultFailure ?? VaultFailure(.other)
        changeCheck = ChangeCheck(marker.type, .refused(f.kind, code: f.code))
        refreshPinStep()
    }

    /// No credential, another version or a clone alarm: no decision; the candidate is left to the next unlock and the
    /// alarm follows its own path (§3.5.9). No retry that sends a secret is offered; after a PIN change the PIN is
    /// uncertain (``FailureKind/pinUncertain``).
    private func ended(_ marker: UnresolvedChange, _ info: CredentialInfo) {
        // After a PIN change the PIN is uncertain until an unlock with step 5's prompts settles it (0.45.0); if that
        // cannot be written, the marker stays and the next check decides again.
        guard (try? phoneSecrets.endUnresolved(marker)) != nil else { return undecided(marker, reachable: true) }
        heldChange = nil
        if let a = info.alarm, let id = a.alarmID {
            alarm = CredentialAlarm(alarmID: id, state: a.state ?? CredentialAlarm.stateFrozen, at: a.at)
        }
        changeCheck = ChangeCheck(marker.type, .ended)
        refreshPinStep()
    }

    private func undecided(_ marker: UnresolvedChange, reachable: Bool) {
        changeCheck = ChangeCheck(marker.type, reachable ? .checking : .unreachable)
    }

    // MARK: - The unlock (§11.14.9 step 5)

    /// Which PIN the unlock asks for: while a PIN change is unresolved, or its PIN uncertain (0.45.0 step 5), and its
    /// record is still a candidate, the previous PIN, then (after `device_secret`) the new one.
    func refreshPinStep() {
        guard twoStepOperation() != nil else {
            newPinAsked = false
            if unlockPinStep != .pin {
                unlockPinStep = .pin
                phoneSecrets.pinMoved()
            }
            return
        }
        let step: UnlockPinStep = newPinAsked ? .new : .previous
        if unlockPinStep != step {
            unlockPinStep = step
            phoneSecrets.pinMoved()
        }
    }

    /// The operation of the PIN change the unlock's two prompts are for: the unresolved one, else the one whose PIN is
    /// uncertain, while its record is a candidate; nil when the unlock asks for the PIN once.
    private func twoStepOperation() -> String? {
        guard let recs = try? phoneSecrets.records() else { return nil }
        if let m = recs.unresolved, m.type == .pin, let op = m.operation, recs.candidates.contains(where: { $0.operation == op }) {
            return op
        }
        return recs.uncertainPin
    }

    /// What the unlock's tries are for [step]: at the previous-PIN step, the current record and then the other candidates
    /// (an unanswered renew's: VAULT-MESSAGING 0.45.0 §11.14.9 step 5); at the new-PIN step, only the PIN change's own
    /// candidate.
    func tries(_ step: UnlockPinStep) -> UnlockTries {
        switch step {
        case .pin: .all
        case .previous: .previous(excluding: twoStepOperation())
        case .new: twoStepOperation().map { UnlockTries.candidate(operation: $0) } ?? .all
        }
    }

    /// An unlock answered while a PIN change was unresolved or its PIN uncertain ([step] when it was sent). `device_secret`
    /// to the previous PIN: the vault holds the candidate, and the new PIN is asked for (nil otherwise: the answer is the
    /// unlock's own). `ok` to the previous PIN leaves the change to the check after the unlock (0.45.0 step 5), except
    /// when the unlock's answer is stamped more than a minute after the change's `exp`: no copy can apply any more, and
    /// the change is decided as not applied at once (chosen; not in the spec, which waits for the check). Its candidate
    /// stays a candidate meanwhile (``PhoneSecrets`` treats the unresolved change's operation as in flight). `bad_pin` to
    /// the previous PIN leaves the change unresolved, and the previous PIN is asked for again (chosen; not in the spec,
    /// where only `ok` and `device_secret` decide).
    func afterPinStep(_ step: UnlockPinStep, ok: Bool, code: String?, at: Date?) -> UnlockAttempt? {
        defer { refreshPinStep() }
        switch step {
        case .pin:
            return nil
        case .previous:
            if !ok, code == UnlockEpoch.deviceSecret {
                newPinAsked = true
                return .newPinNeeded
            }
            if ok, let m = unresolved(), m.type == .pin, let at, at > m.exp.addingTimeInterval(Self.decidedAfterExp) {
                notApplied(m)
            }
            return nil
        case .new:
            if !ok, code == UnlockEpoch.deviceSecret { newPinAsked = false }
            return nil
        }
    }
}

/// The marker of a change, once its request is fixed (``VaultManager/changing(_:_:)``).
@MainActor
final class MarkerBox {
    var marker: UnresolvedChange?
}

/// The credential operations' error codes the manager reacts to.
enum CredentialOpsCodes {
    /// §3.5.3: the blob sent is not the vault's latest.
    static let staleCredential = "stale_credential"
}
