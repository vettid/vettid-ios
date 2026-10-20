import Foundation
import VettIDData

/// A message under the PIN. Mirrors vettid-android `UnlockMessage`.
public enum UnlockMessage: Equatable, Sendable {
    case badPin
    case updateRefused(code: String)
    case failed(FailureKind, code: String?)
    /// (Release R, §11.14.10) "The move didn't finish" failed: this old phone could not open the vault with its own keys
    /// after approving a transfer.
    case moveBackFailed
}

public extension UnlockMessage {
    /// Failures that say nothing about this phone's keys (the network, the service): never "the move back failed", and
    /// they keep the keys-gone offer as it was.
    static let transientFailures: Set<FailureKind> = [
        .network, .servicePaused, .vaultUnavailable, .noResponse, .rateLimited, .busy, .retry, .clock, .manifestUnavailable,
        // iPhone (IOS-PLAN §6.3): a locked iPhone says nothing about the keys either, nor does Apple unreachable (§6.2).
        .phoneLocked, .appleUnreachable,
    ]

    /// The message of a failed unlock: on an old phone that keeps its keys after approving a transfer ([keptTransfer])
    /// any failure that is not temporary means its own keys no longer open the vault.
    static func of(_ kind: FailureKind, code: String?, keptTransfer: Bool) -> UnlockMessage {
        keptTransfer && !transientFailures.contains(kind) ? .moveBackFailed : .failed(kind, code: code)
    }
}

/// The unlock screen's state. The PIN is here only from the member's "Unlock" until the answer (kept through a recovery
/// pending, so that "Cancel the recovery and unlock" can send it again); the password only until the unlock and its check.
/// Never printed: the description names no secret. Mirrors vettid-android `UnlockUiState`.
public struct UnlockState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let minPinLength = 4
    public static let maxPin = 32
    /// The unlock result this phone could not read (``VaultFailure`` code).
    public static let codeUnreadable = "unreadable_result"

    public var loading = true
    /// (Release R, §11.14.10) This phone approved a transfer and keeps the keys until the new phone finished the move.
    public var keptTransfer = false
    public var email: String?
    public var preflight: PreflightInfo?
    public var preflightError: FailureKind?
    /// The member read the "vault software was updated" notice (§11.10.6).
    public var updateAcknowledged = false
    /// The member approves the offered release with this unlock (§11.10.3).
    public var approveOffer = false
    /// (§11.14.9) A PIN or password change is undecided: the approval is not offered, and none goes with the unlock.
    public var updateHeld = false
    /// What's new in the offered release; nil while it loads (or without an offer). Never gates the unlock.
    public var notes: ReleaseNotes?
    public var pin = ""
    public var busy = false
    public var message: UnlockMessage?
    /// Seconds until the enclave's backoff allows another try (§11.8).
    public var waitSeconds: Int64 = 0
    /// Seconds until the paused vault service asked to be tried again (MEMBER-API 1.2.0). Nothing retries by itself.
    public var serviceWaitSeconds: Int64 = 0
    public var recoveryPending = false
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale: the screen's waits are shown divided by it.
    public var timeScale: UInt64 = 1
    public var stateRollback = false
    /// `signer_refused` (§11.7.1): a state of its own, not a wrong PIN.
    public var signerRefused = false
    public var signerHelp = false
    /// The last result was unreadable, as a phone the vault no longer knows sees it (§11.4): the erase is offered.
    public var notRecognised = false
    /// This phone no longer holds the vault's keys (`device_secret`): recover-or-erase is offered.
    public var keysGone = false
    /// (iPhone, IOS-PLAN §6.3 item 5) With ``keysGone``: a replaced phone-secret record exists, and the member may try it.
    public var earlierSecret = false
    /// The open app was sent here because the relay kept refusing this phone's messages to the vault.
    public var refused = false
    /// The lock the member asked for (``LockNotice``).
    public var lock: LockNotice = .none
    public var eraseConfirm = false
    public var erasing = false
    /// The vault is past its owner-check deadline (§3.6.5): the password is asked for with the PIN (from the owner check).
    public var checkDue = false
    public var password = ""
    /// The vault locked after ten failed checks (§3.6.4; from the owner check).
    public var lockedByOwnerCheck = false
    /// (Release R) The vault has a phone secret: cancelling a recovery from here sends the owner check at once.
    public var phoneSecret = false
    /// (Release R, §11.14.10) Why the last "Finish the move" did not open the vault.
    public var moveFailure: FailureKind?
    /// (VAULT-MESSAGING §11.14.9 "A lost answer" step 5) Which PIN is asked for: while a PIN change is unresolved, the
    /// previous PIN, then the new one after the vault showed that it holds the change.
    public var pinStep: UnlockPinStep = .pin
    /// (IOS-PLAN §4.3) The unconfirmed move this phone knows of; with `failed`, "Return to release N" is offered.
    public var moveUnconfirmed: UnconfirmedMove?
    /// "Return to release N?" is asked.
    public var returnConfirm = false
    /// The member confirmed the way back without a PIN on the keypad: the keypad asks for it, and the primary action
    /// sends it to the way back.
    public var returnAsksPin = false

    public init(loading: Bool = true, email: String? = nil, phoneSecret: Bool = false) {
        self.loading = loading
        self.email = email
        self.phoneSecret = phoneSecret
    }

    /// "Cancel the recovery and unlock" may be pressed: with a phone secret, once the password is entered.
    public var cancelAllowed: Bool { recoveryPending && !busy && (!phoneSecret || !password.isEmpty) }

    /// The vault cannot be opened from here and erasing this phone would not help: an ended release, or a rollback of
    /// the release or of the vault's state. "Recover your vault" and support only.
    public var recoverOnly: Bool { preflightError == .releaseEnded || preflight?.rollback == true || stateRollback }

    /// "Erase VettID from this phone" is offered: never on a ``recoverOnly`` screen, which wins.
    public var eraseOffered: Bool { !recoverOnly && (notRecognised || keysGone) }

    /// Whether "Try again" (after a failed release check) may be pressed now.
    public var retryAllowed: Bool { serviceWaitSeconds == 0 && !loading }

    /// (IOS-PLAN §4.3 point 3) "Return to release N" is offered: the marker of an unconfirmed move has `failed`.
    public var returnOffered: Bool { moveUnconfirmed?.failed == true && !recoveryPending }

    /// Whether the PIN may be entered and sent now: never while the last check of the vault's software failed (except for
    /// the way back, which does not go to the routed release).
    public var pinAllowed: Bool {
        if returnAsksPin { return waitSeconds == 0 && serviceWaitSeconds == 0 && !busy }
        guard let p = preflight, preflightError == nil else { return false }
        return !p.rollback && (!p.softwareUpdated || updateAcknowledged) && waitSeconds == 0 && serviceWaitSeconds == 0 && !busy
    }

    /// Whether the unlock may be sent: a PIN, and with a check due, the password too.
    public var submitAllowed: Bool { pinAllowed && pin.count >= Self.minPinLength && (!checkDue || !password.isEmpty) }

    /// The PIN field is shown: the vault's software verified, nothing blocking, no recovery pending.
    public var showsPin: Bool { returnAsksPin || (!recoverOnly && !recoveryPending && preflight != nil && preflightError == nil) }

    /// A recovery's delay at the vault's time scale ("24 hours"; on staging "1 hour").
    public var recoveryText: String { TimeScales.text(TimeScales.recoveryDelay, by: timeScale) }
    /// How long the old phone keeps its keys after a transfer, at the vault's time scale ("7 days"; on staging "7 hours").
    public var keptTransferText: String { TimeScales.text(TimeScales.oldPhoneKeep, by: timeScale) }
    /// "Staging: 1 day = 1 hour" on a staging vault; nil otherwise.
    public var stagingNote: String? { TimeScales.stagingNote(timeScale) }

    public var description: String {
        "UnlockState(loading: \(loading), busy: \(busy), message: \(message.map { "\($0)" } ?? "nil"), wait: \(waitSeconds), "
            + "serviceWait: \(serviceWaitSeconds), refused: \(refused), notRecognised: \(notRecognised), erasing: \(erasing))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `m:ss` for a countdown. Mirrors vettid-android `formatWait`.
public func formatWait(_ seconds: Int64) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}
