import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

// The identities of a phone that could not tell (IOS-PLAN 0.1.33 §4.9; owner decision of 2026-10-25: two, no third). The new code
// is registered with a second identity (its keys, its device state with its own `recovery_id` and the history of its opens, and
// the App Attest keys the vault bound to it); nothing is deleted until the vault answered `ok` and the pairing completed. If the
// second identity's recovery ends too, the phone keeps both and goes on with the lost-ok unlock, newest first; each identity pairs
// only with its own `recovery_id` as `ctx`.
extension VaultManager {
    // MARK: - The new recovery with the same K

    /// Whether a code is registered as the rule's new recovery: the rule decided that the recovery ended (no second identity yet,
    /// or one that never registered).
    var registersAsNewRecovery: Bool {
        guard let ct = record.value.couldNotTell else { return false }
        return ct.ended && !ct.unlock
    }

    /// A vault other than the earlier open's is no use for the rule: its code is refused as soon as its vault is known, before the
    /// register, and no status read of it drives the rule (``ruleRead()``).
    func requireEarlierVault(_ vaultID: String) throws {
        if vaultID != record.value.vaultID { throw VaultFailure(.other, code: Self.codeRecoveryOpenUnknown) }
    }

    /// Switching identities for the rule: a status read of the rule waits.
    func withRuleSwitch<T>(_ body: () async throws -> T) async throws -> T {
        moveFlags.book.ruleSwitching += 1
        defer { moveFlags.book.ruleSwitching -= 1 }
        return try await body()
    }

    /// After the claim with K: the unanswered opens of the newest identity are read once each (a readable answer decides), then the
    /// second identity registers the code with K, and the open that follows carries the earlier opens' unlock secret (the
    /// phone-secret record is the same). [claimAgain] is the same claim, made again after a `401` at the register.
    func registerAsNewIdentity(
        _ code: RecoveryCode, _ claimed: Claimed, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        try await withRuleSwitch {
            guard let ct = record.value.couldNotTell else { throw VaultFailure(.other, code: "no_rule") }
            try await selectIdentity(ct.newest)
            await convertLegacyUnanswered(try await openSession().device)
            if case .ok = await readUnansweredOpens(try await openSession()) {
                // A readable `ok` decides it: the vault adopted that open, and the PIN finishes it (kept, so that the stage says so).
                try persistRecord(record.generation) {
                    $0.couldNotTell?.unlock = true
                    $0.couldNotTell?.ended = false
                }
                return .refused(code: Self.codeRecoveryOpenSent)
            }
            let fresh = try await identityForNewCode(ct)
            // The second identity is registered once: for another recovery than this code's it has ended, and the phone goes on
            // with the unlock with each identity.
            if let known = fresh.device.recoveryID, known != code.recoveryID { return try bothRecoveriesEnded() }
            do {
                let registered = try await registerClaimed(fresh, code, claimed)
                if case .registered = registered { try persistRecord(record.generation) { $0.couldNotTell?.ended = false } }
                return registered
            } catch let e as MemberApiError where e.status == 401 && e.code == MemberApiError.unauthorized && !e.queued {
                // A `401` of the register itself queued nothing: the identity did not register (and may be registered again).
                try await fresh.device.dropRecoveryRegistration()
                // A claim key that has since become a key in use is no claim key: the register is `401`, and a new claim says whether.
                do {
                    _ = try await claimAgain()
                } catch let again as MemberApiError where again.code == MemberApiError.keyInUse {
                    return try await claimKeyInUse()
                } catch {
                    // Anything else decides nothing: the first refusal stands, and everything is kept.
                }
                throw e
            }
        }
    }

    /// The identity that registers the new code: the second one, made here from the floors the first has seen, or the one made
    /// before when its registration did not complete. The identity in use is the one returned.
    private func identityForNewCode(_ ct: CouldNotTell) async throws -> VaultSession {
        let current = try await openSession()
        let floors = (ct.floors ?? AltFloors(current.device.altState)).merged(with: AltFloors(current.device.altState))
        if ct.identities.count > 1 {
            try await current.device.seedFloors(from: floors.altState)
            return current
        }
        guard let n = ct.nextFree else { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
        _ = await cancelOpening() // a session being opened for another identity must not interleave
        // Keys the App Attest record may still hold for this number (an earlier episode) are not the new identity's.
        try config.attester.forget(identity: n.rawValue)
        try Self.makeIdentity(config, n)
        // The floors are written with the switch, and applied to the new identity whenever it is used.
        try persistRecord(record.generation) {
            $0.couldNotTell?.identities.append(n)
            $0.couldNotTell?.floors = floors
            $0.activeIdentity = n
        }
        try await dropSession(forget: false)
        let fresh = try await openSession()
        try await fresh.device.seedFloors(from: floors.altState)
        return fresh
    }

    /// The second identity's recovery ended too: nothing more is registered, no third identity is made, and the unlock with each
    /// identity is what is left, for good (owner decision of 2026-10-25). The text after a day of refusals is the stage
    /// ``CouldNotTellStage/couldNotFinish``.
    func bothRecoveriesEnded() throws -> RecoveryRegistration {
        try persistRecord(record.generation) {
            $0.couldNotTell?.unlock = true
            $0.couldNotTell?.couldNotFinish = true
            $0.couldNotTell?.ended = false
            $0.couldNotTellRead = nil
        }
        return .refused(code: Self.codeRecoveryOpenSent)
    }

    /// A forget: refused while the phone could not tell, unless the vault is gone, when the rule is cleared first, in a save of its
    /// own, so that a failure or a kill later in the forget leaves no rule that outlives its keys.
    func guardRule(vaultGone: Bool) throws {
        guard record.value.couldNotTell != nil else { return }
        guard vaultGone else { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
        try persistRecord(record.generation) {
            $0.couldNotTell = nil
            $0.couldNotTellRead = nil
        }
    }

    /// The claim answered `409 key_in_use`: the phone is the vault's app. The lost-ok unlock decides, newest identity first
    /// (``resumeLostOk(pin:)``).
    func claimKeyInUse() async throws -> RecoveryRegistration {
        guard let ct = record.value.couldNotTell else { throw VaultFailure(.other, code: MemberApiError.keyInUse) }
        try persistRecord(record.generation) {
            $0.couldNotTell?.unlock = true
            $0.couldNotTell?.ended = false
            $0.couldNotTellRead = nil
        }
        // An identity that did not register is no unlock key: the PIN screen is on the newest that did (else the first).
        try await withRuleSwitch {
            for id in ct.identities.reversed() {
                do {
                    try await selectIdentity(id)
                    if try await openSession().device.recovering { return }
                } catch {
                    if error is CancellationError { throw error }
                    continue // an identity that cannot be opened is no reason to stop
                }
            }
            try await selectIdentity(ct.earlier)
        }
        return .refused(code: Self.codeKeyInUse)
    }

    /// The slots of the unanswered opens of one identity, read once each (a readable answer decides it).
    enum EarlierOpen {
        case ok
        case answered(RecoveryOpen.Result)
        case unreadable
    }

    func readUnansweredOpens(_ s: VaultSession) async -> EarlierOpen {
        var found = EarlierOpen.unreadable
        for rid in s.device.unansweredOpenRequestIDs.reversed() { // oldest first
            do {
                let slot = try await member.slot(rid)
                guard slot.status == Slot.done, let envelope = slot.envelope else { continue }
                let r = try await s.device.openRecoveryOpenResult(envelope, requestID: rid)
                await noteOpenAnswer(r, device: s.device, id: rid)
                if r.ok { return .ok }
                noteEarlierAnswer(r, none: !phoneHasUnansweredOpen(s.device))
                found = .answered(r)
            } catch {
                continue
            }
        }
        return found
    }

    /// An answer to an earlier open that was readable after all: the mark goes only when no open is left unanswered ([none]).
    private func noteEarlierAnswer(_ r: RecoveryOpen.Result, none: Bool) {
        _ = try? record.update(since: record.generation) {
            if none { $0.recoveryOpenUnanswered = false }
            if r.counted { $0.recoveryAttemptsUsed = r.used }
        }
    }

    // MARK: - The identities

    /// Uses [set]'s identity from the next session on: one write of the record, then the session of the other is dropped.
    func selectIdentity(_ set: IdentitySet) async throws {
        // The record and the session in use must both be [set]'s: a session of another identity is dropped even when the record matches.
        let stale = session.map { $0.identity != set } ?? false
        guard record.value.activeIdentity != set || stale else { return }
        _ = await cancelOpening()
        if record.value.activeIdentity != set { try persistRecord(record.generation) { $0.activeIdentity = set } }
        try await dropSession(forget: false)
    }

    /// A forget: fresh keys for the first identity, none for the others (they exist only for a phone that could not tell), a new
    /// app key and no device state.
    nonisolated static func forgetKeys(_ c: VaultManagerConfig) async throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.slots(of: .first) { try keys.generate(slot) }
        for set in IdentitySet.all.dropFirst() {
            for slot in KeySlot.slots(of: set) { try c.keys.wrapped.remove(slot) }
            try c.file(VaultFiles.device(of: set)).clear()
        }
        _ = try c.keys.appKeys.regenerate()
        try c.attester.resetIdentities() // the App Attest keys of the other identities, and the identity in use, are forgotten
        try c.file(VaultFiles.device).clear()
    }

    nonisolated static func makeIdentity(_ c: VaultManagerConfig, _ set: IdentitySet) throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.slots(of: set) { try keys.generate(slot) }
        try c.file(VaultFiles.device(of: set)).clear()
    }

    /// The vault answered `ok` and the pairing completed: every identity that did not pair, its device state and the rule's record
    /// go. Nothing before (IOS-PLAN 0.1.33 §4.9 "What it keeps"); a failure keeps all, and the next look tries again.
    func settleCouldNotTell(winner: IdentitySet? = nil) {
        guard record.value.couldNotTell != nil else { return }
        let winner = winner ?? record.value.activeIdentity
        do {
            for loser in IdentitySet.all where loser != winner {
                for slot in KeySlot.slots(of: loser) { try config.keys.wrapped.remove(slot) }
                try config.file(VaultFiles.device(of: loser)).clear()
                try config.attester.forget(identity: loser.rawValue)
            }
            try persistRecord(record.generation) {
                $0.activeIdentity = winner
                $0.couldNotTell = nil
                $0.couldNotTellRead = nil
            }
        } catch {
            // Kept: nothing is lost by waiting.
        }
    }

    /// The identity of the rule whose device state shows the pairing completed (it paired and has no recovery left), read from the
    /// stored state without any key. It is the winner whatever the record says of the identity in use.
    func pairedIdentity(_ ct: CouldNotTell) -> IdentitySet? {
        ct.identities.first { id in
            guard let bytes = try? config.file(VaultFiles.device(of: id)).load() else { return false }
            return VaultDevice.pairedAfterRecovery(state: bytes)
        }
    }

    /// A start with a switch of identity that did not end (the app was killed during the unlock of another identity): the identity
    /// to go back to is the one in use again (IOS-PLAN 0.1.33 §4.9, "never forget": nothing else changes). True when it changed.
    @discardableResult
    func settleTrial() -> Bool {
        guard moveFlags.book.trialDepth == 0, moveFlags.book.ruleSwitching == 0, let ct = record.value.couldNotTell else { return false }
        let before = record.value.activeIdentity
        // A pairing that completed wins over any marker a write left behind: that identity is the one, and the rest go.
        if let winner = pairedIdentity(ct) {
            settleCouldNotTell(winner: winner)
            return record.value.activeIdentity != before
        }
        guard let back = ct.returnTo else { return false }
        _ = try? record.update(since: record.generation) {
            $0.couldNotTell?.returnTo = nil
            $0.activeIdentity = back
        }
        return record.value.activeIdentity != before
    }

    // MARK: - The unlock with each identity

    /// One identity's turn in the unlock with each identity.
    private enum UnlockStep {
        /// Not an unlock key (it did not register).
        case skip
        /// The vault opened, or answered a PIN wrong (an answer only a key it holds gets).
        case done(RecoveryOpenOutcome)
        case refused(RecoveryOpenOutcome)
        /// Its state could not be opened, or the unlock got no answer ([tried]: the request was made).
        case failed(any Error, tried: Bool)
    }

    private func unlockStep(_ id: IdentitySet, pin: String) async throws -> UnlockStep {
        // An identity whose state cannot be opened is skipped, as one that failed to answer: the others still try.
        let d: VaultDevice
        do {
            try await selectIdentity(id)
            d = try await openSession().device
        } catch {
            if error is CancellationError { throw error }
            return .failed(error, tried: false)
        }
        guard d.recovering || d.recoveryOpenedNotFinished else { return .skip }
        do {
            let out = try await lostOkOnce(pin: pin)
            guard Self.knowsThisPhone(out) else { return out.ok ? .done(out) : .refused(out) }
            // An answer only a key the vault holds ends the run of refusals.
            try persistRecord(record.generation) {
                $0.couldNotTell?.refusalsSinceMs = nil
                $0.couldNotTell?.refusalsForMs = nil
            }
            return .done(out)
        } catch {
            if error is CancellationError { throw error }
            return .failed(error, tried: true)
        }
    }

    /// ``resumeLostOk(pin:)`` while the phone could not tell: the unlock with each identity that may hold the vault's key, newest
    /// first. The first that opens finishes the recovery (its handshake names its own `recovery_id`); a PIN answered wrong is an
    /// answer too (the vault knows this identity). Otherwise everything is kept, the identity in use is the one it was, and after
    /// a day of refusals to a vault that took this phone the second text is shown.
    func resumeLostOkEither(_ ct: CouldNotTell, pin: String) async throws -> RecoveryOpenOutcome {
        let start = record.value.activeIdentity
        moveFlags.book.trialDepth += 1
        defer { moveFlags.book.trialDepth -= 1 }
        // The identity to go back to is written down first: a kill or an error meanwhile goes back to it (``settleTrial()``).
        let outer = record.value.couldNotTell?.returnTo
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = start }
        func back() async {
            try? await selectIdentity(start)
            _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = outer }
        }
        var last: RecoveryOpenOutcome?
        var failure: (any Error)?
        var (transient, tried) = (false, false)
        do {
            for id in ct.identities.reversed() {
                switch try await unlockStep(id, pin: pin) {
                case .skip: continue
                case .done(let out):
                    _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = outer }
                    return out
                case .refused(let out): (last, tried) = (out, true)
                case .failed(let error, let wasTried):
                    failure = failure ?? error
                    tried = tried || wasTried
                    // The network or the service not answering, or a state that cannot be opened, is no refusal.
                    if !wasTried || !Self.isRefusal(error) { transient = true }
                }
            }
            if let now = record.value.couldNotTell, now.unlock, !now.unlockByReads, tried, !transient {
                try noteRefusals()
            }
        } catch {
            await back()
            throw error
        }
        // The identity the screens find: the one it was.
        await back()
        if let last { return last }
        throw failure ?? VaultFailure(.other, code: Self.codeNoBundle)
    }

    /// The identity with the vault's `ok` got no `hs.resp`: the vault answers a handshake it does not accept with nothing, and the
    /// invitation may be an older identity's, under its `recovery_id`. The lost-ok unlock with each other identity, newest first,
    /// then its `hs.init` with that `ctx` (IOS-PLAN 0.1.33 §4.9). Nil when none is the vault's key: nothing changed, the identity
    /// with the `ok` is in use again, and the caller reopens its session. The unlock's refusal code beside the session otherwise.
    func pairEarlierIdentity(pin: String) async throws -> (String?, VaultSession)? {
        guard let ct = record.value.couldNotTell, ct.identities.count > 1 else { return nil }
        let back = record.value.activeIdentity
        moveFlags.book.trialDepth += 1
        defer { moveFlags.book.trialDepth -= 1 }
        // The identity that has the vault's `ok` is written down with the trial: a kill meanwhile goes back to it. Inside the
        // unlock with each identity the marker of that loop is put back at the end, not cleared (a stack of two).
        let outer = ct.returnTo
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = back }
        func end(strict: Bool = false) throws {
            if strict {
                try persistRecord(record.generation) { $0.couldNotTell?.returnTo = outer }
            } else {
                _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = outer }
            }
        }
        for id in ct.identities.reversed() where id != back {
            let other: VaultSession
            let u: UnlockOutcome
            do {
                try await selectIdentity(id)
                other = try await openSession()
                // An identity that never registered is no key.
                guard other.device.recovering || other.device.recoveryOpenedNotFinished else { continue }
                u = try await unlockWithSecret(other, pin: pin, options: UnlockOptions(), path: .current)
            } catch {
                // The unlock did not answer, or was cancelled.
                if error is CancellationError {
                    try? await selectIdentity(back)
                    try? end()
                    throw error
                }
                continue
            }
            guard u.ok else {
                // A PIN answered wrong is the answer of a vault that knows this identity. The `ok` and the token are the other
                // identity's: it stays the one in use (a restart finds it), and the code is said.
                if let code = u.result.code, code == "bad_pin" || code == "backoff" {
                    try await selectIdentity(back)
                    try end(strict: true)
                    return (code, try await openSession())
                }
                continue
            }
            // No bundle: the vault does not hold this identity as the one a completed recovery made its app.
            guard other.device.recoveryOpenedNotFinished else { continue }
            try end(strict: true)
            do {
                try await other.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false))
            } catch let e as VaultStateError where VaultFailures.noResponse(e) {
                if let refusal = try await unlockOwn(other, pin: pin, cause: e) { return (refusal, other) }
                try await other.device.completeRecoveryOpen()
            }
            return (nil, other)
        }
        try await selectIdentity(back)
        try end(strict: true)
        return nil
    }

    /// A refusal to the unlock, as it is thrown (mapped): the member API's `401` or `403`, or an answer that cannot be read.
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        guard let f = error as? VaultFailure else { return false }
        return f.kind == .unauthorized || f.code == "forbidden" || f.code == "unreadable_result"
    }

    /// An answer only a key the vault holds gets: the PIN is wrong, or too many wrong ones. Not a refusal of the phone.
    nonisolated static func knowsThisPhone(_ out: RecoveryOpenOutcome) -> Bool {
        out.opened && (out.code == "bad_pin" || out.code == "backoff")
    }

    /// The unlock did not succeed: the first refusal of a run starts the day after which the second text is shown (a clock set
    /// back starts it again).
    private func noteRefusals() throws {
        let (now, scale) = (nowMs, record.value.timeScale)
        try persistRecord(record.generation) {
            guard var ct = $0.couldNotTell, ct.unlock else { return }
            if let since = ct.refusalsSinceMs, since <= now { return }
            ct.refusalsSinceMs = now
            ct.refusalsForMs = TimeScale.scaledMs(Self.refusalDayMs, by: scale)
            $0.couldNotTell = ct
        }
    }
}
