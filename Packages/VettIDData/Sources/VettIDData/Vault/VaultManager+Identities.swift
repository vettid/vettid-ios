import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

// The identities of a phone that could not tell (IOS-PLAN 0.1.33 §4.9; chosen; not in the spec: as many as ``IdentitySet/limit``).
// Each new code makes a new device identity (its keys, its device state with its own `recovery_id` and the history of its opens,
// and the App Attest keys the vault bound to it) unless the newest one never had an unanswered open; nothing is deleted until the
// vault answered `ok` and the pairing completed. The lost-ok unlock tries the newest identity first, and each pairs only with its
// own `recovery_id` as `ctx`.
extension VaultManager {
    /// A new code would need more identities than ``IdentitySet/limit``: nothing is registered, and the unlock with each of
    /// the identities that are kept stays possible.
    public nonisolated static let codeIdentitiesFull = "identities_full"

    // MARK: - The new recovery with the same K

    /// Whether a code is registered as the rule's new recovery: the rule decided that the recovery ended.
    var registersAsNewRecovery: Bool {
        guard let ct = record.value.couldNotTell else { return false }
        return ct.ended && !ct.unlock
    }

    /// A vault other than the earlier open's is no use for the rule: its code is refused before anything is claimed.
    func requireEarlierVault(_ vaultID: String) throws {
        if vaultID != record.value.vaultID { throw VaultFailure(.other, code: Self.codeRecoveryOpenUnknown) }
    }

    /// Switching identities for the rule: a status read of the rule waits.
    func withRuleSwitch<T>(_ body: () async throws -> T) async throws -> T {
        moveFlags.book.ruleSwitching += 1
        defer { moveFlags.book.ruleSwitching -= 1 }
        return try await body()
    }

    /// After the claim with K: the unanswered opens of the newest identity are read once each (a readable answer decides), then an
    /// identity registers the code with K, and the open that follows carries the earlier opens' unlock secret (the phone-secret
    /// record is the same). [claimAgain] is the same claim, made again after a `401` at the register.
    func registerAsNewIdentity(
        _ code: RecoveryCode, _ claimed: Claimed, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        try await withRuleSwitch {
            guard let ct = record.value.couldNotTell else { throw VaultFailure(.other, code: "no_rule") }
            try await selectIdentity(ct.newest)
            if case .ok = await readUnansweredOpens(try await openSession()) {
                // A readable `ok` decides it: the vault adopted that open, and the PIN finishes it (kept, so that the stage says so).
                try persistRecord(record.generation) {
                    $0.couldNotTell?.unlock = true
                    $0.couldNotTell?.ended = false
                }
                return .refused(code: Self.codeRecoveryOpenSent)
            }
            let fresh = try await identityForNewCode(ct)
            // The identity's own recovery ended with no unanswered open: it registers the new code, with the same keys.
            if let known = fresh.device.recoveryID, known != code.recoveryID {
                // Never a `recovery_id` the vault may hold an invitation under.
                if fresh.device.recoveryOpenEverUnanswered { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
                try await fresh.device.dropRecoveryRegistration()
            }
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

    /// The identity that registers the new code: the newest again when it never had an unanswered open (more than one identity),
    /// else the next one, which starts from the floors the newest has seen. The identity in use is the one returned.
    private func identityForNewCode(_ ct: CouldNotTell) async throws -> VaultSession {
        let current = try await openSession()
        if ct.identities.count > 1, !current.device.recoveryOpenEverUnanswered { return current }
        guard let n = ct.newest.next else { throw VaultFailure(.other, code: Self.codeIdentitiesFull) }
        let floors = current.device.altState
        _ = await cancelOpening() // a session being opened for another identity must not interleave
        // Keys the App Attest record may still hold for this number (an earlier episode) are not the new identity's.
        try config.attester.forget(identity: n.rawValue)
        try Self.makeIdentity(config, n)
        try persistRecord(record.generation) {
            $0.couldNotTell?.identities.append(n)
            $0.activeIdentity = n
        }
        try await dropSession(forget: false)
        let fresh = try await openSession()
        try await fresh.device.seedFloors(from: floors)
        return fresh
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
                try await selectIdentity(id)
                if try await openSession().device.recovering { return }
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
        for rid in s.device.unansweredOpenRequestIDs {
            do {
                let slot = try await member.slot(rid)
                guard slot.status == Slot.done, let envelope = slot.envelope else { continue }
                let r = try await s.device.openRecoveryOpenResult(envelope, requestID: rid)
                await noteOpenAnswer(r, device: s.device, id: rid)
                if r.ok { return .ok }
                noteEarlierAnswer(r)
                found = .answered(r)
            } catch {
                continue
            }
        }
        return found
    }

    /// An answer to an earlier open that was readable after all: as at the time, it says whether the record existed.
    private func noteEarlierAnswer(_ r: RecoveryOpen.Result) {
        _ = try? record.update(since: record.generation) {
            if r.counted || Self.recordExistedCodes.contains(r.code) { $0.recoveryOpenUnanswered = false }
            if r.counted { $0.recoveryAttemptsUsed = r.used }
        }
    }

    // MARK: - The identities

    /// Uses [set]'s identity from the next session on: one write of the record, then the session of the other is dropped.
    func selectIdentity(_ set: IdentitySet) async throws {
        guard record.value.activeIdentity != set else { return }
        _ = await cancelOpening()
        try persistRecord(record.generation) { $0.activeIdentity = set }
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
    func settleCouldNotTell() {
        guard record.value.couldNotTell != nil else { return }
        let winner = record.value.activeIdentity
        do {
            for loser in IdentitySet.all where loser != winner {
                for slot in KeySlot.slots(of: loser) { try config.keys.wrapped.remove(slot) }
                try config.file(VaultFiles.device(of: loser)).clear()
                try config.attester.forget(identity: loser.rawValue)
            }
            try persistRecord(record.generation) {
                $0.couldNotTell = nil
                $0.couldNotTellRead = nil
            }
        } catch {
            // Kept: nothing is lost by waiting.
        }
    }

    /// A start with a switch of identity that did not end (the app was killed during the unlock of another identity): the identity
    /// to go back to is the one in use again (IOS-PLAN 0.1.33 §4.9, "never forget": nothing else changes). True when it changed.
    @discardableResult
    func settleTrial() -> Bool {
        guard !moveFlags.book.trialRunning, moveFlags.book.ruleSwitching == 0, let ct = record.value.couldNotTell,
              let back = ct.returnTo else { return false }
        let before = record.value.activeIdentity
        _ = try? record.update(since: record.generation) {
            $0.couldNotTell?.returnTo = nil
            $0.activeIdentity = back
        }
        return record.value.activeIdentity != before
    }

    // MARK: - The unlock with each identity

    /// ``resumeLostOk(pin:)`` while the phone could not tell: the unlock with each identity that may hold the vault's key, newest
    /// first. The first that opens finishes the recovery (its handshake names its own `recovery_id`); a PIN answered wrong is an
    /// answer too (the vault knows this identity). Otherwise everything is kept, the identity in use is the one it was, and after
    /// a day of refusals to a vault that took this phone the second text is shown.
    func resumeLostOkEither(_ ct: CouldNotTell, pin: String) async throws -> RecoveryOpenOutcome {
        let start = record.value.activeIdentity
        moveFlags.book.trialRunning = true
        defer { moveFlags.book.trialRunning = false }
        // The identity to go back to is written down first: a kill or an error meanwhile goes back to it (``settleTrial()``).
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = start }
        var last: RecoveryOpenOutcome?
        var failure: (any Error)?
        var transient = false
        var tried = false
        do {
            for id in ct.identities.reversed() {
                try await selectIdentity(id)
                // An identity that did not register is no unlock key.
                let d = try await openSession().device
                guard d.recovering || d.recoveryOpenedNotFinished else { continue }
                tried = true
                do {
                    let out = try await lostOkOnce(pin: pin)
                    if Self.knowsThisPhone(out) {
                        // An answer only a key the vault holds gets ends the run of refusals.
                        try persistRecord(record.generation) {
                            $0.couldNotTell?.refusalsSinceMs = nil
                            $0.couldNotTell?.refusalsForMs = nil
                        }
                    }
                    if out.ok || Self.knowsThisPhone(out) {
                        _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = nil }
                        return out
                    }
                    last = out
                } catch {
                    if error is CancellationError { throw error }
                    failure = failure ?? error
                    // The network or the service not answering is no refusal.
                    if !Self.isRefusal(error) { transient = true }
                }
            }
            if let now = record.value.couldNotTell, now.unlock, !now.unlockByReads, tried, !transient { try noteRefusals() }
        } catch {
            try? await selectIdentity(start)
            _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = nil }
            throw error
        }
        // The identity the screens find: the one it was.
        try await selectIdentity(start)
        _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = nil }
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
        moveFlags.book.trialRunning = true
        defer { moveFlags.book.trialRunning = false }
        // The identity that has the vault's `ok` is written down with the trial: a kill meanwhile goes back to it.
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = back }
        func end() { _ = try? record.update(since: record.generation) { $0.couldNotTell?.returnTo = nil } }
        for id in ct.identities.reversed() where id != back {
            let other: VaultSession
            let u: UnlockOutcome
            do {
                try await selectIdentity(id)
                other = try await openSession()
                u = try await unlockWithSecret(other, pin: pin, options: UnlockOptions(), path: .current)
            } catch {
                // The unlock did not answer, or was cancelled.
                if error is CancellationError {
                    try? await selectIdentity(back)
                    end()
                    throw error
                }
                continue
            }
            guard u.ok else {
                // A PIN answered wrong is the answer of a vault that knows this identity. The `ok` and the token are the other
                // identity's: it stays the one in use (a restart finds it), and the code is said.
                if let code = u.result.code, code == "bad_pin" || code == "backoff" {
                    try await selectIdentity(back)
                    end()
                    return (code, try await openSession())
                }
                continue
            }
            // No bundle: the vault does not hold this identity as the one a completed recovery made its app.
            guard other.device.recoveryOpenedNotFinished else { continue }
            end()
            do {
                try await other.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false))
            } catch let e as VaultStateError where VaultFailures.noResponse(e) {
                if let refusal = try await unlockOwn(other, pin: pin, cause: e) { return (refusal, other) }
                try await other.device.completeRecoveryOpen()
            }
            return (nil, other)
        }
        try await selectIdentity(back)
        end()
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
