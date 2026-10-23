import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDVault

/// The pending epoch-1 record and the bundle's traits, as the alternate channel's callback (off the main actor) leaves
/// them.
private final class TransferPath: @unchecked Sendable {
    private let lock = NSLock()
    private var epochID: String?
    private var caps: [String] = []
    private var scale: UInt64 = TimeScale.real

    func set(_ id: String, _ capabilities: [String], _ timeScale: UInt64) {
        lock.withLock { (epochID, caps, scale) = (id, capabilities, timeScale) }
    }

    struct Seen {
        let id: String?
        let capabilities: [String]
        let timeScale: UInt64
    }

    var value: Seen { lock.withLock { Seen(id: epochID, capabilities: caps, timeScale: scale) } }
}

// A direct transfer (VAULT-MESSAGING §6.7.1, §11.14.10), on both phones: the new phone scans the old phone's code, shows
// the SAS and takes the credential over; the old phone shows the code, compares the SAS and approves with the PIN and the
// password. Mirrors vettid-android `VaultManager`'s direct transfer (`transferIn`, `awaitTransferIn`, `abandonTransferIn`,
// `transferCreate`, `awaitTransferPending`, `transferApprove`, `transferReject`). The old phone's keys after the approval:
// ``VaultManager+Keep``. Recovery (§11.11) comes with I3.4: its requirements of ``MoveRepository`` answer
// ``FailureKind/notSupported`` until then.
extension VaultManager: MoveRepository {
    /// The code of a scanned or pasted text that is not a transfer code (vettid-android `CODE_NOT_TRANSFER`).
    public nonisolated static let codeNotTransfer = "not_transfer"
    /// How long the new phone waits for the old phone's approval after its `hs.init` (§6.7, 0.10.4).
    nonisolated static let pairingWindow: TimeInterval = 600

    // MARK: - Recovery (I3.4)

    public func recoveryStage() async throws -> RecoveryStage { throw Self.recoveryNotYet }
    public func registerRecovery(_ code: RecoveryCode) async throws -> RecoveryRegistration { throw Self.recoveryNotYet }
    public func registerTypedRecovery(_ typed: TypedRecoveryCode) async throws -> RecoveryRegistration { throw Self.recoveryNotYet }
    public func recoveryPreflight() async throws -> PreflightInfo { throw Self.recoveryNotYet }
    public func recoveryUnlock(pin: String, approve: ReleaseView?) async throws -> UnlockAttempt { throw Self.recoveryNotYet }
    public func recoveryCredentialBackup() async throws -> Bool? { throw Self.recoveryNotYet }
    public func recoverCredential(password: String) async throws -> RecoverOutcome { throw Self.recoveryNotYet }

    private static var recoveryNotYet: VaultFailure { VaultFailure(.notSupported, code: "recovery_not_available") }

    // MARK: - The new phone (§6.7.1)

    /// Starts the transfer from the old phone's code ([code]: the scanned QR or a pasted link): the code is checked here
    /// first, the claim fetched, the attested `hs.init` sent (with this phone's app key and, on release R, a new phone key's
    /// secret of epoch 1, IOS-PLAN §6.3 item 7), and the SAS returned once the handshake checked out. Without the vault's
    /// `hs.resp` within ``MoveCodes/hsRespWait`` the transfer is dropped and fails with ``FailureKind/noResponse`` and
    /// ``MoveCodes/hsUnanswered`` (§6.7.1 step 2). **Honours task cancellation**, also while waiting for the SAS.
    public func transferIn(code: String) async throws -> String {
        try await guarded {
            let link = try Self.transferLink(code, now: config.now())
            try prepared()
            let s = try await openSession()
            let d = s.device
            // One vault per phone: no transfer onto a phone that holds one, or may hold a provisional one.
            if d.deviceID != nil || d.vaultID != nil || d.recovering { throw VaultFailure(.vaultExists) }
            if let refusal = startOverRefusal(nil) { throw refusal }
            let rec = record.generation
            if !record.value.transferIn { try record.update(since: rec) { $0.transferIn = true } }
            let path = TransferPath()
            let secrets = phoneSecrets
            let policy = config.trust.timeScales
            // Release R (§11.14.10): this phone's key and its secret of epoch 1 go in the hs.init. The vault id is not
            // known yet: they are made for "" (IOS-PLAN §6.1). Stored before the hs.init is sent; a retry reuses them.
            try await d.startTransfer(link: link, attester: config.attester) { capabilities, scale in
                try ReleasePath.requireR(capabilities)
                try policy.check(scale)
                let epoch = try secrets.reuseOrCreate(keyVault: "")
                path.set(epoch.id, capabilities, scale)
                return epoch.secret
            }
            let (epochID, capabilities, scale) = (path.value.id, path.value.capabilities, path.value.timeScale)
            transferEpochID = epochID
            usesPhoneSecret = phoneSecrets.inUse
            try record.update(since: rec) { $0.capabilities = capabilities }
            learnTimeScale(scale, since: rec)
            recoveryOffered = ReleasePath.recoveryOffered(capabilities)
            transferStartedAt = config.now()
            // §6.7.1 step 2 (0.10.6): a dropped hs.init is never answered; stop after 60 s and say why it may be.
            guard let sas = try await sasWithinLimit(d) else {
                await dropTransfer(d)
                throw VaultFailure(.noResponse, code: MoveCodes.hsUnanswered)
            }
            return sas
        }
    }

    /// The transfer code's link, or the failure of a text that is not one (nothing is fetched for it).
    private static func transferLink(_ code: String, now: Date) throws -> String {
        switch InviteLinks.parseTransfer(code, now: now) {
        case .ok(let link, _): link
        case .expired: throw VaultFailure(.inviteExpired, code: codeNotTransfer)
        case .notATransfer, .invalid: throw VaultFailure(.inviteInvalid, code: codeNotTransfer)
        }
    }

    /// The SAS, or nil when none came within ``MoveCodes/hsRespWait``. A cancelled task stops the wait with
    /// ``CancellationError``.
    private func sasWithinLimit(_ d: VaultDevice) async throws -> String? {
        let sleep = config.transferSleep
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { () async throws -> String? in try await d.awaitPairingSas() }
            group.addTask { try await sleep(MoveCodes.hsRespWait); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// Waits for the old phone's approval, then takes the credential over (`credential.get`, `credential.ack`,
    /// `credential.utk.get`, §6.7.1 step 5). ``FailureKind/rejected`` when the owner rejected it, ``FailureKind/noResponse``
    /// after 10 minutes; then the transfer is dropped. True when the vault gave this phone the member's `user_guid`
    /// (§6.7.1, 0.17.0), which its unlocks need.
    public func awaitTransferIn() async throws -> Bool {
        try await guarded {
            let rec = record.generation
            let s = try await openSession()
            let d = s.device
            let started = transferStartedAt ?? config.now()
            let left = max(started.addingTimeInterval(Self.pairingWindow).timeIntervalSince(config.now()), 1)
            let guid: String?
            do {
                guid = try await d.awaitTransfer(timeout: left)
            } catch {
                // Rejected or timed out: nothing was approved, so nothing changes; the handshake state is dropped.
                if !(error is CancellationError) { await dropTransfer(d) }
                throw error
            }
            transferStartedAt = nil
            // This phone's attested App Attest key is the one the vault bound now (IOS-PLAN §6.2).
            if let k = d.altState.enrolledAttestKeyID { try? config.attester.confirm(keyID: k) }
            // §6.7.1 (0.17.0): the member's user_guid from device.paired, kept as an enrolled phone keeps the redeem's, so
            // that this phone unlocks later (§11.4). A vault release before 0.17.0 sends none: the transfer is still
            // complete, and the unlock screen says why this phone cannot unlock.
            // Release R (§11.14.10): "Finish the move" is asked until an unlock from storage with this phone's secret.
            try record.update(since: rec) {
                if let guid { $0.userGuid = guid }
                if let vid = d.vaultID { $0.vaultID = vid }
                $0.finishMovePending = true
                $0.movedIn = true
                // The vault was confirmed long ago (§3.5.7): this phone does not wait for `vault.enroll.confirm`.
                $0.enrollConfirmed = true
            }
            memberVault.set(recorded: record.value.vaultID)
            usesPhoneSecret = phoneSecrets.inUse
            // §6.7.1 step 5: the blob the vault kept, confirmed, and a UTK pool.
            try await openApi(s).credentialTakeOver()
            phase = .setup(.finishing)
            return guid != nil
        }
    }

    /// Drops a transfer this phone started and has not completed: the handshake, the pinned vault, the attested key and
    /// the pending epoch-1 record (the vault holds neither before the approval, §6.7.1: "Aborted. Nothing else changes").
    public func abandonTransferIn() async throws {
        try await guarded {
            transferStartedAt = nil
            guard let d = session?.device else { return }
            await dropTransfer(d)
        }
    }

    /// The device's transfer dropped, with the App Attest key it attested discarded and its epoch-1 record deleted.
    private func dropTransfer(_ d: VaultDevice) async {
        let key = d.altState.transferAttestKeyID
        try? await d.abandonTransfer()
        transferStartedAt = nil
        if let key { try? config.attester.discard(keyID: key) }
        if let id = transferEpochID {
            try? phoneSecrets.dropPending(id: id)
            transferEpochID = nil
            usesPhoneSecret = phoneSecrets.inUse
        }
    }

    // MARK: - The old phone (§6.7.1)

    /// `device.transfer.create`: the code the new phone scans. One transfer at a time (`exists`): a code this phone showed
    /// before and left behind is cancelled first.
    public func transferCreate() async throws -> TransferOfferView {
        try await guarded {
            let api = try openApi(try await openSession())
            let offer: TransferOffer
            do {
                offer = try await api.transferCreate()
            } catch let e as VaultOpError where e.code == Self.codeExists {
                guard let prev = openTransferID else { throw e }
                try? await api.transferReject(prev)
                offer = try await api.transferCreate()
            }
            openTransferID = offer.transferID
            let exp = try offer.exp.flatMap { OwnerCheckManager.instant($0) } ?? InviteLinks.expiry(offer.link)
            return TransferOfferView(
                transferID: offer.transferID, qrPayload: try InviteLinks.qrPayload(offer.link), link: offer.link, expiresAt: exp
            )
        }
    }

    /// Waits until [until] for the new phone's `device.transfer.pending`; nil when the code expired first. This app has no
    /// signer of its own to name on an iPhone (App Attest reports none), so ``TransferPendingView/currentSigner`` is nil.
    public func awaitTransferPending(transferID: String, until: Date) async throws -> TransferPendingView? {
        try await guarded {
            let left = until.timeIntervalSince(config.now())
            guard left > 0 else { return nil }
            let api = try openApi(try await openSession())
            do {
                let p = try await api.awaitTransferPending(transferID, timeout: left)
                return TransferPendingView(
                    transferID: p.transferID, name: p.name, sas: p.sas, signer: p.signer, signerChanged: p.signerChanged
                )
            } catch let e as VaultStateError where VaultFailures.noResponse(e) {
                return nil
            }
        }
    }

    /// §6.7.1 step 3: the approval. Its `{}` is not yet proof that the transfer completed; the proof is the
    /// `device.unlinked{transferred}` that follows (step 4), which wipes this phone. On release R that notice comes only
    /// after the new phone's first unlock from storage (§11.14.10), so this phone keeps its keys until then or for 7 days
    /// (``KeptTransfer``): the time is stored before the approval is sent, so that an approval whose answer is lost is
    /// bounded too, and removed again when the approval is refused or does not keep the keys.
    public func transferApprove(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool {
        let rec = record.generation
        let before = (record.value.transferApprovedAtMs, record.value.transferKeepMs)
        // STAGING-TIME-SCALE (S10): the keep period is divided by the vault's time scale now, and kept with the time.
        let keepMs = KeptTransfer.keepMs(timeScale: timeScale)
        let stored = keepMs == KeptTransfer.keepPeriodMs ? nil : keepMs
        try? record.update(since: rec) {
            $0.transferApprovedAtMs = nowMs
            $0.transferKeepMs = stored
        }
        let restore: (inout LocalAccount) -> Void = { ($0.transferApprovedAtMs, $0.transferKeepMs) = before }
        var keep = false
        let moved: Bool
        do {
            guard let holder else { throw VaultFailure(.other, code: "no_holder_watch") }
            moved = try await guarded {
                try await holder.approveTransfer(wait: .zero) {
                    let api = try openApi(try await openSession())
                    keep = try await api.transferApprove(transferID: transferID, pin: pin, password: password, signer: signer)
                        .keepUntilNewUnlock
                    openTransferID = nil
                }
            }
        } catch let e as VaultFailure {
            if !KeptTransfer.mayHaveReached(e.kind) { _ = try? record.update(since: rec, restore) }
            throw e
        }
        if keep {
            await checkKeptTransfer()
        } else {
            _ = try? record.update(since: rec, restore)
        }
        return moved
    }

    public func transferReject(transferID: String) async throws {
        try await guarded {
            try await openApi(try await openSession()).transferReject(transferID)
            if openTransferID == transferID { openTransferID = nil }
        }
    }
}
