import Foundation

// The models of a move (``MoveRepository``): recovery on a new phone (VAULT-MESSAGING §11.11) and direct transfer
// (§6.7.1). Mirrors the last part of vettid-android `core/data` `vault/Models.kt`.

/// Where a recovery on this phone stands (it survives restarts). Mirrors vettid-android `RecoveryStage`.
public enum RecoveryStage: Equatable, Sendable, CaseIterable {
    /// Not registered yet: scan or type the code.
    case code
    /// Registered (§11.11.3): unlock with the PIN.
    case pin
    /// Unlocked and paired as a restricted app: the credential password (§11.11.5).
    case password
}

/// `vault.recovery.register`'s answer (VAULT-MESSAGING §11.11.3), or the member API's gate before it. Mirrors
/// vettid-android `RecoveryRegistration`.
public enum RecoveryRegistration: Equatable, Sendable {
    /// Claimed and registered: [emailHint] names the account the vault belongs to (§11.11.7).
    case registered(emailHint: String)
    /// Refused: [code] is the enclave's (`no_recovery`, `used`, `expired`, `too_early`, `bad_code`, `attestation`,
    /// `bad_request`, `retry`), `not_available` (the API's `409 recovery_not_available`, at the claim or the register)
    /// or `no_recovery` (the claim's `404`: the QR, or a typed code's locator, does not name a vault's current
    /// recovery). [recoveryID] is the recovery a typed code's claim named (§11.11.10), so that wrong codes are counted
    /// per recovery however they were read; nil when the claim did not answer with one.
    case refused(code: String, recoveryID: String? = nil)
}

/// `credential.recover`'s outcome (VAULT-MESSAGING §11.11.5). Mirrors vettid-android `RecoverOutcome`.
public enum RecoverOutcome: Equatable, Sendable, CaseIterable {
    /// The credential was handed over: this phone holds the vault; the old app is removed.
    case recovered
    /// The vault keeps no backup copy of its credential (`no_backup`, or an older vault's `credential_lost`): it cannot
    /// be recovered; it can only be deleted on the account site and replaced.
    case noBackup
    /// `credential_required`: the vault has no credential (should not happen past enrollment).
    case credentialRequired
}

/// A pending start-over (VAULT-MESSAGING §11.11.9): the vault is deleted at [deletesAt] unless cancelled. [executing]:
/// too late to cancel. [deletionID]: the API's id when the status names it (needed to cancel in the app). Mirrors
/// vettid-android `DeletionView`.
public struct DeletionView: Equatable, Sendable {
    public var deletesAt: Date
    public var executing: Bool
    public var deletionID: String?

    public init(deletesAt: Date, executing: Bool, deletionID: String?) {
        self.deletesAt = deletesAt
        self.executing = executing
        self.deletionID = deletionID
    }

    public var cancellable: Bool { !executing && deletionID != nil }
}

/// A direct transfer the old phone opened (`device.transfer.create`, VAULT-MESSAGING §6.7.1). Mirrors vettid-android
/// `TransferOfferView`.
public struct TransferOfferView: Equatable, Sendable {
    public var transferID: String
    /// The QR content: the compact JSON pairing payload (§6.4).
    public var qrPayload: String
    /// The same code as a link, for pasting.
    public var link: String
    public var expiresAt: Date

    public init(transferID: String, qrPayload: String, link: String, expiresAt: Date) {
        self.transferID = transferID
        self.qrPayload = qrPayload
        self.link = link
        self.expiresAt = expiresAt
    }
}

/// `device.transfer.pending` (VAULT-MESSAGING §6.7.1): the new phone's handshake checked out. (§11.7.1) [signer]: the
/// attested class of the new app's signer as the vault named it (nil: an older vault, or not an Android app);
/// [signerChanged]: it differs from the signer the vault is bound to, so the member confirms the change before the PIN
/// and the approval names [signer]; [currentSigner]: this app's own signer, for that confirmation's text (nil when it
/// could not be read). Mirrors vettid-android `TransferPendingView`.
public struct TransferPendingView: Equatable, Sendable {
    public var transferID: String
    public var name: String
    public var sas: String
    public var signer: String?
    public var signerChanged: Bool
    public var currentSigner: SignerClass?

    public init(
        transferID: String,
        name: String,
        sas: String,
        signer: String? = nil,
        signerChanged: Bool = false,
        currentSigner: SignerClass? = nil
    ) {
        self.transferID = transferID
        self.name = name
        self.sas = sas
        self.signer = signer
        self.signerChanged = signerChanged
        self.currentSigner = currentSigner
    }
}
