import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDVault

/// The opened unlock result as the phone secret's tries judge it (``PhoneSecrets/unlock(isolation:attempt:)``).
extension UnlockOutcome: SecretCheckedAnswer {
    public var code: String? { result.code }
    public var at: Date? { result.at }
}

/// Which of the phone's secrets an unlock carries.
enum UnlockSecretPath {
    /// The current record, then the candidates and the pending epoch-1 records (``PhoneSecrets/unlock(isolation:attempt:)``).
    case current
    /// The replaced records, only on the member's tap (``PhoneSecrets/tryEarlierSecret(isolation:attempt:)``).
    case earlier
}

/// How one unlock goes: which of the phone's secrets, whether a move is followed at once, and where it is routed.
struct UnlockRoute: Sendable {
    var path: UnlockSecretPath = .current
    /// After `update: moved`, unlock again at once (§11.10.6): the unlock screen. The release update reports the move.
    var followMove = true
    /// A release (PCR0) to route to: only to abandon an unconfirmed move (§11.10.5).
    var release: String?
    /// Hears each `503 release_starting` while the routed release starts (§11.10.5).
    var onStarting: (@Sendable (Int) -> Void)?
    /// The unlock's PIN steps of an unresolved PIN change apply (§11.14.9 step 5); the release update never moves them.
    var pinSteps = true
    /// The unlock right after `update: moved`: routed to exactly the release moved from, it waits (``unlockRouted``).
    var afterMove = false
    /// (VAULT-MESSAGING §11.14.9 step 2) A PIN typed on a flow's own screen (the release update, "Finish the move"):
    /// ``PhoneSecrets/pinGeneration`` when it was taken. Each request is refused with nothing sent once it moved
    /// (``VaultManager/pinTakenBefore(_:)``). Nil: the unlock screen's prompts, whose PIN step is read as the unlock starts.
    var pinTaken: Int?
}

/// The sealed result of one unlock, the session it went through, and whether the vault moved.
struct UnlockOpened: Sendable {
    let outcome: UnlockOutcome
    let session: VaultSession
    let moved: Bool
}

/// One unlock's outcome; [moved]: the vault moved and locked itself (only without following the move); [abandoned]: it
/// returned to the previous release (§11.10.4).
struct UnlockStepOutcome: Sendable {
    let attempt: UnlockAttempt
    var moved = false
    var abandoned = false

    init(_ attempt: UnlockAttempt, moved: Bool = false, abandoned: Bool = false) {
        self.attempt = attempt
        self.moved = moved
        self.abandoned = abandoned
    }
}

// The unlock (VAULT-MESSAGING §11.4) over the alternate channel with the phone's unlock secret (§11.14.1), the release
// check before the PIN (§11.10.6) and what the result says (§11.8 backoff, §11.10.4 release moves, §11.11.4 recovery,
// §13.2 rollback). Mirrors vettid-android `VaultManager.preflight`, `unlockOnce`, `unlockStep` and `unlockWithSecret`.
extension VaultManager {
    nonisolated static let updateMoved = "moved"
    nonisolated static let updateAbandoned = "abandoned"
    nonisolated static let updateRefused = "refused"
    /// ``unlockWithEarlierSecret(pin:)`` with no earlier secret that the vault answered.
    public nonisolated static let codeNoEarlierSecret = "no_earlier_secret"

    /// The release check before the PIN (§11.10.6). IOS-PLAN ID8: an instance without `recovery_r` is refused here
    /// already ("This vault's release is too old for the iPhone app"), before any PIN is asked for.
    public func preflight() async throws -> PreflightInfo {
        try await guarded {
            let s = try await openSession()
            let p = try await s.alt.preflight(s.device.altState)
            try ReleasePath.requireR(p.capabilities)
            learnTimeScale(p.timeScale, since: record.generation)
            return PreflightInfo(
                routed: Self.view(p.routed), lastNumber: p.lastNumber, softwareUpdated: p.softwareUpdated, rollback: p.rollback,
                offer: p.offer.map(Self.view), between: p.between.map(Self.view)
            )
        }
    }

    public func unlock(pin: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: cancelRecovery))
    }

    /// A locked vault past its owner-check deadline (§3.6.5): the unlock, then the check with [pin] and [password] before
    /// the app opens, so that the member types both once (``OwnerCheckManager/afterUnlock(pin:password:)``).
    public func unlockWithCheck(pin: String, password: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: cancelRecovery)) { [weak self] in
            await self?.ownerChecks.afterUnlock(pin: pin, password: password)
        }
    }

    /// (Release R, ANDROID-PLAN "Other screens") An unlock with `cancel_recovery`, then at once the owner check with the
    /// PIN and the password, which records that the member is present (§11.14.5).
    public func unlockCancellingRecovery(pin: String, password: String, approve: ReleaseView?) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: true)) { [weak self] in
            await self?.ownerChecks.afterCancelledRecovery(pin: pin, password: password)
        }
    }

    /// (iPhone, IOS-PLAN §6.3 item 5) Whether the earlier-secret step can be offered: a replaced record exists.
    public var earlierSecretOffered: Bool { (try? phoneSecrets.hasEarlierSecret()) ?? false }

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step, only on the member's tap on the "this phone no longer holds
    /// the keys" screen: an unlock with [pin] and each replaced record, newest first, each once. Only `ok`, or
    /// `transfer_incomplete`, makes that record current again.
    public func unlockWithEarlierSecret(pin: String) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: UnlockOptions(), path: .earlier)
    }

    /// A recovery in progress, from `GET /api/vault/status` (MEMBER-API "Vault"), for the unlock screen.
    public func recovery() async throws -> RecoveryView? {
        try await guarded {
            guard let st = try await vaultStatus(), let state = st.recoveryState else { return nil }
            return RecoveryView(state: state, availableAt: st.recoveryAvailableAt ?? "")
        }
    }

    // MARK: - One unlock

    static func options(_ approve: ReleaseView?, cancelRecovery: Bool) -> UnlockOptions {
        UnlockOptions(approve: approve.map { Approval(toPcr0: $0.pcr0, toRelease: $0.number) }, cancelRecovery: cancelRecovery)
    }

    /// One unlock (§11.4). After `update: moved` it unlocks again at once (§11.10.6). Never beside a lock attempt; once the
    /// vault opened, no older lock is ever sent (``LockKeeper``). A failure before the sealed result (network, status,
    /// timeout, unreadable result) is never proof of anything ([holder]); a sealed `unknown_device` is.
    func unlockStep(
        pin: String, options: UnlockOptions, path: UnlockSecretPath = .current, beforeOpen: @MainActor () async -> Void = {}
    ) async -> UnlockAttempt {
        await unlockOutcome(pin: pin, options: options, route: UnlockRoute(path: path), beforeOpen: beforeOpen).attempt
    }

    /// One unlock (§11.4) along [route]: with ``UnlockRoute/followMove`` (the unlock screen) an `update: moved` is followed
    /// at once by the unlock that reaches the new release (§11.10.6); without it (the release update) the move is reported
    /// and the vault stays locked. ``UnlockRoute/release`` routes to a given release (only to abandon an unconfirmed move,
    /// §11.10.5).
    func unlockOutcome(
        pin: String, options: UnlockOptions, route: UnlockRoute, beforeOpen: @MainActor () async -> Void = {}
    ) async -> UnlockStepOutcome {
        do {
            try prepared()
        } catch {
            let f = VaultFailures.map(error) as? VaultFailure
            return UnlockStepOutcome(.failed(f?.kind ?? .other, code: f?.code))
        }
        // §6.7.1 (0.17.0): a phone a transfer set up from an older vault release has no user_guid (§11.4 needs it).
        guard !record.value.userGuid.isEmpty else { return UnlockStepOutcome(.failed(.notSupported, code: UnlockAttempt.codeNoUserGuid)) }
        // §11.14.9 step 5: while a PIN change is unresolved, the previous PIN with the current record, then the new one.
        refreshPinStep()
        let step = route.path == .current && route.pinSteps ? unlockPinStep : .pin
        // Read before the unlock: a lock asked for while it is on its way bumps it, and this unlock then opens nothing.
        let marks = OpenMarks(locks: lockGeneration, record: record.generation, rereads: rereads)
        let opened: UnlockOpened
        do {
            opened = try await lockGuard.keeper.unlocking(opened: { $0.outcome.ok }) {
                try await guarded { try await unlockFollowing(pin: pin, options: options, route: route, tries: tries(step)) }
            }
        } catch let f as VaultFailure {
            _ = holder?.onFailure(f) // never proof (a 503, paused or not, included)
            return UnlockStepOutcome(.failed(f.kind, code: f.code, retryAfterSeconds: f.retryAfterSeconds))
        } catch {
            return UnlockStepOutcome(.failed(.other, code: nil))
        }
        let r = opened.outcome.result
        learnTimeScale(opened.outcome.timeScale, since: marks.record)
        if let next = afterPinStep(step, ok: r.ok, code: r.code, at: r.at) { return UnlockStepOutcome(next) }
        guard r.ok else {
            if await holder?.onSealedUnlockResult(HolderPolicy.of(r)) == true { return UnlockStepOutcome(.failed(.other, code: r.code)) }
            return UnlockStepOutcome(Self.refusal(r))
        }
        // The vault moved and locked itself (§11.10.4 step 8); the caller unlocks again.
        if opened.moved && !route.followMove { return UnlockStepOutcome(.success, moved: true) }
        await didOpen(r, opened.session, marks, beforeOpen: beforeOpen)
        let abandoned = r.update?.result == Self.updateAbandoned
        if let u = r.update, u.result == Self.updateRefused { return UnlockStepOutcome(.updateRefused(code: u.code ?? Self.updateRefused)) }
        return UnlockStepOutcome(.success, abandoned: abandoned)
    }

    /// The unlock with this phone's secret and, after `update: moved` with [route]'s ``UnlockRoute/followMove``, the
    /// unlock that reaches the new release; the outcome, the session and whether the vault moved.
    private func unlockFollowing(
        pin: String, options: UnlockOptions, route: UnlockRoute, tries: UnlockTries
    ) async throws -> UnlockOpened {
        let s = try await openSession()
        var out = try await unlockWithSecret(s, pin: pin, options: options, path: route.path, tries: tries, route: route)
        let moved = out.ok && out.result.update?.result == Self.updateMoved
        if moved && route.followMove {
            // §11.10.6: after a move the vault is locked under the new release; unlock again, which reaches it.
            let next = UnlockRoute(onStarting: route.onStarting, afterMove: true)
            out = try await unlockWithSecret(s, pin: pin, options: UnlockOptions(), path: .current, route: next)
        }
        // A sealed result: the enclave knows this phone; earlier relay refusals no longer count.
        s.device.clearVaultRefusals()
        refusals?.clear()
        refusedByVault = false
        return UnlockOpened(outcome: out, session: s, moved: moved)
    }

    /// The vault opened: the stale lock notices, the outbox, and the phase, unless a lock overtook this unlock.
    private func didOpen(_ r: UnlockResult, _ s: VaultSession, _ marks: OpenMarks, beforeOpen: @MainActor () async -> Void) async {
        let (locks, rec) = (marks.locks, marks.record)
        // The vault is open as of the result's ts: a vault.locking from before it is stale, also after a restart.
        lockNotices.opened(at: r.at)
        if let at = r.at { try? record.opened(since: rec, atMs: Int64((at.timeIntervalSince1970 * 1000).rounded(.down))) }
        // A lock asked for while this unlock was on its way is the newer wish: still pending, or already confirmed by its
        // attempt, which followed the unlock at once. This phone stays locked, nothing is opened or flushed.
        let lockedSince = lockGuard.lockedWhatever(unlocked: true)
        let overtaken = lockedSince || locks != lockGeneration || rec != record.generation
        let guardRef = lockGuard
        Task {
            // No lock from before this unlock: none is ever left in the outbox (locks never go through it).
            _ = try? await s.device.dropFromOutbox(VaultManager.typeVaultLock)
            // Nothing but the lock while one is pending: what the member wrote earlier waits for the next unlock.
            if !overtaken && guardRef.admits() { await s.device.flushOutbox() }
        }
        if overtaken {
            if lockedSince { phase = .locked }
            return
        }
        // A vault event that has the phase read again (a `device.unlinked{vault_deleted}` of a deletion that waited in the
        // locked vault's mailbox) came while this unlock was on its way: its read may have ended before this, or may end
        // after it, and either way this unlock's phase is older. The phase is read again instead, and nothing more (no
        // owner check) is sent to a vault that may be deleting itself (chosen; not in the spec). What this does not cover:
        // the vault sends `device.unlinked{vault_deleted}` before it erases itself (VAULT-MESSAGING §12.5 "Order", steps 2
        // and 4), and until step 5 the member API still lists the vault as unlocked, so a read in that window still gives
        // the open app.
        if rereads != marks.rereads { return await rereadPhase() }
        if !s.device.recovering { await beforeOpen() }
        guard locks == lockGeneration, rec == record.generation, !lockGuard.lockedWhatever(unlocked: true) else { return }
        // The same for one that came during the steps before the open app.
        if rereads != marks.rereads { return await rereadPhase() }
        phase = afterUnlocked(s)
    }

    private func rereadPhase() async { try? await refresh() }

    /// What an unlock reads before it starts, to know at its end what happened meanwhile: the member's locks, the record's
    /// resets and the vault events that have the phase read again.
    struct OpenMarks {
        let locks: Int
        let record: Int
        let rereads: Int
    }

    nonisolated static let typeVaultLock = "vault.lock"

    /// The phase of a vault that just opened.
    func afterUnlocked(_ s: VaultSession) -> AppPhase {
        if s.device.recovering { return .setup(.recovering) }
        if s.device.credentialVersion == nil { return .setup(.needsCredential) }
        ownerChecks.onOpened()
        return record.value.setupComplete ? .unlocked : .setup(.finishing)
    }

    /// One unlock with this phone's unlock secret (release R, §11.14.1): the current record, then the candidates and the
    /// pending epoch-1 records after `device_secret` (``PhoneSecrets/unlock(isolation:attempt:)``), or the replaced
    /// records on the member's tap. IOS-PLAN ID8: an instance without `recovery_r` is refused before anything is built.
    private func unlockWithSecret(
        _ s: VaultSession, pin: String, options: UnlockOptions, path: UnlockSecretPath, tries: UnlockTries = .all,
        route: UnlockRoute = UnlockRoute()
    ) async throws -> UnlockOutcome {
        let attempt: ([UInt8]) async throws -> UnlockOutcome = { [self] secret in
            try await unlockRouted(s, pin: pin, options: options, route: route, secret: secret)
        }
        switch path {
        case .current:
            return try await phoneSecrets.unlock(tries: tries, attempt: attempt)
        case .earlier:
            switch try await phoneSecrets.tryEarlierSecret(attempt: attempt) {
            case .restored(let answer, let opened):
                // §6.3 item 5: after `ok`, a History entry and an immediate prompt for a new phone secret (I1.8).
                if opened { earlierSecretRestored() }
                return answer
            case .unchanged(let last?): return last
            case .unchanged(nil): throw VaultFailure(.deviceSecret, code: Self.codeNoEarlierSecret)
            }
        }
    }

    /// How often, and how far apart, an unlock right after a move is tried again while the member API still routes the
    /// vault to the release it left (chosen; not in the spec: the API learns the move from the vault's lifecycle event).
    nonisolated static let routingRetries = 3
    nonisolated static let routingPause: Duration = .seconds(3)
    /// The code of an unlock after a move that the member API kept routing to the release the vault left.
    public nonisolated static let codeReleaseNotRouted = "release_not_routed"

    /// One unlock request with [secret]. Right after a move (``UnlockRoute/afterMove``) the member API may still route to
    /// exactly the release the vault left, which is not sent to (``AltRefused/notYetRouted``): that is waited out, a few
    /// times; still so, it is a neutral failure, never the rollback's text (chosen; not in the spec). Any other older
    /// release, and every other unlock, keeps the rollback refusal (§11.10.6).
    private func unlockRouted(
        _ s: VaultSession, pin: String, options: UnlockOptions, route: UnlockRoute, secret: [UInt8]
    ) async throws -> UnlockOutcome {
        var options = options
        options.afterMove = route.afterMove
        let guid = record.value.userGuid
        let attester = config.attester
        let sleep = config.releaseUpdateSleep
        let taken = route.pinTaken
        var waited = 0
        while true {
            do {
                return try await s.alt.unlock(
                    party: s.device, userGuid: guid, pin: pin, attester: attester, options: options, release: route.release,
                    onStarting: route.onStarting,
                    unlockSecretFor: { [self] caps in
                        try ReleasePath.requireR(caps)
                        // Right before the request is built and sent: nothing goes with a PIN taken before a change.
                        if let moved = pinTakenBefore(taken) { throw moved }
                        return secret
                    }
                )
            } catch AltRefused.notYetRouted {
                guard waited < Self.routingRetries else { throw VaultFailure(.vaultUnavailable, code: Self.codeReleaseNotRouted) }
                waited += 1
                try await sleep(Self.routingPause)
            }
        }
    }

    /// A sealed refusal (§11.4) as the screens see it.
    static func refusal(_ r: UnlockResult) -> UnlockAttempt { // swiftlint:disable:this cyclomatic_complexity
        let wait = Int64(clamping: r.retryAfterSeconds)
        return switch r.code {
        case "bad_pin": .badPin(retryAfterSeconds: wait)
        case "backoff": .backoff(retryAfterSeconds: wait)
        case "recovery_pending": .recoveryPending
        // §11.7.1: sealed, decided before the PIN; not a PIN failure and no backoff.
        case VaultDevice.codeSignerRefused: .signerRefused
        case "state_rollback": .stateRollback
        case "attestation": .failed(.attestation, code: r.code)
        case "manifest": .failed(.manifest, code: r.code)
        // Release R (§11.4, §11.14): decided before the PIN, not PIN failures.
        case UnlockEpoch.deviceSecret: .failed(.deviceSecret, code: r.code)
        case UnlockEpoch.transferIncomplete: .failed(.transferIncomplete, code: r.code)
        case "retry": .failed(.retry, code: r.code)
        default: .failed(.other, code: r.code)
        }
    }

    static func view(_ r: Release) -> ReleaseView {
        ReleaseView(number: r.number, pcr0: r.pcr0, status: r.status.rawValue, endsAt: r.endsAt, notes: r.notes)
    }
}
