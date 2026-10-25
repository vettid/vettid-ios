import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

// A phone that could not tell (IOS-PLAN 0.1.33 §4.9; VAULT-MESSAGING 0.59.0 §11.14.6; MEMBER-API 2.12.0, owner decision of
// 2026-10-24, "option A"). An open the member API took got no readable answer and its recovery has ended: the phone cannot tell
// whether the vault adopted it. It reads the status signed with K twice, at least 5 minutes apart with the clock checked; only
// then does it use the phone for a new recovery, with a new device identity and the same K, and the earlier open's unlock
// secret. Nothing is deleted until the vault answered `ok` and the pairing completed: K, both identities (keys and device state:
// the earlier `recovery_id` and the `request_id`s of its opens, `min_header_seq` / `min_state_seq`) and the phone-secret record.
extension VaultManager {
    /// The claim of a new code answered `409 key_in_use` (K is the vault's `app_key`, or a live `app_key_pending`): nothing was
    /// written, the phone is the vault's app, and the lost-ok unlock decides (``RecoveryRegistration/refused(code:recoveryID:)``).
    public nonisolated static let codeKeyInUse = MemberApiError.keyInUse
    /// The two status reads are at least this far apart (5 minutes).
    nonisolated static let readGap: TimeInterval = 5 * 60
    /// How far the phone's clock and its monotonic clock may differ over the gap before the reads are taken as unchecked
    /// (chosen; not in the spec).
    nonisolated static let readClockTolerance: TimeInterval = 2 * 60
    /// The day of refusals after which the second text is shown, divided by the vault's time scale (chosen; not in the spec: the
    /// scale is the one the recovery's other days take).
    nonisolated static let refusalDayMs: Int64 = 86_400_000
    nonisolated static let transferIncomplete = UnlockEpoch.transferIncomplete

    /// What a status read of the rule says.
    enum RuleRead: Equatable, Sendable {
        /// `200` and the recovery shows `registered`: the phone opens again.
        case registered
        /// `200` otherwise: K may be the vault's app key or only its pending next key.
        case notRegistered
        /// `401`, or `410 recovery_ended`.
        case ended
        /// Anything else (the network, a `401` the clock explains, `403`, `5xx`, `vault: null`): decides nothing.
        case undecided
    }

    // MARK: - Where it stands

    /// Where the rule stands for this phone, from what it keeps (no status read).
    public func couldNotTellStage() async throws -> CouldNotTellStage {
        try await guarded { try await currentCouldNotTell() }
    }

    func currentCouldNotTell() async throws -> CouldNotTellStage {
        try prepared()
        guard let ct = record.value.couldNotTell else { return .none }
        let device = try await storedSession()?.device
        // The vault answered `ok` and the pairing completed (the recovery record is gone): the earlier identity and its records
        // may go, and the rule is over.
        if let device, device.deviceID != nil, !device.recovering {
            settleCouldNotTell()
            return .none
        }
        if ct.unlock {
            if let since = ct.refusalsSinceMs, let period = ct.refusalsForMs, nowMs >= since, nowMs - since >= period {
                return .contact
            }
            return .finishWithPin
        }
        // A registered new identity clears `ended`; it is set again when that recovery ended too.
        return ct.ended ? .newCode : .none
    }

    /// Reads the status once when it is due and says where the rule stands (IOS-PLAN 0.1.33 §4.9 "When"). Only while an open the
    /// member API took has no readable answer (``LocalAccount/recoveryOpenUnanswered``); never while the recovery shows
    /// `registered` (the phone opens again); a decision needs two reads of the same kind at least 5 minutes apart, on this phone's
    /// clock and its monotonic clock agreeing. A call made too soon sends nothing.
    public func checkCouldNotTell() async throws -> CouldNotTellStage {
        try await guarded {
            let here = try await currentCouldNotTell()
            let ct = record.value.couldNotTell
            // Decided: a code is what is left, or the unlock after a key in use. An unlock that two reads of `200` led to is read
            // again (K may be only the vault's orphaned pending key, and the host may clear it).
            if let ct, ct.ended || (ct.unlock && (!ct.unlockByReads || ct.new != nil)) { return here }
            guard let device = try await storedSession()?.device, device.recovering else { return here }
            // An open of this identity has no readable answer; or this is the new identity, registered, whose recovery may end.
            let newRegistered = ct?.new != nil && record.value.activeIdentity == ct?.new
            guard record.value.recoveryOpenUnanswered || newRegistered || ct?.transferIncomplete == true else { return here }
            let rec = record.generation
            let (now, up) = (nowMs, config.uptime())
            if let m = record.value.couldNotTellRead, let due = Self.readsAgree(m, nowMs: now, uptime: up), due < Self.readGap {
                return .waiting(until: Date(timeIntervalSince1970: Double(m.atMs) / 1000 + Self.readGap))
            }
            switch await ruleRead() {
            case .registered:
                // The recovery is not over: the phone opens again.
                try persistRecord(rec) {
                    $0.couldNotTellRead = nil
                    guard var ct = $0.couldNotTell, ct.new == nil else { return }
                    ct.transferIncomplete = false
                    if ct.unlockByReads { (ct.unlock, ct.unlockByReads, ct.refusalsSinceMs, ct.refusalsForMs) = (false, false, nil, nil) }
                    $0.couldNotTell = ct.new == nil && !ct.ended && !ct.unlock ? nil : ct
                }
                return try await currentCouldNotTell()
            case .undecided:
                return here
            case .ended: return try await noteRead(ended: true, since: rec, nowMs: now, uptime: up)
            case .notRegistered: return try await noteRead(ended: false, since: rec, nowMs: now, uptime: up)
            }
        }
    }

    /// The second read of a kind, at least the gap after the first, decides; any other read is the first of the next pair. After a
    /// `transfer_incomplete` both kinds are "ended".
    private func noteRead(ended read: Bool, since rec: Int, nowMs now: Int64, uptime up: Double) async throws -> CouldNotTellStage {
        let ended = read || record.value.couldNotTell?.transferIncomplete == true
        if let m = record.value.couldNotTellRead, m.ended == ended, let due = Self.readsAgree(m, nowMs: now, uptime: up),
           due >= Self.readGap {
            try persistRecord(rec) {
                var ct = $0.couldNotTell ?? CouldNotTell(earlier: $0.activeIdentity)
                if ended, ct.new == nil {
                    // Two reads of `401`/`410`: a new code, also after two reads of `200` and a refused unlock.
                    (ct.ended, ct.unlock, ct.unlockByReads, ct.transferIncomplete) = (true, false, false, false)
                    (ct.refusalsSinceMs, ct.refusalsForMs) = (nil, nil)
                } else if ended, !$0.recoveryOpenUnanswered {
                    // The new identity's recovery ended and none of its opens went unanswered: a new code re-registers it.
                    ct.ended = true
                } else if !ended || ct.new != nil {
                    // A third identity is not made: with a new one already, what is left is the unlock with either.
                    if !ct.unlock { ct.unlockByReads = !ended }
                    ct.unlock = true
                }
                $0.couldNotTell = ct
                $0.couldNotTellRead = nil
            }
            return try await currentCouldNotTell()
        }
        try persistRecord(rec) { $0.couldNotTellRead = CouldNotTellRead(ended: ended, atMs: now, uptime: up) }
        return .waiting(until: Date(timeIntervalSince1970: Double(now) / 1000 + Self.readGap))
    }

    /// The seconds between [first] and now when both clocks show the same time passed (within ``readClockTolerance``) and none
    /// ran backwards; nil when they do not (a clock set, a restart of the phone: the first read counts for nothing).
    nonisolated static func readsAgree(_ first: CouldNotTellRead, nowMs: Int64, uptime: Double) -> TimeInterval? {
        let wall = Double(nowMs - first.atMs) / 1000
        let mono = uptime - first.uptime
        guard wall >= 0, mono >= 0, abs(wall - mono) <= readClockTolerance else { return nil }
        return wall
    }

    /// `GET /api/vault/status` signed with K, as the rule reads it. A `401` the phone's clock explains (``MemberApiError/clockSkew``)
    /// is none.
    func ruleRead() async -> RuleRead {
        do {
            guard let status = try await vaultStatus() else { return .undecided }
            return status.recoveryState == "registered" ? .registered : .notRegistered
        } catch let e as MemberApiError {
            if e.status == 401, e.code == MemberApiError.unauthorized { return .ended }
            if e.status == 410, e.code == MemberApiError.recoveryEnded { return .ended }
            return .undecided
        } catch {
            return .undecided
        }
    }

    func persistRecord(_ rec: Int, _ change: (inout LocalAccount) -> Void) throws {
        guard try record.update(since: rec, change) else { throw VaultFailure(.other, code: "record_changed") }
    }

    // MARK: - The new recovery with the same K

    /// Whether a code is registered as the rule's new recovery: the rule decided that the recovery ended, and no new identity is
    /// registered yet.
    var registersAsNewRecovery: Bool {
        guard let ct = record.value.couldNotTell else { return false }
        return ct.ended && !ct.unlock
    }

    /// A vault other than the earlier open's is no use for the rule: its code is refused before anything is claimed.
    func requireEarlierVault(_ vaultID: String) throws {
        if vaultID != record.value.vaultID { throw VaultFailure(.other, code: Self.codeRecoveryOpenUnknown) }
    }

    /// After the claim with K: the earlier open's answer is read once, a new identity is made and registered with K, and the open
    /// that follows carries the earlier open's unlock secret (the phone-secret record is the same).
    /// [claimAgain] is the same claim, made again after a `401` at the register.
    func registerAsNewIdentity(
        _ s: VaultSession, _ code: RecoveryCode, _ claimed: Claimed, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        if record.value.couldNotTell?.new == nil, case let answer = await readEarlierOpen(s) {
            switch answer {
            // A readable `ok` decides it: the vault adopted the earlier open, and the PIN finishes it (kept, so that the stage says so).
            case .ok:
                try persistRecord(record.generation) {
                    $0.couldNotTell?.unlock = true
                    $0.couldNotTell?.ended = false
                }
                return .refused(code: Self.codeRecoveryOpenSent)
            case .answered(let r): noteEarlierAnswer(r)
            case .unreadable: break
            }
        }
        try await switchToNewIdentity()
        let fresh = try await openSession()
        // The new identity's own recovery ended (none of its opens went unanswered): it registers the new code, with the same keys.
        if let known = fresh.device.recoveryID, known != code.recoveryID { try await fresh.device.dropRecoveryRegistration() }
        do {
            let registered = try await registerClaimed(fresh, code, claimed)
            if case .registered = registered { try persistRecord(record.generation) { $0.couldNotTell?.ended = false } }
            return registered
        } catch let e as MemberApiError where e.status == 401 && e.code == MemberApiError.unauthorized && !e.queued {
            // A `401` of the register itself queued nothing: the new identity did not register (and may be registered again).
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

    /// The claim answered `409 key_in_use`: the phone is the vault's app. The lost-ok unlock decides, with the new identity if it
    /// registered, then with the earlier one (``resumeLostOk(pin:)``).
    func claimKeyInUse() async throws -> RecoveryRegistration {
        guard let ct = record.value.couldNotTell else { throw VaultFailure(.other, code: MemberApiError.keyInUse) }
        let rec = record.generation
        try persistRecord(rec) {
            $0.couldNotTell?.unlock = true
            $0.couldNotTellRead = nil
        }
        // An identity that did not register is no unlock key: the PIN screen is on the registered one.
        if ct.new != nil, try await openSession().device.recovering == false { try await selectIdentity(ct.earlier) }
        return .refused(code: Self.codeKeyInUse)
    }

    /// The earlier open's slot, read once (a readable answer decides it).
    enum EarlierOpen {
        case ok
        case answered(RecoveryOpen.Result)
        case unreadable
    }

    func readEarlierOpen(_ s: VaultSession) async -> EarlierOpen {
        guard let rid = s.device.recoveryOpenRequestIDs.first else { return .unreadable }
        do {
            let slot = try await member.slot(rid)
            guard slot.status == Slot.done, let envelope = slot.envelope else { return .unreadable }
            let r = try await s.device.openRecoveryOpenResult(envelope, requestID: rid)
            return r.ok ? .ok : .answered(r)
        } catch {
            return .unreadable
        }
    }

    /// An answer to the earlier open that was readable after all: as at the time, it says whether the record existed.
    private func noteEarlierAnswer(_ r: RecoveryOpen.Result) {
        let rec = record.generation
        _ = try? record.update(since: rec) {
            if r.counted || Self.recordExistedCodes.contains(r.code) { $0.recoveryOpenUnanswered = false }
            if r.counted { $0.recoveryAttemptsUsed = r.used }
        }
    }

    // MARK: - The identities

    /// Makes the new identity (once) and uses it: its keys and device state are new, the earlier identity's untouched. The new
    /// one is recorded together with the switch, so that a kill before leaves only keys nobody refers to.
    func switchToNewIdentity() async throws {
        guard let ct = record.value.couldNotTell else { throw VaultFailure(.other, code: "no_rule") }
        _ = await cancelOpening() // a session being opened for the other identity must not interleave
        let n = ct.new ?? ct.earlier.other
        if ct.new == nil {
            // Keys the App Attest record may still hold for this number (an earlier episode) are not the new identity's.
            try config.attester.forget(identity: n.rawValue)
            try Self.makeIdentity(config, n)
            try persistRecord(record.generation) {
                $0.couldNotTell?.new = n
                $0.activeIdentity = n
            }
            try await dropSession(forget: false)
        } else {
            try await selectIdentity(n)
        }
    }

    /// Uses [set]'s identity from the next session on: one write of the record, then the session of the other is dropped.
    func selectIdentity(_ set: IdentitySet) async throws {
        guard record.value.activeIdentity != set else { return }
        _ = await cancelOpening()
        try persistRecord(record.generation) { $0.activeIdentity = set }
        try await dropSession(forget: false)
    }

    /// A forget: fresh keys for the first identity, none for the second (it exists only for a phone that could not tell), a new
    /// app key and no device state.
    nonisolated static func forgetKeys(_ c: VaultManagerConfig) async throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.slots(of: .first) { try keys.generate(slot) }
        for slot in KeySlot.slots(of: .second) { try c.keys.wrapped.remove(slot) }
        _ = try c.keys.appKeys.regenerate()
        try c.attester.resetIdentities() // the App Attest keys of the second identity, and the identity in use, are forgotten
        try c.file(VaultFiles.device).clear()
        try c.file(VaultFiles.device2).clear()
    }

    private nonisolated static func makeIdentity(_ c: VaultManagerConfig, _ set: IdentitySet) throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.slots(of: set) { try keys.generate(slot) }
        try c.file(VaultFiles.device(of: set)).clear()
    }

    /// The vault answered `ok` and the pairing completed: the identity that did not pair, its device state and the rule's record
    /// go. Nothing before (IOS-PLAN 0.1.33 §4.9 "What it keeps"); a failure keeps all, and the next look tries again.
    func settleCouldNotTell() {
        guard record.value.couldNotTell != nil else { return }
        let loser = record.value.activeIdentity.other
        do {
            for slot in KeySlot.slots(of: loser) { try config.keys.wrapped.remove(slot) }
            try config.file(VaultFiles.device(of: loser)).clear()
            try config.attester.forget(identity: loser.rawValue)
            try persistRecord(record.generation) {
                $0.couldNotTell = nil
                $0.couldNotTellRead = nil
            }
        } catch {
            // Kept: nothing is lost by waiting.
        }
    }

    // MARK: - The unlock with either identity

    /// The identities that may be the vault's unlock key, in the order of the rule: the new one if it registered, then the earlier.
    private func unlockOrder(_ ct: CouldNotTell) -> [IdentitySet] {
        guard let new = ct.new else { return [ct.earlier] }
        return [new, ct.earlier]
    }

    /// ``resumeLostOk(pin:)`` while the phone could not tell: the unlock with each identity that may hold the vault's key. The
    /// first that opens finishes the recovery (its handshake names its own `recovery_id`); a PIN answered wrong is an answer too
    /// (the vault knows this identity). Otherwise everything is kept, and after a day of refusals the second text is shown.
    func resumeLostOkEither(_ ct: CouldNotTell, pin: String) async throws -> RecoveryOpenOutcome {
        let start = record.value.activeIdentity
        var last: RecoveryOpenOutcome?
        var failure: (any Error)?
        var transient = false
        var tried = false
        for id in unlockOrder(ct) {
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
                if out.ok || Self.knowsThisPhone(out) { return out }
                last = out
            } catch {
                if error is CancellationError { throw error }
                failure = failure ?? error
                // The network or the service not answering is no refusal.
                if !Self.isRefusal(error) { transient = true }
            }
        }
        if record.value.couldNotTell?.unlock == true, tried, !transient { try noteRefusals() }
        // The identity the screens find: the registered one, as before.
        try await selectIdentity(start)
        if let last { return last }
        throw failure ?? VaultFailure(.other, code: Self.codeNoBundle)
    }

    /// The new identity's handshake got no `hs.resp`: the vault answers a handshake it does not accept with nothing, and after the
    /// new open's `ok` the invitation may be the earlier identity's, under the earlier `recovery_id`. The lost-ok unlock with the
    /// earlier identity, then its `hs.init` with that `ctx` (IOS-PLAN 0.1.33 §4.9). Nil when it is not the earlier identity's:
    /// nothing changed, and the new identity goes on. The unlock's refusal code beside the session otherwise.
    func pairEarlierIdentity(pin: String) async throws -> (String?, VaultSession)? {
        guard let ct = record.value.couldNotTell, ct.earlier != record.value.activeIdentity else { return nil }
        let back = record.value.activeIdentity
        // The identity that has the vault's `ok` is written down with the trial: a kill meanwhile goes back to it (``settleTrial()``).
        try persistRecord(record.generation) { $0.couldNotTell?.opened = back; $0.couldNotTell?.trial = true }
        func end(opened: IdentitySet) throws {
            try persistRecord(record.generation) { $0.couldNotTell?.opened = opened; $0.couldNotTell?.trial = false }
        }
        let earlier: VaultSession
        let u: UnlockOutcome
        do {
            try await selectIdentity(ct.earlier)
            earlier = try await openSession()
            u = try await unlockWithSecret(earlier, pin: pin, options: UnlockOptions(), path: .current)
        } catch {
            // The unlock did not answer, or was cancelled: the identity that has the `ok` is the one in use again.
            try? await selectIdentity(back)
            try? end(opened: back)
            if error is CancellationError { throw error }
            return nil
        }
        guard u.ok else {
            // A PIN answered wrong is the answer of a vault that knows this identity: it is said, and the identity stays.
            if let code = u.result.code, code == "bad_pin" || code == "backoff" {
                try end(opened: ct.earlier)
                return (code, earlier)
            }
            try await selectIdentity(back)
            try end(opened: back)
            return nil
        }
        // No bundle: the vault does not hold this identity as the one a completed recovery made its app.
        guard earlier.device.recoveryOpenedNotFinished else {
            try await selectIdentity(back)
            try end(opened: back)
            return nil
        }
        try end(opened: ct.earlier)
        do {
            try await earlier.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false))
        } catch let e as VaultStateError where VaultFailures.noResponse(e) {
            if let refusal = try await unlockOwn(earlier, pin: pin, cause: e) { return (refusal, earlier) }
            try await earlier.device.completeRecoveryOpen()
        }
        return (nil, earlier)
    }

    /// A start with a trial of the earlier identity's unlock that did not end (the app was killed): the identity that has the vault's
    /// `ok` is the one in use (IOS-PLAN 0.1.33 §4.9, "never forget": nothing else changes).
    func settleTrial() {
        guard let ct = record.value.couldNotTell, ct.trial else { return }
        _ = try? record.update(since: record.generation) {
            $0.couldNotTell?.trial = false
            if let opened = ct.opened { $0.activeIdentity = opened }
        }
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

    /// The unlock answered `transfer_incomplete` (the state is still under `DEK_0`, only an open repeats the recovery): the phone
    /// opens again while its recovery shows `registered`; otherwise the rule applies, on the same two reads as every other decision
    /// (a single `401` can be a clock or a nonce). The unlock of two reads of `200` is given up for it. IOS-PLAN 0.1.33 §4.9.
    func noteTransferIncomplete() async throws {
        // An unlock that a key in use led to stays: K is the vault's app key.
        if let ct = record.value.couldNotTell, ct.unlock, !ct.unlockByReads { return }
        try persistRecord(record.generation) {
            var ct = $0.couldNotTell ?? CouldNotTell(earlier: $0.activeIdentity)
            if ct.new == nil {
                (ct.unlock, ct.unlockByReads, ct.refusalsSinceMs, ct.refusalsForMs) = (false, false, nil, nil)
                ct.transferIncomplete = true
            }
            $0.couldNotTell = ct
            $0.couldNotTellRead = nil
        }
        _ = try? await checkCouldNotTell()
    }
}
