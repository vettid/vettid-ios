import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDVault

// A direct transfer (VAULT-MESSAGING §6.7.1, §11.14.10), on both phones: the new phone scans the old phone's code, shows
// the SAS and takes the credential over; the old phone shows the code, compares the SAS and approves with the PIN and the
// password. Mirrors vettid-android `VaultManager`'s direct transfer (`transferIn`, `awaitTransferIn`, `abandonTransferIn`,
// `transferCreate`, `awaitTransferPending`, `transferApprove`, `transferReject`). The old phone's keys after the approval:
// ``VaultManager+Keep``. Recovery (§11.11): ``VaultManager+Recovery``.
extension VaultManager: MoveRepository {
    /// The code of a transfer dropped at its deadline (``awaitTransferIn()``'s ``FailureKind/noResponse``).
    public nonisolated static let codeTransferDeadline = "transfer_deadline"
    /// The code of a scanned or pasted text that is not a transfer code (vettid-android `CODE_NOT_TRANSFER`).
    public nonisolated static let codeNotTransfer = "not_transfer"
    /// How long the new phone waits for the old phone's approval after its `hs.init` (§6.7, 0.10.4).
    nonisolated static let pairingWindow: TimeInterval = 660
    // MARK: - The new phone (§6.7.1)

    /// Starts the transfer from the old phone's code ([code]: the scanned QR or a pasted link): the code is checked here
    /// first, the claim fetched, the attested `hs.init` sent (with this phone's app key and, on release R, a new phone key's
    /// secret of epoch 1, IOS-PLAN §6.3 item 7), and the SAS returned once the handshake checked out. Without the vault's
    /// `hs.resp` within ``MoveCodes/hsRespWait`` the transfer is dropped and fails with ``FailureKind/noResponse`` and
    /// ``MoveCodes/hsUnanswered`` (§6.7.1 step 2). **Honours task cancellation**, also while waiting for the SAS.
    public func transferIn(code: String) async throws -> String {
        // A scan of the open transfer's own code changes nothing (§11.14.10 rule 5, 0.88.4), and is decided first: before
        // the notice below, the window's and the deadline's refusals, the code's expiry, the claim fetch and any drop.
        if let sas = try await sameCodeMove(code) { return sas }
        // A new move: the notice of how the last one ended goes, whatever this one does.
        transferEnd = nil
        // A refresh while this runs resumes nothing: the start may be written before its handshake is saved, and a start
        // that nothing pinned is cleared at a resume (``resumeTransferIn(_:)``).
        moveFlags.book.startingIn += 1
        defer { moveFlags.book.startingIn -= 1 }
        return try await startTransferIn(code)
    }

    private func startTransferIn(_ code: String) async throws -> String {
        try await guarded {
            // One window at a time, and no new code from the end of the vault's 10 minutes (§11.14.10 rule 5): said before the
            // code is looked at.
            try refuseWhileClosed()
            let link = try Self.transferLink(code, now: config.now())
            try prepared()
            let s = try await openSession()
            let d = s.device
            try refuseTransferIn(d)
            moveFlags.book.transferWaiter?.cancel()
            moveFlags.book.transferWaiter = nil
            // A transfer still open and unpaired (refused above when paired), in memory or only stored (an earlier drop whose
            // save failed), is dropped as an abandon drops it, and saved: its handshake, its attested key and its epoch-1 record
            // go before this scan starts (§6.7.1, §11.14.10 rule 5). When the drop cannot be saved, the scan stops before
            // anything changes: the device file may still hold that handshake, which a relaunch reloads and the old phone could
            // still approve with that record's secret, so the record stays (chosen; not in the spec).
            if d.hasVault || record.value.transferEpochID != nil {
                guard await dropTransfer(d) else { throw VaultFailure(.phoneLocked, code: Self.codeTransferNotDropped) }
            }
            let rec = record.generation
            // The one deadline of 11 minutes counts from here, the start of the `hs.init` (owner decision, 2026-10-23), and is
            // stored: a restart keeps it, and nothing the member does extends it.
            let started = nowMs
            // The code's `r` and `c` are stored with the start, before the claim is fetched: from the fetch on, a scan of the
            // same code is this transfer's (§11.14.10 rule 5, 0.88.4).
            let codeID = InviteLinks.transferCodeID(code)
            try record.update(since: rec) {
                $0.transferIn = true
                $0.transferStartedMs = started
                $0.transferCode = codeID
            }
            let path = TransferPath()
            let fresh = FreshTransferSecret(secrets: phoneSecrets, policy: config.trust.timeScales, path: path)
            // Release R (§11.14.10): this phone's key and its secret of epoch 1 go in the hs.init. The vault id is not
            // known yet: they are made for "" (IOS-PLAN §6.1). Stored before the hs.init is sent. A scan never reuses an earlier
            // attempt's secret (§6.7.1, §11.14.10 rule 5): the epoch-1 records still pending for "" (a transfer dropped before
            // pairing and not cleaned up) are dropped first, so that an earlier code's vault never learns the secret this
            // scan's vault is sent. Safe: ``refuseTransferIn(_:)`` guarantees this phone is not paired, so no such record is
            // a paired transfer's secret. If the drop fails nothing is sent.
            do {
                try await d.startTransfer(link: link, attester: config.attester) { [weak self] capabilities, scale in
                    guard let self else { throw CancellationError() }
                    return try await fresh.make(capabilities, scale) { try await self.noteTransferEpoch($0) }
                }
            } catch {
                // The device dropped the key it attested (``VaultDevice/startTransfer``); the epoch-1 record goes too.
                await dropTransfer(d)
                throw error
            }
            let (capabilities, scale) = (path.value.capabilities, path.value.timeScale)
            usesPhoneSecret = phoneSecrets.inUse
            try record.update(since: rec) { $0.capabilities = capabilities }
            learnTimeScale(scale, since: rec)
            recoveryOffered = ReleasePath.recoveryOffered(capabilities)
            // §6.7.1 step 2 (0.10.6): a dropped hs.init is never answered; stop after 60 s and say why it may be.
            let sas: String?
            do {
                sas = try await sasWithinLimit(d)
            } catch let notCompleted as PairingNotCompleted {
                // The relay refused the fin for good: the code is spent, nothing is kept (as for a rejection).
                await dropTransfer(d)
                throw notCompleted
            }
            guard let sas else {
                await dropTransfer(d)
                throw VaultFailure(.noResponse, code: MoveCodes.hsUnanswered)
            }
            return sas
        }
    }

    /// A new code is refused while the last transfer cannot be abandoned (§11.14.10 rule 5); it is then waited for, if
    /// nothing does (the screen went, or nothing pinned it), and its end lets a new code in.
    private func refuseWhileClosed() throws {
        guard abandonClosed else { return }
        waitForTransferInBackground()
        throw VaultFailure(.enrollmentStarted, code: Self.codeTransferWaiting)
    }

    /// Why no transfer can start on [d] now, if it cannot.
    private func refuseTransferIn(_ d: VaultDevice) throws {
        // One vault per phone: no transfer onto a phone that holds one, or may hold a provisional one.
        if d.deviceID != nil || d.vaultID != nil || d.recovering { throw VaultFailure(.vaultExists) }
        if let refusal = startOverRefusal(nil) { throw refusal }
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
    /// `credential.utk.get`, §6.7.1 step 5). ``FailureKind/rejected`` when the owner rejected it; ``FailureKind/noResponse``
    /// at the deadline, **11 minutes after the `hs.init` was started** (§11.14.10 rule 5, owner decision 2026-10-23: one
    /// deadline, stored with the transfer, which no user action extends). At the deadline, and not before, the mailbox is
    /// collected for the settlement window (``collectBeforeDrop(_:)``, VAULT-MESSAGING 0.85.2): a `device.paired{transfer}`
    /// the collects bring is applied and the move completes instead; a rejection is ``FailureKind/rejected``; a session that
    /// ended is ``codeTransferSessionEnded``; otherwise the transfer is dropped. A fin the relay refused for good at its first
    /// deposit (``PairingNotCompleted``) before the deadline drops the transfer too; after it the window runs all the same.
    /// Any other failure before the deadline is rethrown and the transfer kept. True when the vault gave this phone the
    /// member's `user_guid` (§6.7.1, 0.17.0), which its unlocks need.
    public func awaitTransferIn() async throws -> Bool {
        do {
            return try await awaitTransferInOnce()
        } catch {
            // A failure that keeps the transfer (one before the deadline, rethrown): something must still wait for it, the
            // background's wait when this was the screen's (a same-code scan stopped the background's, ``sameCodeMove(_:)``).
            // A cancelled wait is the screen's to settle (Back, or the screen gone); an ended session, a halt, a wipe and a
            // paired phone (or one without a session) start nothing; and the background's own failure starts nothing either
            // (its waiter is still set).
            let ended = (error as? VaultFailure)?.code == Self.codeTransferSessionEnded
            if !(error is CancellationError), !Task.isCancelled, !ended, !halted, !record.closed,
               record.value.transferStartedMs != nil, let d = session?.device, d.deviceID == nil {
                waitForTransferInBackground()
            }
            throw error
        }
    }

    private func awaitTransferInOnce() async throws -> Bool {
        try await guarded {
            let s = try await openSession()
            // One device per transfer: a foreground after a background takes this session back (``takeBackTransferSession()``).
            moveFlags.book.transferSession = s
            moveFlags.book.waitingIn += 1
            defer {
                moveFlags.book.waitingIn -= 1
                if moveFlags.book.waitingIn == 0, moveFlags.book.settling == nil { moveFlags.book.transferSession = nil }
            }
            let settled: TransferSettled
            do {
                // Already paired (a take-over that failed is retried here): its `device.paired` is consumed, so nothing is waited for.
                if s.device.deviceID != nil {
                    settled = await settleTransfer(s, collect: false, guid: nil)
                } else {
                    switch try await awaitPairedOrDeadline(s.device) {
                    case .paired(let guid): settled = await settleTransfer(s, collect: false, guid: guid)
                    case .deadline: settled = await settleTransfer(s, collect: true, guid: nil)
                    }
                }
            } catch let rejected as PairingRejected {
                // Rejected: nothing was approved, so nothing changes; the handshake state is dropped.
                await dropTransfer(s.device)
                throw rejected
            } catch let notCompleted as PairingNotCompleted {
                // The fin was refused for good at its first deposit: the pairing cannot finish; the same.
                await dropTransfer(s.device)
                throw notCompleted
            }
            switch settled {
            case .completed(let guid): return guid != nil
            case .dropped: throw VaultFailure(.noResponse, code: Self.codeTransferDeadline)
            case .failed(let error): throw error
            }
        }
    }

    private enum PairedOrDeadline: Sendable {
        case paired(String?)
        case deadline
    }

    /// Waits for the transfer's `device.paired` (applied by the device as it is handled) or the deadline, whichever comes
    /// first; the deadline's wait is ``VaultManagerConfig/transferDeadlineSleep``. A failure of the wait before the deadline
    /// is thrown (nothing is collected or dropped before it, rule 5); at or after it, it is the deadline, also when the fin
    /// was refused for good, so that a `device.paired` the vault already sent is collected and not lost.
    private func awaitPairedOrDeadline(_ d: VaultDevice) async throws -> PairedOrDeadline {
        let sleep = config.transferDeadlineSleep
        while true {
            let deadline = transferDeadline ?? config.now().addingTimeInterval(Self.pairingWindow)
            let left = max(deadline.timeIntervalSince(config.now()), 0)
            let first: PairedOrDeadline
            do {
                first = try await withThrowingTaskGroup(of: PairedOrDeadline.self) { group in
                    // The device's own wait is longer than the deadline's: it is the deadline that ends the wait.
                    group.addTask { .paired(try await d.awaitTransfer(timeout: left + 60)) }
                    group.addTask {
                        // At the deadline already there is nothing to wait for.
                        if left > 0 { try await sleep(.seconds(left)) } else { try await Task.sleep(for: .milliseconds(50)) }
                        return .deadline
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? .deadline
                }
            } catch {
                if error is CancellationError || error is PairingRejected { throw error }
                // Before the deadline a failure is thrown (a refused fin, ``PairingNotCompleted``, drops the transfer); at or
                // after it the wait is over and the collect of rule 5 runs, whatever the failure was.
                if config.now() < deadline { throw error }
                return .deadline
            }
            if case .paired = first { return first }
            // The clock may be behind the wait: the deadline is the moment by this phone's clock.
            if config.now() >= deadline { return first }
        }
    }

    /// The end of a transfer to this phone is settled by **one task** that every caller joins (the screen's wait, a start's
    /// resume, an abandon): a paired transfer's take-over is done once, and the window of collects at the deadline is run
    /// once. [collect]: the deadline is reached, so a transfer not yet paired gets the window of collects before the drop
    /// (``collectBeforeDrop(_:)``). [guid]: the `user_guid` the caller has.
    func settleTransfer(_ s: VaultSession, collect: Bool, guid: String?) async -> TransferSettled {
        if let running = moveFlags.book.settling { return await running.value }
        let task = Task { @MainActor [self] in
            let result = await runSettle(s, collect: collect, guid: guid)
            moveFlags.book.settling = nil
            // Its session is held no longer than its transfer is waited for.
            if moveFlags.book.waitingIn == 0 { moveFlags.book.transferSession = nil }
            return result
        }
        moveFlags.book.settling = task
        return await task.value
    }

    private func runSettle(_ s: VaultSession, collect: Bool, guid: String?) async -> TransferSettled {
        var s = s
        var guid = guid
        let sessionEnds = moveFlags.book.sessionEnds
        if s.device.deviceID == nil {
            guard collect else {
                await dropTransfer(s.device)
                return .dropped
            }
            let end = await collectBeforeDrop(s.device)
            // A wipe or a sign-out during the window: nothing more is done for this transfer (the wipe or sign-out has it).
            if record.closed || moveFlags.book.sessionEnds != sessionEnds {
                return .failed(VaultFailure(.other, code: Self.codeTransferSessionEnded))
            }
            // A background may have ended the session meanwhile: what follows goes through the current one, or this one taken
            // back (one device per transfer).
            if !halted { s = await settlingSession(s) }
            if session == nil, takeBackTransferSession() != nil, let back = session { s = back }
            if case .paired(let paired) = end {
                guid = paired
            } else if s.device.deviceID == nil {
                return await windowEndedUnpaired(end, s.device)
            }
            // Else paired all the same (its event was taken elsewhere): the move completed, and is reported so.
        }
        // A wipe or a sign-out meanwhile: no take-over (nothing is confirmed, sent or written for a phone being erased).
        if record.closed || moveFlags.book.sessionEnds != sessionEnds {
            return .failed(VaultFailure(.other, code: Self.codeTransferSessionEnded))
        }
        let d = s.device
        guid = guid ?? d.transferUserGuid
        do {
            try await completeTransferIn(s, guid: guid)
            return .completed(guid: guid)
        } catch {
            return .failed(error)
        }
    }

    /// How a window that ended without a pairing settles the transfer on [d].
    private func windowEndedUnpaired(_ end: WindowEnd, _ d: VaultDevice) async -> TransferSettled {
        if case .rejected = end {
            // A rejection in the window ends as a rejection, not as a drop at the deadline.
            await dropTransfer(d)
            return .failed(PairingRejected())
        }
        // The process is ending (``halt()`` cut the window): nothing is decided; the next process runs its own window.
        if halted { return .failed(CancellationError()) }
        if case .ended(let drop) = end {
            // The session ended: reported as ended, never as dropped. On `mailbox_unknown` its handshake is dead and goes;
            // after a wipe or a sign-out nothing is written (they have it).
            if drop { await dropTransfer(d) }
            return .failed(VaultFailure(.other, code: Self.codeTransferSessionEnded))
        }
        await dropTransfer(d)
        return .dropped
    }

    /// The `device.paired{transfer}` has arrived: this phone's key is the one the vault bound, the record keeps the member's
    /// `user_guid` and the move to finish (§11.14.10: "Finish the move" is asked until an unlock from storage with this
    /// phone's secret), and the credential is taken over (§6.7.1 step 5). The transfer's clock is removed only when the
    /// take-over is done, so that a start after the app was killed meanwhile does it again (a paired transfer completes at any
    /// later start, whatever its age).
    private func completeTransferIn(_ s: VaultSession, guid: String?) async throws {
        let d = s.device
        let rec = record.generation
        // This phone's attested App Attest key is the one the vault bound now (IOS-PLAN §6.2).
        if let k = d.altState.enrolledAttestKeyID { try? config.attester.confirm(keyID: k) }
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
        // The answers of the take-over come over the mailbox: it is collected (not in the background, where nothing starts it).
        if !backgrounded { d.start() }
        try await openApi(s).credentialTakeOver()
        // The pending epoch-1 record is this phone's secret now: it stays until the first unlock confirms it.
        _ = try? record.update(since: record.generation) {
            $0.transferStartedMs = nil
            $0.transferEpochID = nil
            $0.transferCode = nil
        }
        try? await d.transferCompleted()
        phase = .setup(.finishing)
    }

    /// The new phone's deadline: 11 minutes after it started the `hs.init` (``LocalAccount/transferStartedMs``); nil without
    /// a transfer waiting.
    var transferDeadline: Date? {
        record.value.transferStartedMs.map { Date(timeIntervalSince1970: Double($0) / 1000 + Self.pairingWindow) }
    }

    /// The code of the refusal of an enrollment (or another vault's code) while a move to this phone is under way, in the
    /// kind ``FailureKind/enrollmentStarted``: "a move to this phone is still under way" (the wording is I3.3b's).
    public nonisolated static let codeTransferWaiting = "transfer_waiting"

    /// Once per process, at the start (before anything else is decided about this phone; §11.14.10 rule 5): a transfer whose
    /// `device.paired` arrived is completed whatever its age; one still waiting is waited for in the background
    /// (``waitForTransferInBackground()``): before its deadline until it, past it for the settlement window (rule 5,
    /// VAULT-MESSAGING 0.85.2), and then applied or dropped. Meanwhile the welcome screen is shown and no enrollment can
    /// start (the vault is pinned, ``startOverRefusal(_:)``); a new code can be scanned before the end of the vault's 10
    /// minutes, not from then on (``abandonClosed``). Waiting before the deadline is (chosen; not in the spec): Android
    /// shows the welcome screen and does not wait.
    @discardableResult
    func resumeTransferIn(_ s: VaultSession) async -> TransferSettled? {
        guard moveFlags.book.startingIn == 0, !moveFlags.book.transferResumed else { return nil }
        moveFlags.book.transferResumed = true
        guard record.value.transferStartedMs != nil else { return nil }
        let d = s.device
        if d.deviceID == nil, !d.hasVault {
            // A start that no transfer pinned (the app killed before the handshake was saved, or a drop whose record could
            // not be saved after the device's): nothing waits; the start goes, so that a new code is not refused for it.
            await clearTransferStart(d)
            return nil
        }
        if d.deviceID == nil, !d.holdsTransferSas, !d.awaitsPairingResp {
            // (0.88.4) A handshake the vault had not answered when the process ended: it was in memory only, so no `hs.fin`
            // can follow and the vault cannot approve it (its comparison code is saved in the write that owes the fin, so
            // none saved means no fin). The transfer is over: dropped, its code and start with it, so that nothing waits
            // for it and no new code or enrollment is refused for it. Never a handshake of this process still waiting for
            // its answer (a scan cancelled during its wait, before this first resume). A drop that cannot be saved leaves
            // it to the background's wait, which drops it at its deadline plus the settlement window; a new code scanned
            // before minute 10 drops it too, and from then on new codes are refused (`abandonClosed`) until that drop.
            // Bounded, and safe: nothing of it can finish.
            if await !dropTransfer(d) { waitForTransferInBackground() }
            return nil
        }
        if d.deviceID != nil {
            return await settleTransfer(s, collect: false, guid: nil)
        } else if d.hasVault, transferDeadline != nil {
            // Before the deadline or past it, in the background: past it, the window of collects before the drop runs there,
            // so that the start does not wait for it (§11.14.10 rule 5).
            moveFlags.book.transferWaiter?.cancel()
            moveFlags.book.transferWaiter = nil
            waitForTransferInBackground()
        }
        return nil
    }

    /// The record after the start's resume. A **paired** transfer whose take-over has not completed (it failed: the network)
    /// is taken over again here, at every evaluation, and its failure is thrown: such a phone is never shown "create a
    /// credential" (the vault has one). [resumed]: what this start's resume settled, if it ran.
    func recordAfterResume(_ s: VaultSession, resumed: TransferSettled?) async throws -> LocalAccount {
        if case .failed(let error)? = resumed { throw error }
        if resumed == nil, s.device.deviceID != nil, record.value.transferStartedMs != nil,
           case .failed(let error) = await settleTransfer(s, collect: false, guid: nil) {
            throw error
        }
        return record.value
    }

    /// Drops a transfer this phone started and has not completed: the handshake, the pinned vault, the attested key and the
    /// pending epoch-1 record (the vault holds neither before the approval, §6.7.1: "Aborted. Nothing else changes"). A
    /// **paired** transfer is not dropped: its pending record is this phone's secret; the take-over is completed instead.
    /// Refused, with ``codeTransferWaiting``, from the end of the vault's 10 minutes on (``abandonClosed``, §11.14.10 rule 5):
    /// the transfer then waits for its window.
    public func abandonTransferIn() async throws {
        try await guarded {
            // Refused with or without a session (a background ends it); the transfer is then waited for in the background.
            if session?.device.deviceID == nil, abandonClosed {
                waitForTransferInBackground()
                throw VaultFailure(.enrollmentStarted, code: Self.codeTransferWaiting)
            }
            moveFlags.book.transferWaiter?.cancel()
            moveFlags.book.transferWaiter = nil
            guard let s = session else { return }
            if s.device.deviceID != nil {
                _ = await settleTransfer(s, collect: false, guid: nil)
            } else {
                await dropTransfer(s.device)
            }
        }
    }

    /// The stored start of a transfer that nothing pinned, with what was made for it: its attested key and epoch-1 record.
    private func clearTransferStart(_ d: VaultDevice) async {
        discardTransferStart(attestKey: d.altState.transferAttestKeyID)
    }

    /// The device's transfer dropped, with the App Attest key it attested discarded and its epoch-1 record deleted: the one
    /// stored with the transfer (``LocalAccount/transferEpochID``), never another. Nothing is touched when the device is
    /// paired, or when its own save failed (it throws): the device file may still hold the pinned vault and the open
    /// handshake, which a relaunch reloads and an approval could still pair, so the record its secret needs stays. Nothing
    /// is reused for that: every scan drops the pending records first (``FreshTransferSecret``).
    /// True when the transfer was dropped and the device's state saved.
    @discardableResult
    private func dropTransfer(_ d: VaultDevice) async -> Bool {
        let key = d.altState.transferAttestKeyID
        guard (try? await d.abandonTransfer()) == true else { return false }
        discardTransferStart(attestKey: key)
        return true
    }

    /// Deletes what a transfer to this phone made, its pending epoch-1 record first: only once it is gone are the stored
    /// start and record id cleared, so that a record that could not be deleted is retried by a later drop (a stored start
    /// that nothing pinned is cleared at a resume, ``resumeTransferIn(_:)``). The attested key is discarded in any case.
    private func discardTransferStart(attestKey: [UInt8]?) {
        if let key = attestKey { try? config.attester.discard(keyID: key) }
        if let id = record.value.transferEpochID {
            do {
                _ = try phoneSecrets.dropPending(id: id)
            } catch let f as VaultFailure where f.kind == .deviceSecret {
                // The records file is lost: no record is left to delete, and keeping the start would refuse every later scan
                // (``abandonClosed``). The next scan's records file replaces it.
            } catch {
                usesPhoneSecret = phoneSecrets.inUse
                return
            }
        }
        _ = try? record.update(since: record.generation) {
            $0.transferStartedMs = nil
            $0.transferEpochID = nil
            $0.transferCode = nil
        }
        usesPhoneSecret = phoneSecrets.inUse
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
    ///
    /// Everything from storing the time to the keep or the restore runs in a task of its own: a caller that is cancelled (the
    /// screen goes during the approval) only stops waiting, and what follows the vault's answer is never lost.
    public func transferApprove(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool {
        let task = Task { @MainActor [self] in
            try await approveTransfer(transferID: transferID, pin: pin, password: password, signer: signer)
        }
        return try await task.value
    }

    private func approveTransfer(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool {
        let rec = record.generation
        let before = (record.value.transferApprovedAtMs, record.value.transferKeepMs)
        // STAGING-TIME-SCALE (S10): the keep period is divided by the vault's time scale now, and kept with the time.
        let keepMs = KeptTransfer.keepMs(timeScale: timeScale)
        let stored = keepMs == KeptTransfer.keepPeriodMs ? nil : keepMs
        let stamp = nowMs
        // Nothing is sent when the time cannot be stored: the keys' bound would be lost with it.
        guard try record.update(since: rec, { $0.transferApprovedAtMs = stamp; $0.transferKeepMs = stored; $0.transferGen += 1 }) else {
            throw VaultFailure(.other, code: "record_closed")
        }
        // Put back after the answer, for the record as it is then (a lock during the approval moved the generation, and a
        // write for the record as it was would be dropped), and only while the stored time is still this approval's.
        let restore: @MainActor () -> Void = { [self] in
            guard record.value.transferApprovedAtMs == stamp else { return }
            _ = try? record.update(since: record.generation) {
                ($0.transferApprovedAtMs, $0.transferKeepMs) = before
                $0.transferGen += 1
            }
        }
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
            if !KeptTransfer.mayHaveReached(e.kind) { restore() }
            throw e
        }
        if keep {
            await checkKeptTransfer()
        } else {
            restore()
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
