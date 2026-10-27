import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

// The recovery open (VAULT-MESSAGING §11.14.6, release R) on the registered phone: the sealed `vault.recovery.open`, its
// result, which pins the vault and gives the phone its first token, and the first handshake that follows. Mirrors
// vettid-android `VaultDevice`'s "recovery open" section. The recovery of before release R (§11.11.5 steps 1 to 3:
// a recovering app's unlock, `credential.recover`) is not implemented on iOS (IOS-PLAN ID8).
extension VaultDevice {
    /// (Release R, §11.14.6) The vault is pinned from a recovery's result but the recovery is not finished (the first
    /// handshake or the credential did not complete): the vault answered `ok` and made this phone its app. Ends with
    /// ``finishRecoveryOpen()``.
    public var recoveryOpenedNotFinished: Bool { mem.withLock { st.vault != nil && st.recovery != nil } }

    /// The `recovery_id` this app is registered for, while recovering.
    public var recoveryID: String? { mem.withLock { st.recovery?.recoveryID } }

    /// While recovering: the vault's `credential_backup` from this app's unlock result (§11.11.5 step 1, a vault before
    /// release R); nil when not reported. A release R vault does not send it (§11.14.6 "What is removed in release R").
    public var recoveryCredentialBackup: Bool? { mem.withLock { st.recovery?.credentialBackup } }

    /// `vault.recovery.open`: the registered phone's PIN, password and unlock secret, with an open token for its own
    /// mailbox (the vault's relay key is not known yet), signed by its identity key.
    public func prepareRecoveryOpen( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, password: String, unlockSecret: [UInt8], enclave: VerifiedEnclave,
        manifest: ReleaseManifest, attester: Attester
    ) async throws -> SealedRequest {
        try await lock.withLock {
            let (vid, rec): (String, RecoveryRecord) = try mem.withLock {
                guard let vid = st.vaultID else { throw VaultStateError(message: "no vault id") }
                guard let rec = st.recovery else { throw VaultStateError(message: "no recovery registered") }
                return (vid, rec)
            }
            let tok = try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL)
            let req = try AltRequests.buildRecoveryOpen(
                userGuid: userGuid, vaultID: vid, recoveryID: rec.recoveryID, pin: pin, password: password,
                unlockSecret: unlockSecret, enclave: enclave, manifest: manifest, attester: attester, ik: secrets.identity,
                token: tok, now: now()
            )
            // Kept, unanswered, before the request is posted, in one save: a kill between the two, or a response that is lost after
            // the member API took the request, must not lose an open that went out. A save that fails posts nothing.
            mem.withLock {
                guard var record = st.recovery else { return }
                record.opens = (record.opens ?? []) + [RecoveryOpenEntry(id: req.requestID, state: .unanswered)]
                st.recovery = record
            }
            do {
                try save()
            } catch {
                mem.withLock {
                    guard var record = st.recovery else { return }
                    record.opens?.removeAll { $0.id == req.requestID }
                    st.recovery = record
                }
                throw error
            }
            return req
        }
    }

    /// Whether a stored device state (its decrypted bytes) holds an open the vault answered `ok` that is not finished (the vault is
    /// pinned and the recovery record is still there, or an entry of the history is `ok`). Reads no keys.
    public static func okToFinish(state bytes: [UInt8]) -> Bool {
        guard let st = try? JSONDecoder().decode(DeviceState.self, from: Data(bytes)), let recovery = st.recovery else { return false }
        return st.vault != nil || (recovery.opens ?? []).contains { $0.state == .ok }
    }

    /// Whether a stored device state has an open that is unanswered (and none `ok`). Reads no keys.
    public static func hasUnansweredOpen(state bytes: [UInt8]) -> Bool {
        guard let opens = (try? JSONDecoder().decode(DeviceState.self, from: Data(bytes)))?.recovery?.opens else { return false }
        return opens.contains { $0.state == .unanswered } && !opens.contains { $0.state == .ok }
    }

    /// Whether a stored device state (its decrypted bytes) is of a device that paired and has no recovery left: the pairing of a
    /// recovery completed there (IOS-PLAN 0.1.38 §4.9). Reads no keys.
    public static func pairedAfterRecovery(state bytes: [UInt8]) -> Bool {
        guard let st = try? JSONDecoder().decode(DeviceState.self, from: Data(bytes)) else { return false }
        return st.deviceID != nil && st.recovery == nil
    }

    /// What is known of each open this identity built, oldest first (IOS-PLAN 0.1.38 §4.10).
    public var recoveryOpens: [RecoveryOpenEntry] { mem.withLock { st.recovery?.opens ?? [] } }

    /// The `request_id`s of the opens this identity built, newest first (IOS-PLAN 0.1.38 §4.9).
    public var recoveryOpenRequestIDs: [String] { recoveryOpens.reversed().map(\.id) }

    /// The `request_id`s of the opens that are unanswered, newest first.
    public var unansweredOpenRequestIDs: [String] { recoveryOpens.reversed().filter { $0.state == .unanswered }.map(\.id) }

    /// Whether an open of this identity is unanswered (sticky: an open stays so until its own answer proves otherwise, and a
    /// later refusal never changes an earlier open's entry), unless one was answered `ok`.
    public var recoveryOpenEverUnanswered: Bool {
        let opens = recoveryOpens
        return opens.contains { $0.state == .unanswered } && !opens.contains { $0.state == .ok }
    }

    /// Writes what became known of the open [id], durably. Never "the newest": an id this device did not build changes nothing. A
    /// save that fails leaves nothing changed in memory either.
    public func markRecoveryOpen(_ id: String, _ state: RecoveryOpenEntry.State) async throws {
        try await lock.withLock {
            let before: RecoveryRecord? = mem.withLock { st.recovery }
            let changed: Bool = mem.withLock {
                guard var record = st.recovery, var opens = record.opens,
                      let i = opens.firstIndex(where: { $0.id == id }) else { return false }
                var entry = opens[i]
                entry.state = state
                guard entry != opens[i] else { return false }
                opens[i] = entry
                record.opens = opens
                st.recovery = record
                return true
            }
            guard changed else { return }
            do {
                try save()
            } catch {
                mem.withLock { st.recovery = before }
                throw error
            }
        }
    }

    /// An open that went out in a build before the history existed (the account record said so) is one unanswered entry, written
    /// once: a later refusal never clears it (IOS-PLAN 0.1.38 §4.10).
    public func addLegacyUnansweredOpen() async throws {
        try await lock.withLock {
            let added: Bool = mem.withLock {
                guard var record = st.recovery, (record.opens ?? []).isEmpty else { return false }
                record.opens = [RecoveryOpenEntry(id: "legacy", state: .unanswered)]
                st.recovery = record
                return true
            }
            if added { try save() }
        }
    }

    /// A new identity starts from the floors the earlier one has seen (`min_state_seq`, `min_header_seq`, the release and the
    /// manifest serial), never below them (IOS-PLAN 0.1.38 §4.9; chosen; not in the spec).
    public func seedFloors(from other: AltState) async throws {
        try await lock.withLock {
            mem.withLock {
                var a = alt()
                a.stateSeq = max(a.stateSeq, other.stateSeq)
                a.manifestSerial = max(a.manifestSerial, other.manifestSerial)
                for (k, v) in other.headerSeq { a.headerSeq[k] = max(a.headerSeq[k] ?? 0, v) }
                if other.releaseNumber > a.releaseNumber {
                    a.release = other.release
                    a.releaseNumber = other.releaseNumber
                }
                setAlt(a)
            }
            try save()
        }
    }

    /// Opens `vault.recovery.open.result`; on `ok` pins the vault from the bundle and keeps the token, so that the phone's
    /// first handshake follows (`hs.init` with `ctx` = `recovery_id`, then `credential.get`).
    public func openRecoveryOpenResult(_ raw: [UInt8], requestID: String) async throws -> RecoveryOpen.Result {
        try await lock.withLock {
            let body = try AltResults.open(raw, kem: secrets.kem, type: RecoveryOpen.typeResult, requestID: requestID)
            let r = try RecoveryOpen.Result.parse(body)
            guard r.ok else { return r }
            try mem.withLock {
                if let bundle = r.vaultBundle { try adoptBundle(bundle) }
                // The open's own invitation: one an earlier unlock named goes (IOS-PLAN 0.1.40 §4.9).
                st.recovery?.invitation = nil
                st.recovery?.invitationSent = nil
                if st.vault != nil {
                    let exp = heldFromVault(r.token).map(Self.ms) ?? 0
                    st.vault?.token = r.token
                    st.vault?.tokenExpMs = exp
                }
                // As after an unlock: the state floor, and the release with its header_seq for the next unlock's rollback
                // check (min_header_seq).
                setAlt(AltRequests.applyRecoveryOpen(
                    alt(), stateSeq: r.stateSeq, headerSeq: r.headerSeq, release: r.release, releaseNumber: r.releaseNumber
                ))
            }
            try save()
            return r
        }
    }

    /// After an `ok` open: `hs.init` with purpose `app` and `ctx` = `recovery_id` (accepted without approval, as the first
    /// app's), deposited with the token from the result. The recovery stays registered until the credential is here too
    /// (``finishRecoveryOpen()``).
    ///
    /// (IOS-PLAN 0.1.39 §4.9) After an `ok` to an unlock (a lost ok), one `hs.init` with each `recovery_id` this identity registered
    /// for, newest first (``pairingContexts``), each waiting [timeout] (the pairing timeout for each one; chosen; not in the spec):
    /// the vault answers a `ctx` that is not its invitation's with nothing. The last one's failure is thrown.
    ///
    /// (IOS-PLAN 0.1.40 §4.9) [skipping]: the `recovery_id`s already tried with the invitation the vault named, left out of the
    /// walk; when none is left this throws a timed-out ``VaultStateError`` without sending anything.
    public func completeRecoveryOpen(timeout: TimeInterval = awaitDefault, skipping: Set<String> = []) async throws {
        let contexts = mem.withLock { pairingContexts }.filter { !skipping.contains($0) }
        if contexts.isEmpty, !skipping.isEmpty {
            var e = VaultStateError(message: "no hs.resp within the walk: every recovery_id was tried")
            e.timedOut = true
            throw e
        }
        for (i, ctx) in contexts.enumerated() {
            do {
                try await pairRecovered(ctx: ctx, timeout: timeout)
                return
            } catch let e as VaultStateError where i < contexts.count - 1 && e.timedOut {
                continue
            }
        }
        throw VaultStateError(message: "no recovery registered")
    }

    /// One `hs.init` of the recovered phone with [ctx], saved with it, and the wait for `device.paired`.
    private func pairRecovered(ctx: String, timeout: TimeInterval) async throws {
        try await lock.withLock {
            let v: VaultRecord = try mem.withLock {
                let v = try requireVault()
                guard st.recovery != nil else { throw VaultStateError(message: "no recovery registered") }
                guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
                return v
            }
            try await startInit(purpose: .app, ctx: ctx, depositToken: v.token)
            mem.withLock {
                st.recovery?.pairing = ctx
                if st.recovery?.invitation == ctx { st.recovery?.invitationSent = true }
            }
            try save()
        }
        _ = try await awaitPaired(timeout: timeout)
    }

    /// (IOS-PLAN 0.1.39 §4.9) The `ctx` of each `hs.init` after the `ok`: this registration's `recovery_id`; after an `ok` to an
    /// unlock (a lost ok), then each earlier one this identity registered for, newest first. Callers hold ``mem``.
    var pairingContexts: [String] {
        guard let rec = st.recovery else { return [] }
        guard rec.lostOk == true else { return [rec.recoveryID] }
        var all = [rec.recoveryID]
        for id in rec.registeredBefore.reversed() where !all.contains(id) { all.append(id) }
        return all
    }

    /// (IOS-PLAN 0.1.40 §4.9) The invitation the last unlock's `ok` named (`invitation_recovery_id`), and whether its `hs.init`
    /// was sent since; nil when that result named none, or when this identity is not recovering.
    public var namedInvitation: NamedInvitation? {
        mem.withLock {
            guard let rec = st.recovery, let id = rec.invitation else { return nil }
            return NamedInvitation(recoveryID: id, sent: rec.invitationSent == true)
        }
    }

    /// (IOS-PLAN 0.1.40 §4.9, VAULT-MESSAGING 0.67.0 §11.14.6 "Pairing") The single `hs.init` with [recoveryID], the
    /// invitation the vault named, as `ctx` (saved as sent with it), and the wait for `device.paired`. The caller has checked
    /// that this identity registered [recoveryID]; the binding is that registration's attested key, verified as for any `ctx`.
    public func pairNamedInvitation(_ recoveryID: String, timeout: TimeInterval) async throws {
        guard registeredRecoveryIDs.contains(recoveryID) else { throw VaultStateError(message: "not a recovery of this identity") }
        try await pairRecovered(ctx: recoveryID, timeout: timeout)
    }

    /// ``registeredRecoveryIDs`` of a stored device state (its decrypted bytes); a state that cannot be read is thrown. Reads no
    /// keys.
    public static func registeredRecoveryIDs(state bytes: [UInt8]) throws -> [String] {
        guard let rec = try JSONDecoder().decode(DeviceState.self, from: Data(bytes)).recovery else { return [] }
        return [rec.recoveryID] + rec.registeredBefore.reversed().filter { $0 != rec.recoveryID }
    }

    /// (IOS-PLAN 0.1.39 §4.9) The `ctx` of the recovered phone's first handshake the vault answered, nil before (or from a build
    /// before it was kept).
    public var recoveryPairedCtx: String? { mem.withLock { st.recoveryPairedCtx } }

    /// ``recoveryPairedCtx`` of a stored device state (its decrypted bytes); a state that cannot be read is thrown. Reads no keys.
    public static func recoveryPairedCtx(state bytes: [UInt8]) throws -> String? {
        try JSONDecoder().decode(DeviceState.self, from: Data(bytes)).recoveryPairedCtx
    }

    /// (IOS-PLAN 0.1.39 §4.9) The `recovery_id`s this identity registered for, newest first (this registration's first).
    public var registeredRecoveryIDs: [String] {
        mem.withLock {
            guard let rec = st.recovery else { return [] }
            return [rec.recoveryID] + rec.registeredBefore.reversed().filter { $0 != rec.recoveryID }
        }
    }

    /// (Release R) The recovered phone holds the credential: the recovery is over (``recoveryOpenedNotFinished`` false).
    public func finishRecoveryOpen() async throws {
        try await lock.withLock {
            try mem.withLock {
                guard st.deviceID != nil else { throw VaultStateError(message: "not paired") }
                st.recovery = nil
            }
            try save()
        }
    }
}

/// (IOS-PLAN 0.1.40 §4.9) The invitation an unlock's `ok` named (`invitation_recovery_id`), and whether its `hs.init` went.
public struct NamedInvitation: Sendable, Equatable {
    public let recoveryID: String
    public let sent: Bool

    public init(recoveryID: String, sent: Bool) {
        self.recoveryID = recoveryID
        self.sent = sent
    }
}
