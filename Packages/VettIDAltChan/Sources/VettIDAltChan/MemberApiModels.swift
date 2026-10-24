import Foundation

/// A member API error (MEMBER-API "Conventions", "Vault errors"): [code] is the `error` member (the vault routes repeat
/// it as `code`). Mirrors vettid-android `MemberApiException`.
public struct MemberApiError: Error, Equatable, Sendable, CustomStringConvertible {
    public static let unauthorized = "unauthorized"
    /// Made by the client, never sent by the API: a `401` whose `Date` header is more than ``clockSkewSeconds`` away
    /// from the phone's clock. The API refuses a signature whose `ts` is not within 300 s of its own time with a plain
    /// `401`, so this is the likely cause, not a key the vault no longer has.
    public static let clockSkew = "clock_skew"
    /// Below the API's 300 s, so that a request signed a moment before the answer's `Date` is not missed.
    public static let clockSkewSeconds: TimeInterval = 240
    public static let invalidCode = "invalid_code"
    public static let termsRequired = "terms_required"
    public static let notFound = "not_found"
    public static let instanceMoved = "instance_moved"
    public static let vaultBusy = "vault_busy"
    public static let duplicateRequest = "duplicate_request"
    public static let releaseUnavailable = "release_unavailable"
    public static let releaseStarting = "release_starting"
    public static let vaultUnavailable = "vault_unavailable"
    public static let recoveryActive = "recovery_active"
    public static let recoveryNotAvailable = "recovery_not_available"
    /// 2.1.0: the vault keeps no backup copy of its credential and cannot be recovered.
    public static let recoveryUnavailable = "recovery_unavailable"
    public static let rateLimited = "rate_limited"
    public static let manifestUnavailable = "manifest_unavailable"
    /// `service` of `vault_unavailable` and of `GET /api/vault/status` while the vault service is paused.
    public static let servicePausedValue = "paused"

    public let status: Int
    public let code: String
    public let message: String
    /// `release_starting`: the release being started.
    public let release: String?
    /// `retry_after` from the body, else the `Retry-After` header (seconds; 0 when absent).
    public let retryAfterSeconds: Int
    /// `vault_unavailable`: the body's `service` (1.2.0: `"paused"` while the operator paused the vault service).
    public let service: String?
    /// A `401` whose answer carried a `Date` within ``clockSkewSeconds`` of the phone's clock: the phone's clock does not explain
    /// it, and nothing stripped the header. False for any other error and for a `401` without a usable `Date`.
    public let dateChecked: Bool

    public init(
        status: Int, code: String, message: String = "", release: String? = nil, retryAfterSeconds: Int = 0, service: String? = nil,
        dateChecked: Bool = false
    ) {
        self.dateChecked = dateChecked
        self.status = status
        self.code = code
        self.message = message
        self.release = release
        self.retryAfterSeconds = retryAfterSeconds
        self.service = service
    }

    /// MEMBER-API 1.2.0 "Vault service pause": temporary; try again after ``retryAfterSeconds``. The operator's reason is
    /// never sent to members (and never read here).
    public var servicePaused: Bool { code == Self.vaultUnavailable && service == Self.servicePausedValue }

    public var description: String { "member API \(status) \(code)" + (message.isEmpty ? "" : ": \(message)") }
}

/// A malformed or empty member API answer.
public struct MemberApiMalformed: Error, Equatable, Sendable {
    public let what: String
}

/// `GET /api/vault/enclave`: the instance to seal to (VAULT-MESSAGING §11.2).
public struct EnclaveInfo: Sendable {
    public let instanceID: String
    public let release: String
    public let descriptor: [UInt8]
    public let attestation: [UInt8]
}

/// A response slot (§11.5): `queued`, `done` or `expired`; [envelope] only when done; [code] a host code. Only
/// `etk_unknown` means something to the app (re-seal, §11.9); any other code beside an envelope is ignored and the
/// sealed result decides.
public struct Slot: Sendable {
    public static let queued = "queued"
    public static let done = "done"
    public static let expired = "expired"
    public static let etkUnknown = "etk_unknown"
    /// The host's clear marker on a successful `recovery_register` (0.10.6); the app ignores it.
    public static let recoveryRegistered = "recovery_registered"

    public let status: String
    public let envelope: [UInt8]?
    public let code: String?
}

/// `VaultStatus.release` (MEMBER-API "Vault"): advisory release status and the in-app notice. The app's own decisions
/// come from the signed manifest (§11.10.6); this is for display.
public struct ReleaseInfo: Equatable, Sendable {
    public static let noticeUpdateAvailable = "update_available"
    public static let noticeFinalWarning = "final_warning"
    public static let noticeEnded = "ended"
    public static let noticeRescue = "rescue"
    public static let noticeUnavailable = "unavailable"

    public let number: Int64?
    public let status: String
    public let endsAt: String?
    public let newestActive: Int64?
    public let notice: String?
}

/// `VaultStatus.deletion` (MEMBER-API 2.1.0, `deletion_id` since 2.1.1).
public struct PendingDeletion: Equatable, Sendable {
    public let state: String
    public let deletesAt: String
    public let deletionID: String?
}

/// `GET /api/vault/status`'s vault (advisory, never a security signal).
public struct VaultStatus: Equatable, Sendable {
    public let vaultID: String
    public let state: String
    public let sealedRelease: String?
    public let leased: Bool
    public let alarmKind: String?
    public let recoveryState: String?
    public let recoveryAvailableAt: String?
    /// The sealed release from the routing table; nil while not sealed yet.
    public let release: ReleaseInfo?
    /// 2.1.0: whether the vault keeps a backup copy of its credential (false: it cannot be recovered); nil: not reported.
    public let credentialBackup: Bool?
    /// 2.1.0: a start-over requested on the portal, until it executes or is cancelled.
    public let deletion: PendingDeletion?
}

/// `GET /api/vault/status`: the member's vault (nil without one) and whether the operator paused the vault service.
public struct VaultStatusAnswer: Equatable, Sendable {
    public let vault: VaultStatus?
    public let servicePaused: Bool
}

/// `POST /api/vault/enroll/redeem`'s answer (§11.12.1).
public struct Redeemed: Equatable, Sendable {
    public let vaultID: String
    public let userGuid: String
    public let emailHint: String
}

/// `POST /api/vault/recovery/claim`'s answer (§11.11.7); since MEMBER-API 2.4.0 also the recovery's vault and id.
public struct Claimed: Equatable, Sendable {
    public let userGuid: String
    public let emailHint: String
    public let vaultID: String?
    public let recoveryID: String?
}

/// A sealed request ready to post (§11.3, §11.4, §11.11.3).
public struct SealedRequest: Sendable {
    public let requestID: String
    public let etkKid: String
    public let envelope: [UInt8]
    public let manifestSHA256: String?
    /// The App Attest key id the request's `device_attest` carries (iOS; nil otherwise), for ``Attester/confirm(keyID:)``.
    public let attestedKeyID: [UInt8]?

    public init(requestID: String, etkKid: String, envelope: [UInt8], manifestSHA256: String?, attestedKeyID: [UInt8]? = nil) {
        self.requestID = requestID
        self.etkKid = etkKid
        self.envelope = envelope
        self.manifestSHA256 = manifestSHA256
        self.attestedKeyID = attestedKeyID
    }
}
