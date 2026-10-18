import Foundation
import VettIDVault

/// Why an action failed, for the UI (``FailureText``). Mirrors vettid-android `FailureKind`.
public enum FailureKind: Equatable, Sendable, CaseIterable {
    case network
    case unauthorized
    /// A setup code the member API refused (`404 invalid_code`: wrong, expired, used, or another email's).
    case setupCodeInvalid
    case termsRequired
    case rateLimited
    case vaultUnavailable
    /// The operator paused the vault service (MEMBER-API 1.2.0, `503 vault_unavailable` with `service: "paused"`):
    /// temporary, try again after the failure's `retryAfterSeconds`. Members see only the generic text.
    case servicePaused
    case releaseEnded
    case badPin
    case badPassword
    case backoff
    case credentialFrozen
    case rotationRequired
    case notSupported
    case noResponse
    case vaultExists
    /// The vault refused this PHONE's attestation (the `attestation` result of an enrollment or an unlock).
    case attestation
    case rollback
    /// (VAULT-MESSAGING §11.10.9) The vault's instance lacks `recovery_r` although this phone has seen release R for
    /// the vault: refused like a rollback, nothing sent.
    case capabilityRollback
    /// (iPhone, IOS-PLAN ID8) The vault's instance lacks `recovery_r` (VAULT-MESSAGING §11.10.9): the iPhone app supports
    /// only vaults of release R, so nothing is sent to it. Temporary: the vault's release is updated.
    case releaseTooOld
    /// (iPhone) A start-over, or another vault's setup code, refused while this phone may already have set up a vault
    /// (an enrollment whose outcome is not known): its keys are kept. ``VaultFailure/retryAfterSeconds`` says when the
    /// start-over becomes possible, when that is known.
    case enrollmentStarted
    /// The release manifest did not verify (signature, key, format, serial), or the vault refused the app's.
    case manifest
    /// The release manifest could not be loaded (the server answered, but not with the document).
    case manifestUnavailable
    /// The vault runs a release that is not in the manifest this app trusts (VAULT-MESSAGING §11.10.1: "absent from the
    /// manifest is unknown: apps refuse to send it a PIN"). Every try loads the manifest again.
    case releaseUnknown
    /// The ENCLAVE's attestation document or descriptor did not verify: nothing was sent to it.
    case enclave
    case notFound
    case connectionUnavailable
    case inviteInvalid
    case inviteExpired
    case inviteNotConnection
    case inviteUnavailable
    case blocked
    case credentialLocked
    case conflict
    case limit
    /// A tag a share rule names cannot be deleted or merged (`in_use`, VAULT-MESSAGING §10.8).
    case inUse
    /// The vault is past its owner-check deadline (`owner_check_required`, VAULT-MESSAGING §3.6.3): nothing but the
    /// check until it passes. What the member entered stays; the check follows when they leave the screen.
    case ownerCheckRequired
    /// The owner rejected this phone's transfer on their old phone (`device.pair.rejected`, VAULT-MESSAGING §6.7).
    case rejected
    /// The vault's release does not accept this installation's signer (`signer_refused`, VAULT-MESSAGING §11.7.1): not a
    /// wrong PIN, nothing counted; the app is updated, or the vault recovered with a current one.
    case signerRefused
    /// The member API refused this phone's requests (`401`) and its answer shows the phone's clock to be more than a
    /// few minutes off: the cause is the date and time, not a key the vault no longer has.
    case clock
    /// The member API said, explicitly, that the account has no vault (`"vault": null`): after a vault was deleted or
    /// an account closed, but also in a fault of the service. Never acted on by itself: the member decides whether this
    /// phone starts over.
    case noVault
    /// What this phone stores for the vault (its keys and device state, the account record) cannot be read. Nothing is
    /// reset by itself: the member tries again or erases the phone.
    case localState
    /// A wipe of this phone did not finish, or could not start: the old vault's keys may still be here. Nothing is
    /// enrolled and no session opens until a wipe finishes ("Try again" runs it again).
    case eraseFailed

    // Release R (VAULT-MESSAGING §11.14; ANDROID-PLAN 0.1.40).

    /// This phone no longer holds the vault's keys: `device_secret` at the next epoch too, or the phone key is gone.
    case deviceSecret
    /// The move to this phone did not finish (`transfer_incomplete`): the old phone approves it again.
    case transferIncomplete
    /// The service is busy (`busy`, the heavy-derivation permit): nothing was used or changed; try again in a minute.
    case busy
    /// The service was too slow (`retry`): nothing was used or changed; try again.
    case retry
    /// The attempt record cannot be reached (`counter_unavailable`): nothing was used or changed.
    case counterUnavailable
    /// The vault's stored data could not be opened (`stored_mismatch`): contact VettID.
    case storedMismatch
    /// The new password breaks a rule (`weak_password`); the reason is ``VaultFailure/weakPasswordReason``.
    case weakPassword
    /// The phone cannot keep its keys in secure hardware: no enrollment, transfer to it or recovery.
    case hardwareKeys
    /// (iPhone, IOS-PLAN §6.3) The iPhone is locked, or has not been unlocked since it started, so its keys or records
    /// cannot be used now: temporary, never "this phone no longer holds the keys". Every key and record is kept; the
    /// member unlocks the iPhone and tries again.
    case phoneLocked
    /// (iPhone, IOS-PLAN §6.3) Four changes of the phone secret are unconfirmed: a new `pin.change` or
    /// `vault.secret.renew` is refused before anything is sent until an unlock confirms one.
    case unconfirmedChanges
    /// The vault's answer was too large to send to this phone (`response_too_large`, VAULT-MESSAGING §8.1): an answer
    /// is never silence. Nothing changed; a list asked for again in smaller pages may fit.
    case responseTooLarge
    case other
}

/// A failed action: [kind] for the UI, [code] the spec's or API's code; [limit] the limit a `limit` error names
/// (VAULT-MESSAGING §10.1), nil from an older vault. Mirrors vettid-android `VaultFailure`.
public struct VaultFailure: Error, Sendable, CustomStringConvertible {
    public let kind: FailureKind
    public let code: String?
    public let retryAfterSeconds: Int64
    public let cause: (any Error)?
    public let limit: VaultLimit?

    public init(
        _ kind: FailureKind,
        code: String? = nil,
        retryAfterSeconds: Int64 = 0,
        cause: (any Error)? = nil,
        limit: VaultLimit? = nil
    ) {
        self.kind = kind
        self.code = code
        self.retryAfterSeconds = retryAfterSeconds
        self.cause = cause
        self.limit = limit
    }

    public var description: String {
        "\(kind)" + (code.map { " (\($0))" } ?? "") + (limit.map { " [\($0.name)]" } ?? "")
    }

    /// `weak_password`'s `reason` (VAULT-MESSAGING §11.14.7): `short`, `repeated`, `common`, `same_as_pin` or
    /// `guessable`, from the vault's error body.
    public var weakPasswordReason: String? {
        guard let body = (cause as? VaultOpError)?.body else { return nil }
        return VaultJSON.string(VaultJSON.object(body), "reason")
    }
}

/// The limit a `limit` error names (VAULT-MESSAGING §10.1: `{limit, max, size?}`): [name] one of the spec's table (a
/// name this app does not know reads as a generic "limit reached"), [max] the bound (a count, or bytes for a `*_size`
/// limit), [size] for a size limit the size the refused request would have reached. Mirrors vettid-android
/// `VaultLimit`.
public struct VaultLimit: Equatable, Sendable {
    public var name: String
    public var max: Int64?
    public var size: Int64?

    public init(_ name: String, max: Int64? = nil, size: Int64? = nil) {
        self.name = name
        self.max = max
        self.size = size
    }
}
