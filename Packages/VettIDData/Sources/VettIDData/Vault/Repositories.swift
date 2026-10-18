import Foundation
import Observation
import VettIDAltChan

// The data layer's contracts with the screens: the account, the vault, the credential and a move. Every failure is a
// ``VaultFailure``.
//
// Each of vettid-android's `StateFlow`s is a read-only property of a `@MainActor` protocol: a conforming type is an
// `@Observable` class, so that SwiftUI views and `@Observable` view models observe the property directly
// (Observation tracks it through the protocol). The protocols that hold state refine `Observable`, so a conforming
// type that is not observable does not compile; ``MoveRepository`` holds none that a screen follows. A Kotlin default method or property is a protocol requirement with a
// default in an extension; the defaults that Android makes throw `NOT_SUPPORTED` throw ``FailureKind/notSupported``
// here.

/// The answer to `vault.recovery.open` (VAULT-MESSAGING §11.14.6): [code] `ok` or one of the result codes (`wrong`,
/// `wrong_again`, `attempt_lost`, `quiet`, `wait`, `busy`, `retry`, `stored_mismatch`, `exhausted`, `closed`,
/// `not_armed`, `counter_unavailable`, …); [used] of 10 attempts when the counter answered; [retryAt] with `quiet`,
/// `wait`, and a wrong or lost attempt that began a wait. Mirrors vettid-android `RecoveryOpenOutcome`.
public struct RecoveryOpenOutcome: Equatable, Sendable {
    public static let attempts = 10

    public var code: String
    public var used: Int?
    public var retryAt: Date?
    /// The open before this one was taken by the member API and got no answer (§11.14.6 "A right entry…").
    public var afterUnanswered: Bool
    /// The vault had already answered `ok` and made this phone its app, but the phone could not finish opening it:
    /// [code] is then the answer of this phone's own unlock (`bad_pin`, `backoff`, …), and nothing of the recovery was
    /// used.
    public var opened: Bool
    /// Whether THIS request used an attempt, as the vault says; nil from a vault that does not say.
    public var attemptUsed: Bool?

    public init(
        _ code: String,
        used: Int? = nil,
        retryAt: Date? = nil,
        afterUnanswered: Bool = false,
        opened: Bool = false,
        attemptUsed: Bool? = nil
    ) {
        self.code = code
        self.used = used
        self.retryAt = retryAt
        self.afterUnanswered = afterUnanswered
        self.opened = opened
        self.attemptUsed = attemptUsed
    }

    public var ok: Bool { code == "ok" }
    public var left: Int? { used.map { Swift.max(Self.attempts - $0, 0) } }
}

/// The member's account on this device: the phase the app is in, the setup code that starts a vault here
/// (VAULT-MESSAGING §11.12: the app never signs in), and the account as the vault reports it (§11.13). Mirrors
/// vettid-android `AccountRepository`.
@MainActor
public protocol AccountRepository: AnyObject, Observable, Sendable {
    var phase: AppPhase { get }

    /// The member's account from the vault's snapshot (read-only), or only its masked email before one arrived.
    var account: AccountInfo? { get }

    /// A development hint for the setup screens (DevStack builds only).
    var devHint: String? { get }

    /// This build's member API origin (`https://account.vettid.org`): setup and recovery QR codes name the portal that
    /// made them in `api`, which must equal it exactly (an identifier, never contacted).
    var apiOrigin: String { get }

    /// The operator paused the vault service (MEMBER-API 1.2.0): `GET /api/vault/status` said `service: "paused"`, or a
    /// vault route answered `503 vault_unavailable` with it. For a non-blocking banner only; cleared when `status` says
    /// the service is available again. Default: false.
    var servicePaused: Bool { get }

    /// Re-reads the vault's state and sets ``phase``.
    func refresh() async throws

    /// The app came back to the foreground: whatever stopped while it was in the background is checked again.
    func onForeground()

    /// Redeems the portal's setup code with this phone's app key (§11.12.1) and returns the account's masked email
    /// (`email_hint`) for the member to confirm before a PIN is asked for. ``FailureKind/setupCodeInvalid`` for any
    /// refusal of the code itself.
    func redeemSetupCode(_ code: SetupCodeInput) async throws -> String

    /// "That is not my account" after a redeem, or a pending key that expired: back to the welcome screen.
    func forgetSetupCode() async throws

    /// The member confirmed "Start over" on ``FailureKind/noVault``: asks the member API once more and, only if it again
    /// says explicitly that the account has no vault, forgets this phone's keys for it; the welcome screen follows. Any
    /// other answer is the new phase (``refresh()``).
    func forgetMissingVault() async throws

    /// Re-reads the account snapshot from the vault (`account.get`); quiet on failure.
    func refreshAccount() async

    /// The member's "Erase VettID from this phone", offered only where the vault did not recognise this phone at
    /// unlock: the same crash-safe wipe as a replaced phone's, with the same best-effort, bounded relay cleanup. The
    /// erase itself needs no network. Returns once the phone is as freshly installed (``phase`` ``AppPhase/signedOut``);
    /// it runs to the end even if the caller is cancelled.
    func eraseThisPhone() async throws

    /// "Erase VettID's data on this phone", offered only after a wipe that did not finish (``FailureKind/eraseFailed``):
    /// local only, every keychain item, key and file of the app. True when nothing is left (``phase`` is then
    /// ``AppPhase/signedOut``); false when something could not be erased. Default: false.
    func clearAppData() async -> Bool
}

public extension AccountRepository {
    func clearAppData() async -> Bool { false }
    var servicePaused: Bool { false }
    func onForeground() {}
    func forgetMissingVault() async throws {}
    func refreshAccount() async {}
}

/// The vault on this device: enrollment, unlock and lock, status, PIN, deletion, recovery. Mirrors vettid-android
/// `VaultRepository`.
@MainActor
public protocol VaultRepository: AnyObject, Observable, Sendable {
    /// The open app was sent to the unlock screen because the relay kept refusing this phone's messages to the vault
    /// (`token_revoked`): the vault may no longer know it. Not proof: the PIN asks the enclave. Cleared by any sealed
    /// unlock result or message from the vault.
    var refusedByVault: Bool { get }

    /// What to tell the member about the lock they asked for (``LockNotice``). Default: ``LockNotice/none``.
    var lockNotice: LockNotice { get }

    /// Tries the pending lock again now.
    func retryLock()

    /// The member has read that the vault confirmed a lock that was in doubt.
    func dismissLockNotice()

    /// Enrolls a vault with [pin] (VAULT-MESSAGING §11.3) and runs the first handshake.
    func enroll(pin: String, onStep: @MainActor (EnrollStep) -> Void) async throws

    /// A start-over requested on the account portal (§11.11.9, `deletion` in `GET /api/vault/status`): nil when none is
    /// pending. Default: nil.
    var pendingDeletion: DeletionView? { get }

    /// Cancels the pending start-over (`POST /api/vault/deletion/cancel`, signed by the app key). True when cancelled.
    func cancelDeletion() async throws -> Bool

    /// Creates the Protean Credential (§3.5.5), sets the backup (§3.5.6) and confirms the vault.
    func createCredential(password: String, backup: Bool, onStep: @MainActor (EnrollStep) -> Void) async throws

    /// (Release R, §11.14.9) The same, with the PIN, which the vault verifies and arms recovery with.
    func createCredential(password: String, backup: Bool, pin: String?, onStep: @MainActor (EnrollStep) -> Void) async throws

    /// (Release R) `pin.change` with the password and the phone's next secret (§11.14.9). Refused for a vault without a
    /// phone secret (``changePin(pin:newPin:)`` is the earlier operation). Default: ``FailureKind/notSupported``.
    func changePin(pin: String, newPin: String, password: String) async throws

    /// (Release R) `vault.secret.renew`: a new phone secret with the PIN unchanged (Settings → Security). Default:
    /// ``FailureKind/notSupported``.
    func renewPhoneSecret(pin: String, password: String) async throws

    /// (Release R) Whether this phone holds a phone secret for its vault (a vault of release R).
    var usesPhoneSecret: Bool { get }

    /// This phone received its vault by a direct transfer and has not left onboarding yet.
    var movedIn: Bool { get }

    /// (§11.10.9) Whether the vault's release offers recovery: true for a release before R (its earlier recovery), and
    /// from release R only when its capabilities list `recovery_offered`. Default: true.
    var recoveryOffered: Bool { get }

    /// (Release R, §11.14.10) When this phone approved a transfer it still keeps the keys for (until the new phone's
    /// first unlock, at most 7 days); nil otherwise. The shell shows "Finish the move on your new phone".
    var transferKeptSince: Date? { get }

    /// (Release R, §11.14.10) This new phone received a transfer and has not yet finished the move (an unlock from
    /// storage with its own secret): the app asks again at every start until it is done.
    var finishMovePending: Bool { get }

    /// (Release R, §11.14.10) "Finish the move": `vault.lock`, then `vault.unlock` with [pin] and this phone's own
    /// secret. While it runs, ``finishingMove`` is true: the phone counts as locked (as after any lock) but the screen
    /// that asked stays. Default: ``lock()`` then ``unlock(pin:approve:cancelRecovery:)``.
    func finishMove(pin: String) async throws -> UnlockAttempt

    /// (Release R) True while ``finishMove(pin:)`` runs, for at most a bounded time.
    var finishingMove: Bool { get }

    /// (Release R) Why the last ``finishMove(pin:)`` did not open the vault (`transfer_incomplete`, a wrong PIN, a wait,
    /// the network), for the unlock screen that follows it; nil after a success or ``acknowledgeFinishMoveFailure()``.
    var finishMoveFailure: FailureKind? { get }

    func acknowledgeFinishMoveFailure()

    /// (Release R, §11.14.10) This old phone opened the vault with its own keys after approving a transfer ("The move
    /// didn't finish"): it is the vault's phone again. Told once, until ``acknowledgeMovedBack()``.
    var movedBack: Bool { get }

    func acknowledgeMovedBack()

    /// (Release R) At the end of the 7 days after approving a transfer, the vault confirmed that this phone is still its
    /// app: the move did not happen and the phone keeps its keys. Told once.
    var moveNotDone: Bool { get }

    func acknowledgeMoveNotDone()

    /// (Release R, ANDROID-PLAN "Transfer") After a transfer, a PIN change or a password change the app offers to rotate
    /// the vault's keys (`credential.rotate`), until a rotation or ``dismissRotateOffer()``.
    var rotateOffered: Bool { get }

    func dismissRotateOffer()

    /// (Release R, §11.14.10) This old phone removed its keys at the end of a kept transfer (the new phone finished the
    /// move, or 7 days passed). Told once, in this process, until ``acknowledgeMovedAway()``.
    var movedAway: Bool { get }

    func acknowledgeMovedAway()

    /// Leaves onboarding for the app.
    func finishSetup() async throws

    /// The release check before the PIN (§11.10.6).
    func preflight() async throws -> PreflightInfo

    /// Unlocks (§11.4), optionally approving [approve] (§11.10.3) or cancelling a recovery (§11.11.4).
    func unlock(pin: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt

    /// (Release R, ANDROID-PLAN "Other screens") An unlock that cancels a pending recovery (`cancel_recovery`), followed
    /// at once by the owner check with [pin] and [password], which records that the member is present. Before release
    /// R, and by default: the unlock with `cancel_recovery` alone.
    func unlockCancellingRecovery(pin: String, password: String, approve: ReleaseView?) async throws -> UnlockAttempt

    /// Unlocks a vault past its owner-check deadline (§3.6.5): the PIN unlocks; if `vault.status` then says held or due,
    /// the check follows with [pin] and [password]. Default: the unlock alone.
    func unlockWithCheck(pin: String, password: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt

    func lock() async throws

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: the app asks at once for a new phone
    /// secret (`vault.secret.renew`). Default: false.
    var renewSecretSuggested: Bool { get }

    /// (iPhone, IOS-PLAN §6.3 item 5) Whether the earlier-secret step can be offered on the "this phone no longer holds
    /// the keys" screen: a replaced phone-secret record exists. Default: false.
    var earlierSecretOffered: Bool { get }

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step, only on the member's tap: an unlock with [pin] and each
    /// replaced record of the phone secret, newest first, each once. Default: ``FailureKind/notSupported``.
    func unlockWithEarlierSecret(pin: String) async throws -> UnlockAttempt

    func overview() async throws -> VaultOverview

    /// `pin.change` (§10.6).
    func changePin(pin: String, newPin: String) async throws

    /// `vault.delete` (§12.5): irreversible.
    func deleteVault(pin: String, password: String) async throws

    /// A recovery in progress, from `GET /api/vault/status` (it is cancelled on the account portal, or by an unlock).
    func recovery() async throws -> RecoveryView?

    func attestationInfo() async throws -> AttestationInfo
}

public extension VaultRepository {
    var lockNotice: LockNotice { .none }
    func retryLock() {}
    func dismissLockNotice() {}
    var earlierSecretOffered: Bool { false }
    var renewSecretSuggested: Bool { false }
    func unlockWithEarlierSecret(pin: String) async throws -> UnlockAttempt { throw VaultFailure(.notSupported) }
    var pendingDeletion: DeletionView? { nil }
    func cancelDeletion() async throws -> Bool { false }

    func createCredential(password: String, backup: Bool, pin: String?, onStep: @MainActor (EnrollStep) -> Void) async throws {
        try await createCredential(password: password, backup: backup, onStep: onStep)
    }

    func changePin(pin: String, newPin: String, password: String) async throws { throw VaultFailure(.notSupported) }
    func renewPhoneSecret(pin: String, password: String) async throws { throw VaultFailure(.notSupported) }
    var usesPhoneSecret: Bool { false }
    var movedIn: Bool { false }
    var recoveryOffered: Bool { true }
    var transferKeptSince: Date? { nil }
    var finishMovePending: Bool { false }

    func finishMove(pin: String) async throws -> UnlockAttempt {
        try await lock()
        return try await unlock(pin: pin, approve: nil, cancelRecovery: false)
    }

    var finishingMove: Bool { false }
    var finishMoveFailure: FailureKind? { nil }
    func acknowledgeFinishMoveFailure() {}
    var movedBack: Bool { false }
    func acknowledgeMovedBack() {}
    var moveNotDone: Bool { false }
    func acknowledgeMoveNotDone() {}
    var rotateOffered: Bool { false }
    func dismissRotateOffer() {}
    var movedAway: Bool { false }
    func acknowledgeMovedAway() {}

    func unlockCancellingRecovery(pin: String, password: String, approve: ReleaseView?) async throws -> UnlockAttempt {
        try await unlock(pin: pin, approve: approve, cancelRecovery: true)
    }

    func unlockWithCheck(pin: String, password: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        try await unlock(pin: pin, approve: approve, cancelRecovery: cancelRecovery)
    }

    // Kotlin's default arguments.

    func unlock(pin: String, approve: ReleaseView? = nil) async throws -> UnlockAttempt {
        try await unlock(pin: pin, approve: approve, cancelRecovery: false)
    }

    func unlockCancellingRecovery(pin: String, password: String) async throws -> UnlockAttempt {
        try await unlockCancellingRecovery(pin: pin, password: password, approve: nil)
    }

    func unlockWithCheck(pin: String, password: String) async throws -> UnlockAttempt {
        try await unlockWithCheck(pin: pin, password: password, approve: nil, cancelRecovery: false)
    }
}

/// The Protean Credential (VAULT-MESSAGING §3.5): status, unlock window, password, rotation, backup, clone alarms.
/// Mirrors vettid-android `CredentialRepository`.
@MainActor
public protocol CredentialRepository: AnyObject, Observable, Sendable {
    /// The open clone alarm, if any (§3.5.9).
    var alarm: CredentialAlarm? { get }

    /// Until when the unlock window is open (§3.5.3), as this app opened it.
    var unlockWindow: Date? { get }

    func status() async throws -> CredentialStatus

    func openUnlockWindow(password: String) async throws

    func closeUnlockWindow() async throws

    func changePassword(_ password: String, newPassword: String) async throws

    /// (Release R, §11.14.9) With the PIN, which the vault verifies; the change closes the recovery generation. Default:
    /// the change without it.
    func changePassword(_ password: String, newPassword: String, pin: String?) async throws

    func rotate(password: String) async throws

    /// A new credential (`credential.reset`, §3.5.5): the PIN, the current password and the new one. Every critical item
    /// is destroyed. Refused while the vault is held; restarts the owner-check clock.
    func newCredential(pin: String, password: String, newPassword: String) async throws

    func setBackup(_ on: Bool) async throws

    func setUnlockTtl(seconds: Int) async throws

    /// Answers the alarm: [mine] = "that was me" (§3.5.9). Either way a rotation follows.
    func confirmAlarm(mine: Bool) async throws
}

public extension CredentialRepository {
    func changePassword(_ password: String, newPassword: String, pin: String?) async throws {
        try await changePassword(password, newPassword: newPassword)
    }
}

/// Moving the vault to another phone (VAULT-MESSAGING §11.11 recovery, §6.7.1 direct transfer), on both phones.
/// Mirrors vettid-android `MoveRepository`.
@MainActor
public protocol MoveRepository: AnyObject, Sendable {
    // Recovery, on the new phone (§11.11).

    /// Where a recovery on this phone stands.
    func recoveryStage() async throws -> RecoveryStage

    /// Claims the recovery of the portal's QR with this phone's app key (§11.11.7), then registers this phone with its
    /// code (§11.11.3), attested.
    func registerRecovery(_ code: RecoveryCode) async throws -> RecoveryRegistration

    /// The same for a typed code (§11.11.10), whose check characters already matched this app's member API origin:
    /// claims by its locator, takes the vault and the recovery from the answer, and then registers exactly as
    /// ``registerRecovery(_:)`` does for the scanned QR of that recovery.
    func registerTypedRecovery(_ typed: TypedRecoveryCode) async throws -> RecoveryRegistration

    /// The release check before the PIN (§11.10.6), as for an unlock.
    func recoveryPreflight() async throws -> PreflightInfo

    /// Unlocks with the PIN (§11.11.5 step 1) and runs the first handshake (step 2).
    func recoveryUnlock(pin: String, approve: ReleaseView?) async throws -> UnlockAttempt

    /// Whether the vault keeps a copy of the credential, from this phone's recovery unlock (`credential_backup`,
    /// §11.11.5 step 1): true, the password recovers it; false, the vault cannot be recovered; nil, the vault did not
    /// say: ask.
    func recoveryCredentialBackup() async throws -> Bool?

    /// Forgets this phone's recovery registration and device state, so that a new recovery code, a setup code or a
    /// transfer starts afresh: when the vault cannot be recovered (`no_backup`), and when the member starts over from
    /// the PIN or password step. The recovery itself is not cancelled by this: the app has no such call (§11.11.4).
    func abandonRecovery() async throws

    /// `credential.recover` with the password (§11.11.5 step 3).
    func recoverCredential(password: String) async throws -> RecoverOutcome

    // Direct transfer, the new phone (§6.7.1).

    /// Starts the transfer from the old phone's code ([code]: the scanned QR or a pasted link) and returns the SAS once
    /// the handshake checked out. Without the vault's `hs.resp` within ``MoveCodes/hsRespWait``, drops the transfer and
    /// fails with ``FailureKind/noResponse`` and ``MoveCodes/hsUnanswered``.
    func transferIn(code: String) async throws -> String

    /// Waits for the old phone's approval, then takes the credential over (`credential.get`, `credential.ack`,
    /// `credential.utk.get`). ``FailureKind/rejected`` when the owner rejected it; ``FailureKind/noResponse`` after 10
    /// minutes. True when the vault gave this phone the member's `user_guid` (§6.7.1), which its unlocks need; false from
    /// a vault release that does not: the transfer is complete, but this phone cannot unlock the vault once it locks.
    func awaitTransferIn() async throws -> Bool

    /// Drops a transfer this phone started and has not completed.
    func abandonTransferIn() async throws

    // Direct transfer, the old phone (§6.7.1).

    /// `device.transfer.create`.
    func transferCreate() async throws -> TransferOfferView

    /// Waits until [until] for the new phone's `device.transfer.pending`; nil when the code expired first.
    func awaitTransferPending(transferID: String, until: Date) async throws -> TransferPendingView?

    /// Approves with the PIN and the password (§6.7.1 step 3), then waits a little for the vault's
    /// `device.unlinked{transferred}`, which erases this phone (the app is then signed out, as freshly installed). True
    /// when that happened; false when the notice has not arrived yet (it wipes when it does).
    func transferApprove(transferID: String, pin: String, password: String, signer: String?) async throws -> Bool

    func transferReject(transferID: String) async throws

    /// (Release R, §11.14.6) Opens the registered recovery with the PIN and the password together and this phone's
    /// unlock secret. On `ok` the phone becomes the vault's app (its first handshake and the credential follow) and the
    /// app opens; every other answer is the table of ANDROID-PLAN 0.1.40. Default: ``FailureKind/notSupported``.
    func recoveryOpen(pin: String, password: String) async throws -> RecoveryOpenOutcome

    /// (Release R) The vault answered `ok` to this phone's open, which has not finished opening it yet:
    /// ``recoveryOpen(pin:password:)`` then finishes that recovery with the PIN and sends no new open, and
    /// ``abandonRecovery()`` is refused (``MoveCodes/recoveryOpened``). Default: false.
    func recoveryOpened() async throws -> Bool

    /// (Release R) The attempts used of the registered recovery as last reported (also after a restart); nil before.
    var recoveryAttemptsUsed: Int? { get }

    /// (Release R, §11.14.6 "A lost ok") The open's answer never arrived or could not be read: an unlock with the PIN and
    /// this phone's secret; when its result carries the vault's bundle the recovery completed and is finished here
    /// (handshake again, credential). No attempt is used. Default: ``FailureKind/notSupported``.
    func resumeLostOk(pin: String) async throws -> RecoveryOpenOutcome

    /// (Release R) After an `ok` ``recoveryOpen(pin:password:)`` the member has read: the app opens.
    func finishRecoveryOpen() async throws
}

public extension MoveRepository {
    func abandonRecovery() async throws {}
    func recoveryOpen(pin: String, password: String) async throws -> RecoveryOpenOutcome { throw VaultFailure(.notSupported) }
    func recoveryOpened() async throws -> Bool { false }
    var recoveryAttemptsUsed: Int? { nil }
    func resumeLostOk(pin: String) async throws -> RecoveryOpenOutcome { throw VaultFailure(.notSupported) }
    func finishRecoveryOpen() async throws {}

    // Kotlin's default arguments.

    func recoveryUnlock(pin: String) async throws -> UnlockAttempt { try await recoveryUnlock(pin: pin, approve: nil) }

    func transferApprove(transferID: String, pin: String, password: String) async throws -> Bool {
        try await transferApprove(transferID: transferID, pin: pin, password: password, signer: nil)
    }
}

/// ``MoveRepository``'s constants (vettid-android `MoveRepository.Companion`).
public enum MoveCodes {
    /// (Release R) ``MoveRepository/abandonRecovery()`` after the vault made this phone its app: never; the phone key
    /// stays.
    public static let recoveryOpened = "recovery_opened"

    /// How long the new phone waits for the vault's `hs.resp` after its transfer `hs.init` (VAULT-MESSAGING §6.7.1 step
    /// 2, a SHOULD): the vault answers at once, but never a dropped `hs.init` (a spent or expired code, a failed
    /// attestation).
    public static let hsRespWait: Duration = .seconds(60)

    /// ``MoveRepository/transferIn(code:)``'s ``FailureKind/noResponse`` code when no `hs.resp` came within
    /// ``hsRespWait``.
    public static let hsUnanswered = "hs_unanswered"
}
