import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDVault

/// The id of the epoch-1 record a registration made, as the alternate channel's callback (off the main actor) leaves it.
private final class RegisterEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    private var madeHere: Bool?

    /// [created]: this call made the record; only then is it dropped when the register is refused.
    func set(_ value: String, created: Bool) {
        lock.withLock {
            id = created ? value : nil
            madeHere = created
        }
    }

    var value: String? { lock.withLock { id } }
    /// Whether no earlier register was built (nil: none was built by this call at all).
    var created: Bool? { lock.withLock { madeHere } }
}

/// A secret kept in one buffer, so that wiping it wipes what was sent.
final class SecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var value: [UInt8] { lock.withLock { bytes } }
    func wipe() { lock.withLock { Bytes.wipe(&bytes) } }
}

// Recovery on the new phone (VAULT-MESSAGING §11.11, §11.14.6): the portal's code is claimed with this phone's app key and
// registered over the alternate channel, then the PIN and the password together open the recovery (`vault.recovery.open`),
// the vault makes this phone its app and the first handshake and `credential.get` follow. Mirrors vettid-android
// `VaultManager`'s `MoveRepository` recovery section. The recovery of before release R (§11.11.5 steps 1 to 3: a recovering
// app's unlock and `credential.recover`) is not implemented on iOS (IOS-PLAN ID8); its requirements answer
// ``FailureKind/notSupported`` with ``codeRecoveryBeforeR``.
extension VaultManager {
    /// The register or the open of a release that implements release R without `recovery_offered` (§11.10.9, §11.14.13):
    /// nothing is sent. Also the code of `RecoveryRegistration.refused`.
    public nonisolated static let codeNotOffered = "not_offered"
    /// ``RecoveryRegistration/refused(code:recoveryID:)``: the API's `409 recovery_not_available`.
    nonisolated static let codeNotAvailable = "not_available"
    /// The vault keeps no backup copy of its credential: it cannot be recovered (VAULT-MESSAGING 0.16.0).
    nonisolated static let codeNoBackup = "no_backup"
    /// The claim's `404`, and a recovery open on a phone with no recovery registered.
    nonisolated static let codeNoRecovery = "no_recovery"
    /// (0.34.0) The resume of a lost `ok`: the unlock opened the vault but carried no `vault_bundle` for this phone.
    public nonisolated static let codeNoBundle = "no_bundle"
    /// A registration or a start-over while an open went out (answered or not): the vault may hold this phone's secret.
    public nonisolated static let codeRecoveryOpenSent = "recovery_open_sent"
    /// A start over or a registration while the member API says the recovery is still registered and this phone is not its app:
    /// the open can be tried again.
    public nonisolated static let codeRecoveryOpenPending = "recovery_open_pending"
    /// A start over or a registration while the member API could not say whether the vault adopted this phone: try again.
    public nonisolated static let codeRecoveryOpenUnknown = "recovery_open_unknown"
    /// A registration for another recovery while this phone is registered for one (a register of it may have been taken).
    public nonisolated static let codeRecoveryRegistered = "recovery_registered"
    /// (IOS-PLAN 0.1.38 §4.9) A recovery code of another vault than the one of a phone that could not tell: nothing registered.
    public nonisolated static let codeOtherVault = "other_vault"
    /// The requirements of the recovery of before release R (IOS-PLAN ID8).
    public nonisolated static let codeRecoveryBeforeR = "recovery_before_release_r"
    /// The recovered phone's handshake right after `ok` (§11.14.6), and, for a recovery whose `ok` came earlier, the wait
    /// before an unlock with this phone's own key.
    nonisolated static let openedHandshakeWait: TimeInterval = 90
    nonisolated static let resumeHandshakeWait: TimeInterval = 30

    // MARK: - Where it stands

    /// Where a recovery on this phone stands. Release R's open has one screen for the PIN and the password, so a registered
    /// phone is always at the PIN (``RecoveryStage/password`` is the stage of the recovery before release R). Reads the stored
    /// device, and makes none (chosen; not in the spec: vettid-android opens the session at this point).
    public func recoveryStage() async throws -> RecoveryStage {
        try await guarded {
            try prepared()
            let registered = try await storedSession()?.device.recovering ?? false
            return registered ? .pin : .code
        }
    }

    // MARK: - Claim and register (§11.11.3, §11.11.7, §11.11.10)

    public func registerRecovery(_ code: RecoveryCode) async throws -> RecoveryRegistration {
        try await guarded {
            let s = try await recoveryStart()
            // IOS-PLAN 0.1.38 §4.9: a phone that could not tell registers the new recovery with N and the same K, and keeps the
            // earlier registration; a scanned code names its vault, so that another vault's code is refused before the claim.
            let rule = registersAsNewRecovery
            if rule {
                if isOtherVault(code.vaultID) { return .refused(code: Self.codeOtherVault) }
            } else {
                // Known beforehand for a scanned code: refused before the claim, which would use one of the API's claim keys.
                try refuseOtherRecovery(s.device, code.recoveryID)
            }
            let claim: @Sendable () async throws -> Claimed = { [self] in
                // §11.11.7: the claim gives this phone's key the right to register, and names the member.
                try await member.recoveryClaim(
                    vaultID: code.vaultID, recoveryID: code.recoveryID, appKey: try config.keys.appKeys.getOrCreate().spki()
                )
            }
            let claimed: Claimed
            do {
                claimed = try await claim()
            } catch let e as MemberApiError {
                if rule, e.code == MemberApiError.keyInUse { return try await claimKeyInUse() }
                return try Self.claimRefusal(e)
            }
            if rule { return try await registerAsNewIdentity(code, claimed, claimAgain: claim) }
            return try await registerClaimed(s, code, claimed)
        }
    }

    /// §11.11.10: the claim by locator names the vault and the recovery; with them and the typed code the app holds what a
    /// scan gives, and the register is the scanned one.
    public func registerTypedRecovery(_ typed: TypedRecoveryCode) async throws -> RecoveryRegistration {
        try await guarded {
            let s = try await recoveryStart()
            let rule = registersAsNewRecovery
            // (A typed code is claimed with K before its vault is known; one of another vault is refused as soon as the claim names
            // it, IOS-PLAN 0.1.38 §4.9.)
            let claim: @Sendable () async throws -> Claimed = { [self] in
                try await member.recoveryClaim(locator: typed.locator, appKey: try config.keys.appKeys.getOrCreate().spki())
            }
            let claimed: Claimed
            do {
                claimed = try await claim()
            } catch let e as MemberApiError {
                if rule, e.code == MemberApiError.keyInUse { return try await claimKeyInUse() }
                return try Self.claimRefusal(e)
            }
            let code = try typed.recoveryCode(claimed: claimed, api: apiOrigin)
            let r: RecoveryRegistration
            if rule {
                // The vault is known only from the claim: another vault's code is refused, nothing registered.
                r = isOtherVault(code.vaultID)
                    ? .refused(code: Self.codeOtherVault) : try await registerAsNewIdentity(code, claimed, claimAgain: claim)
            } else {
                r = try await registerClaimed(s, code, claimed)
            }
            // A refusal after the claim names the recovery, so that wrong codes are counted per recovery however they were read.
            if case .refused(let refusal, _) = r { return .refused(code: refusal, recoveryID: code.recoveryID) }
            return r
        }
    }

    /// The claim's refusals that have their own text (`409`, `404`); any other error is thrown.
    private static func claimRefusal(_ e: MemberApiError) throws -> RecoveryRegistration {
        switch e.code {
        case MemberApiError.recoveryNotAvailable: .refused(code: codeNotAvailable)
        case MemberApiError.recoveryUnavailable: .refused(code: codeNoBackup)
        case MemberApiError.notFound: .refused(code: codeNoRecovery)
        default: throw e
        }
    }

    /// The session of a registration. One vault per phone: none onto a phone that holds one, or may hold a provisional one
    /// (``startOverRefusal(_:)``); a phone that is registered already may register again (another code).
    private func recoveryStart() async throws -> VaultSession {
        try prepared()
        let s = try await openSession()
        let d = s.device
        if registersAsNewRecovery {
            // IOS-PLAN 0.1.38 §4.9: two reads said the recovery ended; the phone keeps everything and registers the new one.
            if d.hasVault || d.deviceID != nil { throw VaultFailure(.vaultExists) }
            return s
        }
        if d.recovering {
            // Opened by the vault's `ok` and not finished: that recovery is finished, not registered again.
            if d.hasVault || d.deviceID != nil { throw VaultFailure(.vaultExists) }
            // An open went out (answered, or not: the vault may have adopted this phone's secret): its record is read here, before
            // a registration resets it, and the pending key stays for the resume. A start over ends it (chosen; not in the spec).
            if record.value.recoveryAttemptsUsed != nil { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
            try await refuseWhileOpenMarked()
        } else {
            if d.deviceID != nil { throw VaultFailure(.vaultExists) }
            if let refusal = startOverRefusal(d) { throw refusal }
        }
        return s
    }

    /// Refuses a register of a recovery other than the one this phone is registered for (a register of it may have been taken).
    private func refuseOtherRecovery(_ d: VaultDevice, _ recoveryID: String) throws {
        if d.recovering, record.value.recoveryRegistered, let known = d.recoveryID, known != recoveryID {
            throw VaultFailure(.other, code: Self.codeRecoveryRegistered)
        }
    }

    /// After the claim, however the code was read: the sealed `vault.recovery.register` (§11.11.3). The record is the
    /// claim's own, made now; what the registration writes belongs to it.
    private func registerClaimed(_ s: VaultSession, _ code: RecoveryCode, _ claimed: Claimed) async throws -> RecoveryRegistration {
        // A register of another recovery may have been taken (its answer lost) and bound this phone's key: the registration it
        // would overwrite is ended by a start over first (chosen; not in the spec).
        try refuseOtherRecovery(s.device, code.recoveryID)
        // The earlier open's mark in the record is about to go: the history of its device keeps it (a build before the history).
        await convertLegacyUnanswered(s.device)
        try resetRecord(LocalAccount(userGuid: claimed.userGuid, vaultID: code.vaultID, emailHint: claimed.emailHint))
        publishAccount()
        let rec = record.generation
        let secrets = phoneSecrets
        let epoch = RegisterEpoch()
        let attester = config.attester
        let guid = claimed.userGuid
        let result: RecoveryResult?
        do {
            result = try await s.alt.recoveryRegister(
                vaultID: code.vaultID, attester: attester,
                build: { [weak self] e in
                    // IOS-PLAN ID8 (§11.10.9): release R's recovery only; an instance without `recovery_r` is refused, and one
                    // with it and without `recovery_offered` gets nothing sent.
                    let caps = e.descriptor.capabilities
                    try ReleasePath.requireR(caps)
                    guard ReleasePath.recoveryOffered(caps) else { throw VaultFailure(.notSupported, code: Self.codeNotOffered) }
                    // The phone key and its epoch-1 record are made before the register (IOS-PLAN §6.3 item 7: a retry reuses
                    // them); the register carries no secret, the open does.
                    var (made, created) = try secrets.reuseOrCreateNoting(keyVault: code.vaultID)
                    Bytes.wipe(&made.secret)
                    epoch.set(made.id, created: created)
                    await self?.noteRegistering(e, since: rec)
                    return try await s.device.prepareRecoveryRegister(userGuid: guid, code: code, enclave: e, attester: attester)
                },
                open: { raw, rid in try s.device.openRecoveryResult(raw, requestID: rid) }
            )
        } catch let f as VaultFailure where f.code == Self.codeNotOffered {
            return .refused(code: Self.codeNotOffered)
        } catch let e as MemberApiError where e.code == MemberApiError.recoveryUnavailable {
            // 2.1.0: a recovery the enclave refused (no backup copy) is `unavailable`: the register is refused too.
            try await dropRegistration(s, epoch, since: rec)
            return .refused(code: Self.codeNoBackup)
        } catch let e as MemberApiError where e.code == MemberApiError.recoveryNotAvailable {
            _ = e
            result = nil
        }
        guard let r = result else {
            try await dropRegistration(s, epoch, since: rec)
            return .refused(code: Self.codeNotAvailable)
        }
        guard r.ok else {
            try await dropRegistration(s, epoch, since: rec)
            return .refused(code: r.code ?? "retry")
        }
        usesPhoneSecret = phoneSecrets.inUse
        config.attestStartOver?.set(recovering: true)
        phase = .setup(.recovering)
        return .registered(emailHint: claimed.emailHint)
    }

    /// What the instance the register is sealed to says: its capabilities and time scale, recorded with the claimed vault.
    func noteRegistering(_ e: VerifiedEnclave, since rec: Int) {
        let caps = e.descriptor.capabilities
        // Before the register is sent: its answer may be lost, and the vault may bind this phone's key all the same (as
        // `enrollStartedMs` is set before an enrollment's request).
        _ = try? record.update(since: rec) {
            $0.capabilities = caps
            $0.recoveryRegistered = true
        }
        config.attestStartOver?.set(recovering: true)
        learnTimeScale(e.descriptor.timeScale, since: rec)
        recoveryOffered = ReleasePath.recoveryOffered(caps)
        usesPhoneSecret = phoneSecrets.inUse
    }

    /// A registration the enclave refused (§11.11.3), or the API did: forgotten, so that a new code can be tried, with the
    /// epoch-1 record it made (the register carried no secret, so no vault holds it; chosen, not in the spec: vettid-android
    /// keeps the phone key).
    ///
    /// Only when this call made the epoch-1 record, so that no earlier register was built: an earlier one whose answer was lost
    /// may have succeeded and bound the App Attest key, and this one is refused (`used`, `no_recovery`) because it did. Then the
    /// registration, the marks and the record stay (chosen; not in the spec: vettid-android drops the registration).
    private func dropRegistration(_ s: VaultSession, _ epoch: RegisterEpoch, since rec: Int) async throws {
        guard epoch.created == true else { return }
        try await s.device.dropRecoveryRegistration()
        // Refused for certain: no vault holds the key this register attested.
        _ = try? record.update(since: rec) { $0.recoveryRegistered = false }
        config.attestStartOver?.set(recovering: false)
        if let epochID = epoch.value { _ = try? phoneSecrets.dropPending(id: epochID) }
        usesPhoneSecret = phoneSecrets.inUse
    }

    public func recoveryPreflight() async throws -> PreflightInfo { try await preflight() }

    // MARK: - The open (§11.14.6)

    /// `vault.recovery.open` (§11.14.6). Once the vault answered `ok` it has made this phone its app and removed the recovery
    /// record: a phone in that state (``recoveryOpened()``) never sends another open (which could only be answered
    /// `no_recovery`) but finishes the one that succeeded (``finishOpened(_:pin:used:resuming:)``). An open the member API
    /// took that got no answer is remembered across a restart (``LocalAccount/recoveryOpenUnanswered``) and reported with
    /// the next answer.
    public func recoveryOpen(pin: String, password: String) async throws -> RecoveryOpenOutcome {
        try await guarded {
            try prepared()
            let rec = record.generation
            let s = try await openSession()
            let d = s.device
            guard d.recovering else { throw VaultFailure(.notSupported, code: Self.codeNoRecovery) }
            guard phoneSecrets.inUse else { throw VaultFailure(.notSupported, code: Self.codeNoPhoneSecret) }
            if d.recoveryOpenedNotFinished {
                return try await finishOpened(s, pin: pin, used: record.value.recoveryAttemptsUsed, resuming: true, since: rec)
            }
            let afterUnanswered = record.value.recoveryOpenUnanswered
            let vaultID = record.value.vaultID
            // The epoch-1 record the register made (a pending one until this open succeeds): its secret goes in the open.
            var epoch = try phoneSecrets.reuseOrCreate(keyVault: vaultID)
            let secret = SecretBox(epoch.secret)
            epoch.secret = []
            defer { secret.wipe() }
            let r = try await postRecoveryOpen(s, pin: pin, password: password, secret: secret, rec: rec)
            let used = r.counted ? r.used : nil
            // The vault holds this phone's secret once it answered `ok` (§11.14.6 step 6): its epoch-1 record is made current
            // first, before anything that can fail.
            if r.ok {
                _ = try phoneSecrets.confirmCreate(id: epoch.id)
                usesPhoneSecret = phoneSecrets.inUse
            }
            // The mark goes only when the history of the opens leaves none unanswered (IOS-PLAN 0.1.38 §4.10): a `wrong`, a `retry`,
            // `not_armed`, `stored_mismatch` or any code outside the list proves nothing after an unanswered open.
            let none = r.ok || !phoneHasUnansweredOpen(d)
            _ = try record.update(since: rec) {
                if none { $0.recoveryOpenUnanswered = false }
                if let used { $0.recoveryAttemptsUsed = used }
            }
            guard r.ok else {
                return RecoveryOpenOutcome(
                    r.code, used: used, retryAt: r.retryAt, afterUnanswered: afterUnanswered, attemptUsed: r.attemptUsed,
                    contactCouldNotRecover: couldNotRecover(r.code)
                )
            }
            var out = try await finishOpened(s, pin: pin, used: used, resuming: false, since: rec)
            out.attemptUsed = r.attemptUsed
            return out
        }
    }

    func clearOpenMark(since rec: Int) { _ = try? record.update(since: rec) { $0.recoveryOpenUnanswered = false } }

    /// The member API took an open: until its answer is read, the next answer says that this one may have been right.
    func noteRecoveryOpenSent(since rec: Int) {
        guard !record.value.recoveryOpenUnanswered else { return }
        _ = try? record.update(since: rec) { $0.recoveryOpenUnanswered = true }
    }

    /// A lost `ok` (VAULT-MESSAGING 0.34.0 §11.14.6): the open's answer never arrived or could not be read, and the vault may
    /// have completed the recovery and removed its record. An ordinary `vault.unlock` with this phone's secret and the PIN:
    /// its result carries `vault_bundle` and a token only for the phone the completed recovery made the app, before its first
    /// handshake; the bundle pins the vault, and the handshake is sent again (the unlock dropped any that was under way),
    /// then `credential.get`. No attempt is used. Without a bundle the recovery did not complete here.
    public func resumeLostOk(pin: String) async throws -> RecoveryOpenOutcome {
        try await guarded {
            try prepared()
            // IOS-PLAN 0.1.38 §4.9: a phone that could not tell unlocks with each identity that may hold the vault's key.
            if let ct = record.value.couldNotTell { return try await resumeLostOkEither(ct, pin: pin) }
            return try await lostOkOnce(pin: pin)
        }
    }

    /// The unlock of ``resumeLostOk(pin:)`` with the identity in use.
    func lostOkOnce(pin: String) async throws -> RecoveryOpenOutcome {
        try await guarded {
            try prepared()
            let s = try await openSession()
            let d = s.device
            await convertLegacyUnanswered(d) // before a `device_secret` answer clears the record's mark
            guard phoneSecrets.inUse, d.recovering else { throw VaultFailure(.notSupported, code: Self.codeNoRecovery) }
            let used = record.value.recoveryAttemptsUsed
            let rec = record.generation
            if d.recoveryOpenedNotFinished { return try await finishOpened(s, pin: pin, used: used, resuming: true, since: rec) }
            let u: UnlockOutcome
            do {
                u = try await unlockWithSecret(s, pin: pin, options: UnlockOptions(), path: .current)
            } catch {
                // A registered phone the vault did not adopt is not one of its unlock keys: it answers random bytes (§11.4,
                // §11.14.6 "A lost ok"). The member API says whether it did (§11.11.7).
                // The member API refuses the recovering key `403` while the recovery is active; the random bytes of an unreadable
                // answer are the fallback. A `401` decides nothing (it has many causes): the status is asked, and without a clear
                // answer the error stands, the key and the mark kept.
                let refused = error as? MemberApiError
                let unreadable = (VaultFailures.map(error) as? VaultFailure)?.code == "unreadable_result"
                guard refused?.status == 403 || refused?.code == MemberApiError.unauthorized || unreadable else { throw error }
                let verdict: OpenMarkVerdict = refused?.status == 403 ? .stillRegistered : await openMarkVerdict()
                switch verdict {
                case .stillRegistered:
                    return RecoveryOpenOutcome(Self.codeNoBundle, used: used, opened: true, attemptUsed: false)
                case .adopted, .undecided: throw error
                }
            }
            if !u.ok {
                // The vault does not hold this phone's secret: no open of this phone was adopted.
                if u.result.code == UnlockEpoch.deviceSecret { clearOpenMark(since: rec) }
                // IOS-PLAN 0.1.38 §4.9: the open continues while the recovery shows `registered`; otherwise the rule applies.
                if u.result.code == Self.transferIncomplete { try await noteTransferIncomplete() }
                return RecoveryOpenOutcome(u.result.code ?? "retry", used: used, opened: true, attemptUsed: false)
            }
            // A result without `vault_bundle` from an unlock that opened: the vault accepts this phone's key, so an open may
            // have been adopted. The mark stays, and this phone is not abandoned (as `recovery_opened`).
            guard d.recoveryOpenedNotFinished else {
                throw VaultFailure(.other, code: MoveCodes.recoveryOpened)
            }
            var out = try await finishOpened(s, pin: pin, used: used, resuming: false, since: rec)
            out.attemptUsed = false
            return out
        }
    }

    /// After `ok` (§11.14.6): `hs.init` with `ctx` = `recovery_id` (after an unlock's `ok`, each `recovery_id` this identity
    /// registered for, newest first, IOS-PLAN 0.1.39 §4.9), then `credential.get` as the holder (no
    /// `credential.recover`). The app is opened by ``finishRecoveryOpen()``, after the member has read the result. When the
    /// handshake is not answered (the vault locked meanwhile, or the relay lost it), the phone unlocks the vault with its own
    /// key, which the vault made its app's, and runs the handshake again.
    ///
    /// [rec] is the record's generation when the open began: a wipe or a reset during the handshake drops what follows.
    private func finishOpened(
        _ s: VaultSession, pin: String, used: Int?, resuming: Bool, since rec: Int
    ) async throws -> RecoveryOpenOutcome {
        var s = s
        confirmRecoveredSecret()
        // The handshake only when it has not completed yet: a phone paired earlier fetches the credential straight away.
        var refused: String?
        if s.device.deviceID == nil { (refused, s) = try await pairRecovered(s, pin: pin, resuming: resuming) }
        if refused == nil { refused = try await fetchRecovered(s, pin: pin, unlockFirst: resuming) }
        if let refused { return RecoveryOpenOutcome(refused, used: used, opened: true) }
        // Only now, with the credential on this phone, is the recovery over (until then the phone resumes it). The vault was
        // confirmed long ago (§3.5.7): this phone does not wait for `vault.enroll.confirm` (as after a transfer).
        _ = try record.update(since: rec) {
            $0.enrollConfirmed = true
            $0.recoveryOpenUnanswered = false
        }
        try await s.device.finishRecoveryOpen()
        config.attestStartOver?.set(recovering: false)
        // IOS-PLAN 0.1.38 §4.9: the vault answered `ok` and the pairing completed; the identity that did not pair goes now.
        settleCouldNotTell(winner: s.identity)
        return RecoveryOpenOutcome("ok", used: used)
    }

    /// The vault made this phone its app, so the pending epoch-1 record of this vault is the secret it holds: made current when
    /// an earlier run did not get to it (a write that failed, a restart). Nothing when none is pending, or when two are (an
    /// unlock proves the right one).
    func confirmRecoveredSecret() {
        _ = try? phoneSecrets.confirmPending(keyVault: record.value.vaultID)
        usesPhoneSecret = phoneSecrets.inUse
    }

    /// How long the recovered phone waits for the vault's `hs.resp`.
    func handshakeWait(resuming: Bool) -> TimeInterval {
        config.pairingWait ?? (resuming ? Self.resumeHandshakeWait : Self.openedHandshakeWait)
    }

    /// The recovered phone's handshake; unanswered, an unlock with its own key and the handshake again. The unlock's refusal
    /// code, and the session that paired (the earlier identity's, for a phone that could not tell whose invitation it was).
    private func pairRecovered(_ s: VaultSession, pin: String, resuming: Bool) async throws -> (String?, VaultSession) {
        do {
            try await s.device.completeRecoveryOpen(timeout: handshakeWait(resuming: resuming))
            return (nil, s)
        } catch let e as VaultStateError where VaultFailures.noResponse(e) {
            // IOS-PLAN 0.1.38 §4.9: the vault answers a handshake it does not accept with nothing. After the new open's `ok` the
            // invitation may be the earlier identity's, under the earlier `recovery_id`.
            if let earlier = try await pairEarlierIdentity(pin: pin) { return earlier }
            // (A switch of identity stopped this session's device: the identity with the `ok` is opened again.)
            let own = record.value.couldNotTell == nil ? s : try await openSession()
            if let refusal = try await unlockOwn(own, pin: pin, cause: e) { return (refusal, own) }
            // (IOS-PLAN 0.1.39 §4.9) That unlock's `ok` is a lost ok: each `recovery_id` this identity registered for is tried.
            try await own.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false))
            return (nil, own)
        }
    }

    /// `credential.get` as the holder; when resuming ([unlockFirst]) and it is not answered (the vault locked since the
    /// pairing), an unlock with this phone's own key and `credential.get` again. The unlock's refusal code.
    private func fetchRecovered(_ s: VaultSession, pin: String, unlockFirst: Bool) async throws -> String? {
        do {
            try await s.api.credentialFetch()
            return nil
        } catch let e as VaultStateError where unlockFirst {
            if let refusal = try await unlockOwn(s, pin: pin, cause: e) { return refusal }
            try await s.api.credentialFetch()
            return nil
        }
    }

    /// An unlock with this phone's own key (the vault made it its app): nil when it opened, else the vault's code.
    func unlockOwn(_ s: VaultSession, pin: String, cause: any Error) async throws -> String? {
        let u = try await unlockWithSecret(s, pin: pin, options: UnlockOptions(), path: .current)
        if u.ok { return nil }
        guard let code = u.result.code else { throw VaultFailure(.noResponse, code: "recovery_unlock", cause: cause) }
        return code
    }

    public func recoveryOpened() async throws -> Bool {
        try await guarded {
            try prepared()
            if settleTrial(), session != nil { try await dropSession(forget: false) }
            let d = try await openSession().device
            return phoneSecrets.inUse && d.recoveryOpenedNotFinished
        }
    }

    public var recoveryAttemptsUsed: Int? { record.value.recoveryAttemptsUsed }

    /// (Release R) After the member has read the `ok` text: the vault opens on this phone. That text is the recovered phone's
    /// last setup screen (a recovered phone is a new install, `setupComplete` false, so ``afterUnlocked(_:)`` says
    /// ``SetupStage/finishing``): setup is finished here as from the onboarding's last screen (``finishSetup()``, under its
    /// gate: never over a pending lock). The rules are ``RecoveryOpenFinish``'s: as at the end of an unlock, a lock or a wipe
    /// since this began, or a lock pending now, is never overwritten (locked while a lock is pending), and an app that did not
    /// open is a failure.
    public func finishRecoveryOpen() async throws {
        // Read before anything: a lock asked for from here on bumps them, and this then publishes no open phase.
        let marks = (locks: lockGeneration, record: record.generation)
        try await RecoveryOpenFinish.run(OpenPorts(manager: self, marks: marks))
    }

    /// ``RecoveryOpenFinish``' view of the manager.
    @MainActor
    private struct OpenPorts: RecoveryOpenFinish.Ports {
        let manager: VaultManager
        let marks: (locks: Int, record: Int)

        func overtaken() -> RecoveryOpenFinish.Overtaken {
            if manager.lockGuard.lockedWhatever(unlocked: true) { return .lockPending }
            if marks.locks != manager.lockGeneration || marks.record != manager.record.generation { return .other }
            return .no
        }

        func afterUnlocked() async throws -> AppPhase {
            try await manager.guarded { manager.afterUnlocked(try await manager.openSession()) }
        }

        func publish(_ phase: AppPhase) { manager.phase = phase }

        func finishSetup() async throws -> Bool { try manager.finishSetupGated() }
    }

    // MARK: - Leaving a registered recovery

    /// Forgets this phone's recovery registration: the device keys and the app key are made anew, the claimed account is
    /// dropped, and the phone is back at the welcome screen (also at the next start). Nothing is sent: a recovering app cannot
    /// cancel the recovery (§11.11.4). Only ever a recovering device: a phone that holds the vault is not touched.
    public func abandonRecovery() async throws {
        let abandoned: Bool = try await guarded {
            try prepared()
            guard let d = try await storedSession()?.device, d.recovering else { return false }
            // IOS-PLAN 0.1.38 §4.9: never while the phone could not tell (K and every identity stay).
            if record.value.couldNotTell != nil { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
            // Release R (§11.14.6): after `ok` the vault's only unlock key is this phone's; it is never deleted here. Whatever the
            // phone's records say (they may be unreadable now): a pinned or paired vault, or an open that may have succeeded.
            if d.hasVault || d.deviceID != nil || d.recoveryOpenedNotFinished {
                throw VaultFailure(.other, code: MoveCodes.recoveryOpened)
            }
            try await refuseWhileOpenMarked()
            try await dropSession(forget: true, registrationOnly: true)
            try resetRecord(LocalAccount())
            config.attestStartOver?.set(recovering: false)
            return true
        }
        if abandoned { phase = .signedOut }
    }

    // MARK: - The recovery of before release R (IOS-PLAN ID8)

    private static var recoveryBeforeR: VaultFailure { VaultFailure(.notSupported, code: codeRecoveryBeforeR) }

    public func recoveryUnlock(pin: String, approve: ReleaseView?) async throws -> UnlockAttempt { throw Self.recoveryBeforeR }
    public func recoveryCredentialBackup() async throws -> Bool? { throw Self.recoveryBeforeR }
    public func recoverCredential(password: String) async throws -> RecoverOutcome { throw Self.recoveryBeforeR }
}
