import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

// A phone that could not tell (IOS-PLAN 0.1.35 §4.9; VAULT-MESSAGING 0.62.0 §11.14.6; MEMBER-API 2.12.0, owner decisions of
// 2026-10-24, "option A", and 2026-10-25). An open the member API took got no readable answer and its recovery has ended: the phone
// cannot tell whether the vault adopted it. It reads the status signed with K twice, at least 5 minutes apart with the clock
// checked; only then does it use the phone for a new recovery, with a new device identity (N, reused for every further recovery)
// and the same K, and the earlier open's unlock secret. Nothing is deleted until the vault answered `ok` and the pairing completed:
// K, both identities (keys and device state: its `recovery_id`, the history of its opens, `min_header_seq` / `min_state_seq`), their
// App Attest keys and the phone-secret record. The identities are in ``VaultManager+Identities``.
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
        // A trial a kill interrupted that was not settled at the start (``settleTrial()``) is settled now.
        if settleTrial(), session != nil { try await dropSession(forget: false) }
        guard let ct = record.value.couldNotTell else { return .none }
        let device = try await storedSession()?.device
        // The vault answered `ok` and the pairing completed (the recovery record is gone): the other identities and their records
        // may go, and the rule is over.
        if let device, device.deviceID != nil, !device.recovering {
            settleCouldNotTell()
            return .none
        }
        // An identity holds an `ok` that is not finished: the PIN finishes it, whatever else the reads said.
        if identityHoldingOk(ct) != nil { return .finishWithPin }
        if ct.unlock {
            // N's recovery ended too: the unlock, and a new code with N again; no text after a day of refusals (§4.9).
            if ct.bothEnded { return .unlockOrNewCode }
            // A text after a day of refusals is only for a vault that took this phone (a key in use); not for a `200` that may be
            // an orphaned key.
            if ct.keyInUse, let since = ct.refusalsSinceMs, let period = ct.refusalsForMs, nowMs >= since, nowMs - since >= period {
                return .contact
            }
            return .finishWithPin
        }
        return ct.ended ? .newCode : .none
    }

    /// Reads the status once when it is due and says where the rule stands (IOS-PLAN 0.1.33 §4.9 "When"). Only while an open the
    /// member API took has no answer that proves no step 1 was stored (the history of ``VaultDevice/recoveryOpens``, sticky); never
    /// while the recovery shows `registered` (the phone opens again); a decision needs two reads of the same kind at least 5
    /// minutes apart, on this phone's clock and its monotonic clock agreeing. A call made too soon sends nothing, and none is made
    /// while identities are being switched.
    public func checkCouldNotTell() async throws -> CouldNotTellStage { try await checkRule(duringSwitch: false) }

    /// [duringSwitch]: the read of the identity in use that an unlock with it asks for (`transfer_incomplete`), made while the
    /// identities are switched. Once N's recovery ended too, a read that decides nothing leaves the stage as it is: the unlock and a
    /// new code stay offered (IOS-PLAN 0.1.35 §4.9, "not terminal").
    func checkRule(duringSwitch: Bool) async throws -> CouldNotTellStage {
        let stage = try await readRule(duringSwitch: duringSwitch)
        if case .waiting = stage, record.value.couldNotTell?.bothEnded == true { return try await couldNotTellStage() }
        return stage
    }

    private func readRule(duringSwitch: Bool) async throws -> CouldNotTellStage {
        try await guarded {
            let here = try await currentCouldNotTell()
            let ct = record.value.couldNotTell
            let switching = moveFlags.book.ruleSwitching > 0 || moveFlags.book.trialDepth > 0
            // Decided for a new code: nothing more to read, unless N's recovery ended too (a recovery that shows `registered` again
            // is opened again, §4.9).
            if (ct?.ended == true && ct?.bothEnded != true) || (switching && !duringSwitch) { return here }
            guard try await hasSomethingToRead(ct) else { return here }
            let rec = record.generation
            let (now, up) = (nowMs, config.uptime())
            if let m = record.value.couldNotTellRead, let due = Self.readsAgree(m, nowMs: now, uptime: up), due < Self.readGap {
                return .waiting(until: Date(timeIntervalSince1970: Double(m.atMs) / 1000 + Self.readGap))
            }
            switch await ruleRead() {
            case .registered:
                return try await noteRegistered(ct, duringSwitch: duringSwitch, since: rec, nowMs: now, uptime: up)
            case .undecided:
                return here
            case .ended: return try await noteRead(ended: true, since: rec, nowMs: now, uptime: up)
            case .notRegistered: return try await noteRead(ended: false, since: rec, nowMs: now, uptime: up)
            }
        }
    }

    /// Whether the identity in use is registered, has no `ok` still to finish (the screens finish it, and no decision contradicts
    /// them), and either the rule is entered or an open of it is, or ever was, unanswered. Once entered, the status is read for as
    /// long as the decision is open (also after a key in use, §4.9: "read the status again later").
    private func hasSomethingToRead(_ ct: CouldNotTell?) async throws -> Bool {
        // Any identity with an `ok` still to be finished: the screens finish it, and no decision contradicts them.
        if let ct, identityHoldingOk(ct) != nil { return false }
        guard let device = try await storedSession()?.device, device.recovering else { return false }
        if device.recoveryOpenedNotFinished || device.recoveryOpens.contains(where: { $0.state == .ok }) { return false }
        await convertLegacyUnanswered(device)
        return ct != nil || record.value.recoveryOpenUnanswered || device.recoveryOpenEverUnanswered
    }

    /// A read showing the recovery `registered`: it is not over, and the phone opens again (with N when there is one: K's recovery is
    /// the one N last registered for). What the rule decided changes only on the pair of reads (§4.9 "The two status reads"),
    /// except after a `transfer_incomplete`, whose own read decides (chosen; not in the spec: as vettid-android, whose lost-ok
    /// unlock reads the status once after `transfer_incomplete`).
    private func noteRegistered(
        _ ct: CouldNotTell?, duringSwitch: Bool, since rec: Int, nowMs now: Int64, uptime up: Double
    ) async throws -> CouldNotTellStage {
        if let ct, !ct.transferIncomplete, !duringSwitch, !pairOfRegistered(nowMs: now, uptime: up) {
            try persistRecord(rec) { $0.couldNotTellRead = CouldNotTellRead(ended: false, atMs: now, uptime: up, registered: true) }
            return .waiting(until: Date(timeIntervalSince1970: Double(now) / 1000 + Self.readGap))
        }
        try persistRecord(rec) {
            $0.couldNotTellRead = nil
            guard var ct = $0.couldNotTell else { return }
            ct.transferIncomplete = false
            if ct.unlockByReads || ct.bothEnded {
                (ct.unlock, ct.unlockByReads, ct.bothEnded, ct.refusalsSinceMs, ct.refusalsForMs) = (false, false, false, nil, nil)
            }
            if let n = ct.new {
                if !ct.unlock { (ct.ended, $0.activeIdentity) = (false, n) }
                $0.couldNotTell = ct
            } else {
                $0.couldNotTell = !ct.ended && !ct.unlock ? nil : ct
            }
        }
        return try await currentCouldNotTell()
    }

    /// Whether a read showing `registered` now is the second of a pair: the first showed it too, at least the gap before, on both
    /// clocks.
    private func pairOfRegistered(nowMs now: Int64, uptime up: Double) -> Bool {
        guard let m = record.value.couldNotTellRead, m.registered, let due = Self.readsAgree(m, nowMs: now, uptime: up) else {
            return false
        }
        return due >= Self.readGap
    }

    /// The second read of a kind, at least the gap after the first, decides; any other read is the first of the next pair. After a
    /// `transfer_incomplete` both kinds are "ended".
    private func noteRead(ended read: Bool, since rec: Int, nowMs now: Int64, uptime up: Double) async throws -> CouldNotTellStage {
        let ended = read || record.value.couldNotTell?.transferIncomplete == true
        if let m = record.value.couldNotTellRead, m.ended == ended, !m.registered, let due = Self.readsAgree(m, nowMs: now, uptime: up),
           due >= Self.readGap {
            try persistRecord(rec) {
                var ct = $0.couldNotTell ?? CouldNotTell(earlier: $0.activeIdentity)
                if ended {
                    // Two reads of `401`/`410`: a new code with N, also after two reads of `200` and a refused unlock; with N
                    // already there, its recovery ended too: both are kept, the unlock with each (N first) is tried, and a new code
                    // registers N again (§4.9). An unlock that a key in use led to stays.
                    if !ct.unlock || ct.unlockByReads {
                        let both = ct.identities.count > 1
                        (ct.ended, ct.unlock, ct.unlockByReads, ct.transferIncomplete) = (true, both, false, false)
                        ct.bothEnded = both
                        (ct.refusalsSinceMs, ct.refusalsForMs) = (nil, nil)
                    }
                } else if !ct.unlock {
                    (ct.unlock, ct.unlockByReads) = (true, true)
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
            // (Status with K is always of K's own vault: a code of another vault is refused before anything is registered.)
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

    /// The unlock answered `transfer_incomplete` (the state is still under `DEK_0`, only an open repeats the recovery): the phone
    /// opens again while its recovery shows `registered`; otherwise the rule applies, on the same two reads as every other decision
    /// (a single `401` can be a clock or a nonce). The unlock of two reads of `200` is given up for it. IOS-PLAN 0.1.33 §4.9.
    func noteTransferIncomplete() async throws {
        // An unlock that a key in use led to stays: K is the vault's app key.
        if let ct = record.value.couldNotTell, ct.unlock, !ct.unlockByReads { return }
        try persistRecord(record.generation) {
            var ct = $0.couldNotTell ?? CouldNotTell(earlier: $0.activeIdentity)
            (ct.unlock, ct.unlockByReads, ct.refusalsSinceMs, ct.refusalsForMs) = (false, false, nil, nil)
            ct.transferIncomplete = true
            $0.couldNotTell = ct
            $0.couldNotTellRead = nil
        }
        _ = try? await checkRule(duringSwitch: true)
    }

    /// Whether an open before [id] is unanswered, on any identity of this phone (§4.10: "a phone with no earlier unanswered open").
    /// An identity after the first of a phone that could not tell exists because an earlier one's open is, so for it the answer is
    /// yes; for the first identity it is its own history.
    func earlierUnanswered(before id: String, device: VaultDevice) -> Bool {
        let opens = device.recoveryOpens
        if let i = opens.firstIndex(where: { $0.id == id }), opens[..<i].contains(where: { $0.state == .unanswered }) { return true }
        guard let ct = record.value.couldNotTell else { return false }
        return record.value.activeIdentity != ct.earlier
    }

    /// An answer that proves no step 1 was stored (IOS-PLAN 0.1.35 §4.10): only a code from the vault's readable answer, and only
    /// `busy`, `wrong_again`, `attempt_lost`, `exhausted`, `not_armed`, `closed`, the counter-down answer and the wait verdicts on
    /// their own, each for the open it answers alone; `wrong` and `expired` only for a phone with no earlier unanswered open. A
    /// slot `expired`, a 404, 410 or 5xx on the poll, no answer, `retry`, `transfer_incomplete` and any error are unanswered.
    nonisolated static func refusalProves(_ code: String, earlierUnanswered: Bool) -> Bool {
        let alone: Set = [
            "busy", "wrong_again", "attempt_lost", "exhausted", "not_armed", "closed", "counter_unavailable", "wait", "quiet",
        ]
        return alone.contains(code) || (!earlierUnanswered && (code == "wrong" || code == "expired"))
    }

    /// The answers of a fresh open that rule recovery of this vault out until its owner's app arms a new generation (IOS-PLAN 0.1.35
    /// §4.9): none can follow a stored step 1.
    nonisolated static let ruledOut: Set = ["exhausted", "closed", "not_armed"]

    /// Whether the answer [code] to an open of the identity in use is the contact text "This phone could not recover your vault…"
    /// (`recover_could_not_recover`, §4.9): N's open, K not the vault's key, and an answer that rules recovery out. Not terminal: a
    /// later recovery the member starts registers N again. Mirrors vettid-android `Rules.showCouldNotRecover`.
    func couldNotRecover(_ code: String) -> Bool {
        guard let ct = record.value.couldNotTell, let n = ct.new, record.value.activeIdentity == n else { return false }
        return !ct.keyInUse && Self.ruledOut.contains(code)
    }

    /// What became known of the open [id] with the answer [r], written to its entry of the history: `ok` decides; a refusal that
    /// proves no step 1 marks this entry only, and never changes an earlier open's.
    func noteOpenAnswer(_ r: RecoveryOpen.Result, device: VaultDevice, id: String) async {
        if r.ok {
            try? await device.markRecoveryOpen(id, .ok)
        } else if Self.refusalProves(r.code, earlierUnanswered: earlierUnanswered(before: id, device: device)) {
            try? await device.markRecoveryOpen(id, .refused(r.code))
        }
    }

    /// The identity of the rule whose stored state holds an `ok` that is not finished (read without keys), if any.
    func identityHoldingOk(_ ct: CouldNotTell) -> IdentitySet? {
        ct.identities.first { id in
            guard let bytes = try? config.file(VaultFiles.device(of: id)).load() else { return false }
            return VaultDevice.okToFinish(state: bytes)
        }
    }

    /// Whether any open of this phone is unanswered: the identity in use (live) or, for a phone that could not tell, any identity
    /// of the rule (stored state, no keys). §4.10 counts the phone, not the identity.
    func phoneHasUnansweredOpen(_ device: VaultDevice) -> Bool {
        if device.recoveryOpenEverUnanswered { return true }
        guard let ct = record.value.couldNotTell else { return false }
        return ct.identities.contains { id in
            guard let bytes = try? config.file(VaultFiles.device(of: id)).load() else { return false }
            return VaultDevice.hasUnansweredOpen(state: bytes)
        }
    }

    /// An open that went out in a build before the history existed is one unanswered entry (the record's mark says so), written
    /// once and before the mark can be cleared: a later refusal never clears it.
    func convertLegacyUnanswered(_ device: VaultDevice) async {
        guard record.value.recoveryOpenUnanswered, device.recovering, device.recoveryOpens.isEmpty else { return }
        try? await device.addLegacyUnansweredOpen()
    }
}
