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
            try await confirmEnrollment(s, backup: backup, onStep: onStep)
            phase = .setup(.finishing)
        }
    }

    /// The backup setting, when the member chose, and `vault.enroll.confirm` (§3.5.7, §11.3): the vault stops being
    /// provisional; recorded once answered.
    func confirmEnrollment(_ s: VaultSession, backup: Bool?, onStep: @MainActor (EnrollStep) -> Void) async throws {
        onStep(.backup)
        if let backup { try await setSetting(s, Self.keyBackup, backup ? "true" : "false") }
        onStep(.confirm)
        try await s.api.enrollConfirm()
        try record.update(since: record.generation) { $0.enrollConfirmed = true }
    }

    /// `credential.create`. A vault that answers `exists` already holds this phone's credential (a create whose answer
    /// was lost): it is fetched instead of a new one being asked for (vettid-android `CredentialCreate.fetchInstead`;
    /// every vault of this app is of release R).
    private func createOrFetch(_ s: VaultSession, password: String, pin: String) async throws {
        do {
            try await s.api.credentialCreate(password: password, pin: pin)
        } catch let e as VaultOpError where e.code == Self.codeExists {
            try await s.api.credentialFetch()
        }
    }

    /// Sets one setting to [json] unless it already has that value.
    private func setSetting(_ s: VaultSession, _ key: String, _ json: String) async throws {
        let current = try await s.api.settingsGet()
        if current.values[key] == json { return }
        _ = try await s.api.settingsSet(version: current.version, set: [(key, json)])
    }

    /// Leaves onboarding for the open app: only from ``SetupStage/finishing`` (``FinishSetupGate``), and never before
    /// `vault.enroll.confirm` was answered. The lock and "Finish the move" that also hold it come with I1.7 and I3.3.
    public func finishSetup() async throws {
        let rec = record.generation
        guard FinishSetupGate.allows(phase, lockPending: false, finishingMove: false) else { return }
        guard record.value.enrollConfirmed else { throw VaultFailure(.other, code: Self.codeEnrollUnconfirmed) }
        try guardedSync { try record.update(since: rec) { $0.setupComplete = true } }
        phase = .unlocked
    }
}
