import Foundation
import VettIDAltChan
import VettIDKeys
import VettIDVault

/// The epoch-1 record an enrollment's secret came from, and the capabilities of the instance it was sealed to, as the
/// alternate channel's callback (off the main actor) leaves them.
private final class EnrollPath: @unchecked Sendable {
    private let lock = NSLock()
    private var epochID: String?
    private var caps: [String] = []

    func set(_ id: String, _ capabilities: [String]) { lock.withLock { (epochID, caps) = (id, capabilities) } }
    var value: (id: String?, capabilities: [String]) { lock.withLock { (epochID, caps) } }
}

/// The requests of this call that were posted and not known to be unprocessed, as the alternate channel's callbacks
/// (off the main actor) count them.
private final class PostedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0

    func posted() { lock.withLock { outstanding += 1 } }
    func unprocessed() { lock.withLock { outstanding = Swift.max(outstanding - 1, 0) } }
    var value: Int { lock.withLock { outstanding } }
}

// Enrollment, the first handshake, the credential and Finish setup (VAULT-MESSAGING §11.3, §3.5.5, §3.5.7, §11.14.1).
extension VaultManager {
    /// The setting the backup choice sets (§3.5.6).
    nonisolated static let keyBackup = "credential.backup"
    /// `credential.create` on a vault that already holds this phone's credential (a create whose answer was lost).
    nonisolated static let codeExists = "exists"
    nonisolated static let codeVaultExists = "vault_exists"
    /// `credential.create` without the PIN, which every vault of this app needs (IOS-PLAN ID8, §11.14.9).
    nonisolated static let codePinRequired = "pin_required"
    /// ``finishSetup()`` before `vault.enroll.confirm` was answered.
    nonisolated static let codeEnrollUnconfirmed = "enroll_unconfirmed"

    /// Enrolls the vault the redeem named (§11.3) and runs the first handshake. Only a release with `recovery_r` gets the
    /// request (IOS-PLAN ID8). The phone's unlock secret of epoch 1 (§11.14.1 "On an iPhone") goes in it: its record is
    /// stored before the request is built, a retry reuses it (IOS-PLAN §6.3 item 7), and the enrollment's `ok`, or the
    /// vault's `vault.enrolled`, confirms it.
    ///
    /// A request whose answer was lost may have made the vault: `vault.enrolled` then pins it on this device, and no
    /// second request is sent; a retry that meets `vault_exists` first waits ``VaultManagerConfig/enrolledGrace`` for
    /// that `vault.enrolled` before it reports the vault as another phone's.
    public func enroll(pin: String, onStep: @MainActor (EnrollStep) -> Void) async throws {
        try await guarded {
            let s = try await openSession()
            let local = record.value
            onStep(.enroll)
            // An earlier request of this enrollment got no answer: its vault.enrolled may still be on its way, and a new
            // request would replace the nonce that vault.enrolled's attestation is checked against.
            if s.device.vaultID == nil, s.device.altState.enrollNonce != nil { await awaitEnrolled(s, config.enrolledGrace) }
            if s.device.vaultID == nil { try await sendEnroll(s, local, pin: pin, onStep: onStep) }
            // This phone's enrollment made the vault: its outcome is known, and only this phone confirms it.
            try record.update(since: record.generation) {
                $0.enrolledHere = true
                $0.enrollStartedMs = nil
            }
            try confirmEnrolledSecret(local, s.device)
            onStep(.handshake)
            if s.device.deviceID == nil { try await s.device.completeEnrollment() }
        }
    }

    /// The sealed `vault.enroll` and its answer, then `vault.enrolled`. Right before a request is posted the start of an
    /// enrollment whose outcome is unknown is recorded (``LocalAccount/enrollStartedMs``). Only a definite outcome of an
    /// enrollment with no earlier unknown request clears it and drops its keys (``EnrollOutcomes``).
    private func sendEnroll(
        _ s: VaultSession, _ local: LocalAccount, pin: String, onStep: @MainActor (EnrollStep) -> Void
    ) async throws {
        let rec = record.generation
        let earlierUnknown = local.enrollStartedMs != nil
        let secrets = phoneSecrets
        let path = EnrollPath()
        let posted = PostedCount()
        let out: EnrollOutcome
        do {
            out = try await s.alt.enroll(
                party: s.device, vaultID: local.vaultID, userGuid: local.userGuid, pin: pin, attester: config.attester
            ) { capabilities in
                try ReleasePath.requireR(capabilities)
                let epoch = try secrets.reuseOrCreate(keyVault: local.vaultID)
                path.set(epoch.id, capabilities)
                return epoch.secret
            } onPosting: { [weak self] in
                try await self?.markPosting()
                posted.posted()
            } onUnprocessed: {
                posted.unprocessed()
            }
        } catch {
            // No request of this enrollment can have been processed: nothing to keep.
            if EnrollOutcomes.neverSent(earlierUnknown: earlierUnknown, outstanding: posted.value) {
                try await abandonEnrollment(s, path.value.id)
            }
            throw error
        }
        let (epochID, capabilities) = path.value
        try record.update(since: rec) {
            if out.ok, !out.vaultID.isEmpty { $0.vaultID = out.vaultID }
            $0.capabilities = capabilities
            $0.timeScale = out.timeScale
        }
        memberVault.set(recorded: record.value.vaultID)
        recoveryOffered = ReleasePath.recoveryOffered(capabilities)
        guard out.ok else {
            // The vault this phone's lost request made answers a retry `vault_exists`; its vault.enrolled tells it apart
            // from another phone's vault.
            if out.code == Self.codeVaultExists { await awaitEnrolled(s, config.enrolledGrace) }
            if s.device.vaultID != nil { return }
            // The refused request is the last one posted; any other posted before it in this call is unknown.
            if EnrollOutcomes.definite(earlierUnknown: earlierUnknown || posted.value > 1) {
                try await abandonEnrollment(s, epochID)
            }
            throw VaultFailure(VaultFailures.enrollFailure(out.code), code: out.code)
        }
        if let epochID { try phoneSecrets.confirmCreate(id: epochID) }
        onStep(.waitForVault)
        try await s.device.awaitEnrolled()
    }

    /// A request is about to be posted: from now its outcome is unknown until its answer.
    private func markPosting() throws {
        let nowMs = Int64(config.now().timeIntervalSince1970 * 1000)
        try record.update(since: record.generation) { if $0.enrollStartedMs == nil { $0.enrollStartedMs = nowMs } }
    }

    /// An enrollment that made no vault: its nonces are dropped (a later `vault.enrolled` for it is not accepted), its
    /// pending epoch-1 record and key deleted, and a start-over allowed again.
    private func abandonEnrollment(_ s: VaultSession, _ epochID: String?) async throws {
        // No request of it made a vault: none of the App Attest keys they attested is bound (IOS-PLAN §6.2).
        for k in s.device.altState.enrollAttempts.compactMap(\.attestKeyID) { try config.attester.discard(keyID: k) }
        try await s.device.abandonEnrollment()
        if let epochID { try phoneSecrets.dropPending(id: epochID) }
        try record.update(since: record.generation) { $0.enrollStartedMs = nil }
    }

    /// Waits up to [seconds] for `vault.enrolled`; nothing when it does not come.
    private func awaitEnrolled(_ s: VaultSession, _ seconds: TimeInterval) async {
        try? await s.device.awaitEnrolled(timeout: seconds)
    }

    /// `vault.enrolled` pinned the vault: the single pending epoch-1 record of its `key_vault` is the one the vault holds
    /// (``PhoneSecrets/confirmPending(keyVault:)``; chosen, not in the spec: `vault.enrolled` taken as the enrollment's
    /// answer).
    /// With two such records left (their keys alive), it cannot tell: both stay pending, an unlock proves the right
    /// one, and setup carries on.
    func confirmEnrolledSecret(_ local: LocalAccount, _ d: VaultDevice) throws {
        // The App Attest key of the request whose vault.enrolled arrived is the one the vault bound (IOS-PLAN §6.2). Best
        // effort, at every start: a key already current changes nothing and writes nothing, and a record that cannot be
        // written now never stops the start (the unlock's fallback finds the bound key).
        if d.vaultID != nil, let k = d.altState.enrolledAttestKeyID { try? config.attester.confirm(keyID: k) }
        if d.vaultID != nil, !d.recovering, !local.vaultID.isEmpty {
            do {
                try phoneSecrets.confirmPending(keyVault: local.vaultID)
            } catch let f as VaultFailure where f.code == PhoneSecrets.codeAmbiguousEpochOne {
                // Left pending.
            }
        }
        usesPhoneSecret = phoneSecrets.inUse
    }

    public func createCredential(password: String, backup: Bool, onStep: @MainActor (EnrollStep) -> Void) async throws {
        try await createCredential(password: password, backup: backup, pin: nil, onStep: onStep)
    }

    /// Creates the Protean Credential (§3.5.5; release R: with the PIN, which the vault verifies and arms recovery with,
    /// §11.14.9), sets the backup (§3.5.6) and confirms the vault (`vault.enroll.confirm`). Resumes where an earlier try
    /// stopped: the handshake when it did not finish, no second credential when the device holds one. Without the PIN
    /// nothing is sent: every vault of this app is of release R (IOS-PLAN ID8).
    public func createCredential(
        password: String, backup: Bool, pin: String?, onStep: @MainActor (EnrollStep) -> Void
    ) async throws {
        let locks = lockGeneration
        try await guarded {
            guard let pin, !pin.isEmpty else { throw VaultFailure(.other, code: Self.codePinRequired) }
            let s = try await openSession()
            try confirmEnrolledSecret(record.value, s.device)
            if s.device.deviceID == nil {
                onStep(.handshake)
                try await s.device.completeEnrollment()
            }
            onStep(.createCredential)
            // Kept first, so that a restart before the confirmation still sends the member's choice.
            try record.update(since: record.generation) { $0.backupChoice = backup }
            if s.device.credentialVersion == nil { try await createOrFetch(s, password: password, pin: pin) }
            try await confirmProvisional(s, backup: backup, onStep: onStep)
            // A lock asked for meanwhile wins: the phone stays locked.
            if locks == lockGeneration, !lockGuard.holdsPhone { phase = .setup(.finishing) }
        }
    }

    /// The backup setting, when the member chose, and `vault.enroll.confirm` (§3.5.7, §11.3): the vault stops being
    /// provisional; recorded once answered. After a restart between the credential and the answer, a status read that
    /// publishes the vault open sends both first (``refresh()``), and so does ``finishSetup()`` when none did, by the phone
    /// whose enrollment made the vault only.
    /// [since]: the record's generation when it began (a confirmation answered after a reset or a lock is not recorded in
    /// the record that came after).
    func confirmEnrollment(_ s: VaultSession, backup: Bool?, since: Int, onStep: @MainActor (EnrollStep) -> Void) async throws {
        onStep(.backup)
        if let backup { try await setSetting(s, Self.keyBackup, backup ? "true" : "false") }
        onStep(.confirm)
        try await openApi(s).enrollConfirm()
        try record.update(since: since) { $0.enrollConfirmed = true }
    }

    /// ``confirmEnrollment(_:backup:since:onStep:)``, one at a time: the credential's step, a status read, an unlock and
    /// "Finish" that find the vault unconfirmed together share the confirmation on its way in the same session, its answer
    /// or its failure (each says it as it says its own), so the backup setting and `vault.enroll.confirm` are sent once.
    /// The first sends it, with its [onStep]; one that comes after the answer sends nothing. One on a session dropped since
    /// (a background, a lock, a reset) is not joined: its answer may never be collected, and this caller's session sends
    /// its own.
    /// [s] must be the live session: one dropped since its caller got it (a read that began before a background) sends
    /// nothing and is refused as such.
    func confirmProvisional(_ s: VaultSession, backup: Bool?, onStep: @MainActor (EnrollStep) -> Void = { _ in }) async throws {
        guard s.device === session?.device else { throw VaultFailure(.other, code: "session_dropped") }
        // Joined only in its own session and before any lock since it began: a vault that locked meanwhile keeps the
        // request in its mailbox, so its answer may come only after its timeout. A caller that joins waits for it as its
        // sender does, request timeout included (``lockedSinceConfirming(_:)``).
        if let c = confirming, c.session == sessionGeneration, c.locks == lockGeneration, !lockedSinceConfirming(c) {
            confirmationsJoined += 1
            do {
                return try await c.done.value
            } catch is CancellationError where !Task.isCancelled {
                // Its sender was cancelled (a screen's task), not this caller: this one goes on, and sends it if still due.
                // (A cancelled request ends in a `CancellationError`; any other failure is said as the sender's.)
                return try await confirmProvisional(s, backup: backup, onStep: onStep)
            }
        }
        guard !record.value.enrollConfirmed else { return }
        let (results, report) = AsyncStream.makeStream(of: Result<Void, any Error>.self)
        let done = Task<Void, any Error> {
            for await r in results { return try r.get() }
            throw CancellationError()
        }
        confirming = Confirming(done: done, session: sessionGeneration, locks: lockGeneration, start: readStart(),
                                openedAt: lockNotices.openedAt)
        defer {
            report.finish()
            if confirming?.done == done { confirming = nil }
        }
        do {
            try await confirmEnrollment(s, backup: backup, since: record.generation, onStep: onStep)
            report.yield(.success(()))
        } catch {
            report.yield(.failure(error))
            throw error
        }
    }

    /// A lock that closed the vault [c] went to: a probe's since it began, or a `vault.locking` timed after the opening it
    /// began under, heard before or after it began (``lockHeardAfterOpening(_:since:)``, as the opening itself judges
    /// it). The one of the opening before, heard late, does not count. With that opening's moment unknown (a status read
    /// at a cold start), any lock heard since it began does: a second confirmation is harmless, a join of one the vault
    /// never answers is not. (The opening is the last one this phone recorded. An unlock whose answer was lost, or came
    /// without a time, leaves an older one recorded: a lock heard after that one then refuses the join, which costs only
    /// a second confirmation.)
    func lockedSinceConfirming(_ c: Confirming) -> Bool {
        lockHeardAfterOpening(c.openedAt, since: c.start.heard)
    }

    /// A confirmation on its way: its outcome, and the session and the locks it began under.
    struct Confirming {
        let done: Task<Void, any Error>
        let session: Int
        let locks: Int
        let start: ReadStart
        /// The opening it began under, on the vault's clock (``LockNotices/openedAt``), when known.
        let openedAt: Date?
    }

    /// `credential.create`. A vault that answers `exists` already holds this phone's credential (a create whose answer
    /// was lost): it is fetched instead of a new one being asked for (vettid-android `CredentialCreate.fetchInstead`;
    /// every vault of this app is of release R).
    private func createOrFetch(_ s: VaultSession, password: String, pin: String) async throws {
        do {
            try await openApi(s).credentialCreate(password: password, pin: pin)
        } catch let e as VaultOpError where e.code == Self.codeExists {
            try await openApi(s).credentialFetch()
        }
    }

    /// Sets one setting to [json] unless it already has that value.
    func setSetting(_ s: VaultSession, _ key: String, _ json: String) async throws {
        let current = try await openApi(s).settingsGet()
        if current.values[key] == json { return }
        _ = try await openApi(s).settingsSet(version: current.version, set: [(key, json)])
    }

    /// Leaves onboarding for the open app: only from ``SetupStage/finishing`` (``FinishSetupGate``), never while a lock is
    /// pending, and never before `vault.enroll.confirm` was answered. "Finish the move", which also holds it, comes with
    /// I3.3.
    /// A provisional vault not confirmed yet (a restart before the answer, and no status read published it open since: one
    /// overtaken by a lock, or the vault locked and then unlocked) is confirmed first, by the paired phone whose enrollment
    /// made it, and only when the gate would let the setup end.
    public func finishSetup() async throws {
        let local = record.value
        let gateOpen = FinishSetupGate.allows(phase, lockPending: lockGuard.holdsPhone, finishingMove: finishMoveRunner.finishing)
        if gateOpen, !local.enrollConfirmed, local.enrolledHere {
            // The session as it is now (opened again after a background, say): a failure is said, as any.
            try await guarded {
                let s = try await openSession()
                if s.device.deviceID != nil { try await confirmProvisional(s, backup: local.backupChoice) }
            }
        }
        // A gate that refuses now (a lock asked for meanwhile) leaves the phase as it is, and says nothing more.
        _ = try finishSetupGated()
    }

    /// ``finishSetup()``; false when its gate refused (nothing written, the phase left as it is). Mirrors vettid-android
    /// `VaultManager.finishSetupGated` (the record's write and the phase are set in one step on the main actor, so a lock
    /// or a wipe cannot come between them).
    func finishSetupGated() throws -> Bool {
        let rec = record.generation
        let allowed = FinishSetupGate.allows(phase, lockPending: lockGuard.holdsPhone, finishingMove: finishMoveRunner.finishing)
        guard allowed else { return false }
        guard record.value.enrollConfirmed else { throw VaultFailure(.other, code: Self.codeEnrollUnconfirmed) }
        // A transfer's leftovers go with it (a take-over whose own clear could not be written): the setup is complete.
        try guardedSync {
            try record.update(since: rec) {
                $0.setupComplete = true
                $0.movedIn = false
                $0.transferStartedMs = nil
                $0.transferEpochID = nil
                $0.transferCode = nil
            }
        }
        phase = .unlocked
        return true
    }
}
