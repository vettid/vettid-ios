import Foundation

// The models of the repositories (Repositories.swift): what the screens see of the account, the vault, the credential
// and a move. Display models only; the wire models are VettIDVault's and VettIDAltChan's. Mirrors vettid-android
// `core/data` `vault/Models.kt`.

/// Where the app is (the root of the UI follows it). A phone that a transfer or a recovery replaced has no phase of its
/// own: it erases itself and is ``signedOut``, as freshly installed. Mirrors vettid-android `AppPhase`.
public enum AppPhase: Equatable, Sendable {
    /// Reading local state at start.
    case starting
    /// The member API could not be reached at start ([failure] says why). [longUnreachable]: nothing has reached the
    /// vault service from this phone for a long time (vettid-android `StuckScreens.LONG_UNREACHABLE`).
    case unreachable(FailureKind, longUnreachable: Bool = false)
    /// Nothing set up on this phone: the welcome screen (a setup code, a recovery or a transfer). The app never signs in
    /// (VAULT-MESSAGING §11.12); the name is kept from when it did.
    case signedOut
    /// A setup code was redeemed (or a recovery claimed): setting the vault up on this device.
    case setup(SetupStage)
    /// Enrolled; the vault is locked: unlock with the PIN.
    case locked
    /// The vault is open and this app is its holder.
    case unlocked
}

/// The steps of setting a vault up on this phone. Mirrors vettid-android `SetupStage`.
public enum SetupStage: Equatable, Sendable, CaseIterable {
    /// No vault yet: enroll one (PIN, password, backup).
    case newVault
    /// The account has a vault this device does not hold (one app per vault, VAULT-MESSAGING §3.5.9).
    case vaultElsewhere
    /// Enrolled and paired, but the Protean Credential is not created yet (§3.5.7).
    case needsCredential
    /// Everything done; the member has not left the final onboarding screen yet.
    case finishing
    /// This phone is recovering the vault (§11.11): registered with the code, until the credential is recovered or reset.
    case recovering
}

/// The member's account as the vault reports it (VAULT-MESSAGING §11.13): membership, terms and subscription,
/// read-only and display only (changes are made on the account portal). Before the first snapshot only [emailHint] is
/// known (from the setup code's redeem or the recovery's claim). Mirrors vettid-android `AccountInfo`.
public struct AccountInfo: Equatable, Sendable {
    public static let accountCanceled = "canceled"

    /// The masked address, `m***@example.com`.
    public var emailHint: String
    /// `member` or another account state; nil before the vault sent a snapshot.
    public var state: String?
    /// `active` or `canceled`.
    public var accountStatus: String?
    /// When a cancelled account's vault is deleted.
    public var deletesAt: Date?
    public var termsNeedAcceptance: Bool
    public var subscription: SubscriptionInfo?
    public var votingRights: Bool
    public var asOf: Date?
    /// The account's names (§11.13): what every connection sees; nil before a snapshot had them.
    public var firstName: String?
    public var lastName: String?
    /// `name_change.allowed_after`: the next name change is applied only after it; nil: now.
    public var nameAllowedAfter: Date?
    /// The latest name change this app asked for (`account.get`'s `name_request`, §10.8).
    public var nameRequest: NameRequestView?
    /// The member's full address from the snapshot (`email`); nil from an older vault.
    public var email: String?

    public init(
        emailHint: String,
        state: String? = nil,
        accountStatus: String? = nil,
        deletesAt: Date? = nil,
        termsNeedAcceptance: Bool = false,
        subscription: SubscriptionInfo? = nil,
        votingRights: Bool = false,
        asOf: Date? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        nameAllowedAfter: Date? = nil,
        nameRequest: NameRequestView? = nil,
        email: String? = nil
    ) {
        self.emailHint = emailHint
        self.state = state
        self.accountStatus = accountStatus
        self.deletesAt = deletesAt
        self.termsNeedAcceptance = termsNeedAcceptance
        self.subscription = subscription
        self.votingRights = votingRights
        self.asOf = asOf
        self.firstName = firstName
        self.lastName = lastName
        self.nameAllowedAfter = nameAllowedAfter
        self.nameRequest = nameRequest
        self.email = email
    }

    public var hasSnapshot: Bool { state != nil }

    /// The address to show: the full [email] when the snapshot carries it, else the masked [emailHint].
    public var displayEmail: String? {
        if let email, !email.allSatisfy(\.isWhitespace) { return email }
        return emailHint.isEmpty ? nil : emailHint
    }

    /// "First Last" (§10.8); nil before the snapshot carried the names.
    public var fullName: String? { AccountNames.full(firstName, lastName) }

    /// Whether a name change would be refused `too_soon` at [now] (the snapshot's `allowed_after` lies ahead).
    public func nameChangeTooSoon(now: Date) -> Bool { nameAllowedAfter.map { $0 > now } ?? false }

    public var canceled: Bool { accountStatus == Self.accountCanceled }
}

/// The member's subscription (VAULT-MESSAGING §11.13): `trial`, `active`, `expired` or `canceled`. Mirrors
/// vettid-android `SubscriptionInfo`.
public struct SubscriptionInfo: Equatable, Sendable {
    public static let statusTrial = "trial"
    public static let statusActive = "active"
    public static let statusExpired = "expired"
    public static let statusCanceled = "canceled"

    public var typeName: String?
    public var status: String?
    public var paid: Bool
    public var expiresAt: Date?

    public init(typeName: String?, status: String?, paid: Bool, expiresAt: Date?) {
        self.typeName = typeName
        self.status = status
        self.paid = paid
        self.expiresAt = expiresAt
    }

    /// The status to show at [now]: a trial (or any subscription) whose `expires_at` has passed reads `expired`.
    public func status(at now: Date) -> String? {
        if let expiresAt, now >= expiresAt, status != Self.statusCanceled { return Self.statusExpired }
        return status
    }
}

/// A setup code as the member gave it (VAULT-MESSAGING §11.12.1). Never printed. Mirrors vettid-android
/// `SetupCodeInput`.
public enum SetupCodeInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The QR's (or the Universal Link's) 128-bit secret.
    case secret(String)
    /// The typed code (canonical, 8 symbols) with the member's email.
    case typed(email: String, code: String)

    public var description: String {
        switch self {
        case .secret: "Secret(…)"
        case .typed: "Typed(…)"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The enrollment steps the progress screen shows (VAULT-MESSAGING §11.3, §3.5.7). Mirrors vettid-android `EnrollStep`.
public enum EnrollStep: Equatable, Sendable, CaseIterable {
    case enroll, waitForVault, handshake, createCredential, backup, confirm
}

/// A release as the app shows it (VAULT-MESSAGING §11.10.3: number, notes, PCR0 fingerprint). Mirrors vettid-android
/// `ReleaseView`.
public struct ReleaseView: Equatable, Sendable {
    private static let fingerprintHex = 16
    private static let group = 4

    public var number: UInt64
    public var pcr0: String
    public var status: String
    public var endsAt: Date?
    public var notes: String

    public init(number: UInt64, pcr0: String, status: String, endsAt: Date?, notes: String) {
        self.number = number
        self.pcr0 = pcr0
        self.status = status
        self.endsAt = endsAt
        self.notes = notes
    }

    /// The first 16 hex digits of PCR0 in groups of four, for display.
    public var fingerprint: String {
        let hex = Array(pcr0.prefix(Self.fingerprintHex))
        return stride(from: 0, to: hex.count, by: Self.group)
            .map { String(hex[$0..<min($0 + Self.group, hex.count)]) }
            .joined(separator: " ")
    }
}

/// The release check before an unlock (VAULT-MESSAGING §11.10.6). Mirrors vettid-android `PreflightInfo`.
public struct PreflightInfo: Equatable, Sendable {
    public var routed: ReleaseView
    public var lastNumber: UInt64
    /// Newer than the release this device last unlocked into: "vault software was updated".
    public var softwareUpdated: Bool
    /// Older: never send the PIN.
    public var rollback: Bool
    /// The newest active release, newer than the routed one: the member may approve the move.
    public var offer: ReleaseView?
    /// The manifest's releases between the routed one and [offer] (What's new, ANDROID-PLAN 0.1.31).
    public var between: [ReleaseView]

    public init(
        routed: ReleaseView,
        lastNumber: UInt64,
        softwareUpdated: Bool,
        rollback: Bool,
        offer: ReleaseView?,
        between: [ReleaseView] = []
    ) {
        self.routed = routed
        self.lastNumber = lastNumber
        self.softwareUpdated = softwareUpdated
        self.rollback = rollback
        self.offer = offer
        self.between = between
    }
}

/// The outcome of an unlock (VAULT-MESSAGING §11.4). Mirrors vettid-android `UnlockAttempt`.
public enum UnlockAttempt: Equatable, Sendable {
    /// ``failed(_:code:retryAfterSeconds:)``'s code when this phone has no `user_guid` to unlock with: it was set up by
    /// a direct transfer from a vault release whose `device.paired` did not carry one (§6.7.1).
    public static let codeNoUserGuid = "no_user_guid"

    case success
    case badPin(retryAfterSeconds: Int64)
    case backoff(retryAfterSeconds: Int64)
    /// A recovery is in progress and the request did not cancel it (§11.11.4).
    case recoveryPending
    /// The vault's stored state is older than state this device has seen (§13.2).
    case stateRollback
    /// The release update was refused ([code]); the vault stayed where it was.
    case updateRefused(code: String)
    /// `signer_refused` (§11.7.1): the running release does not pin the signer recorded for this installation's key.
    /// Decided before the PIN and the same whatever PIN was sent: not a PIN failure, no backoff, nothing to wait for.
    case signerRefused
    /// [retryAfterSeconds]: when the service said when to try again (`Retry-After`, e.g. ``FailureKind/servicePaused``).
    case failed(FailureKind, code: String?, retryAfterSeconds: Int64 = 0)
}

/// A clone alarm on the Protean Credential (VAULT-MESSAGING §3.5.9). Mirrors vettid-android `CredentialAlarm`.
public struct CredentialAlarm: Equatable, Sendable {
    public static let stateFrozen = "frozen"
    public static let stateRotationRequired = "rotation_required"
    public static let stateResolved = "resolved"

    public var alarmID: String
    /// `frozen` or `rotation_required`.
    public var state: String
    public var at: String?
    /// `holder` or `other`, when the alert said.
    public var presenter: String?

    public init(alarmID: String, state: String, at: String?, presenter: String? = nil) {
        self.alarmID = alarmID
        self.state = state
        self.at = at
        self.presenter = presenter
    }

    public var frozen: Bool { state == Self.stateFrozen }
    public var rotationRequired: Bool { state == Self.stateRotationRequired }
}

/// The credential screen's data (VAULT-MESSAGING §3.5, §10.6, §10.8). Mirrors vettid-android `CredentialStatus`.
public struct CredentialStatus: Equatable, Sendable {
    public var exists: Bool
    public var version: Int64?
    public var keyFingerprint: String?
    public var updatedAt: String?
    public var alarm: CredentialAlarm?
    /// `credential.backup` (§3.5.6).
    public var backup: Bool
    /// `credential.unlock_ttl_seconds` (30–3,600).
    public var unlockTtlSeconds: Int
    public var criticalItems: Int?

    public init(
        exists: Bool,
        version: Int64?,
        keyFingerprint: String?,
        updatedAt: String?,
        alarm: CredentialAlarm?,
        backup: Bool,
        unlockTtlSeconds: Int,
        criticalItems: Int?
    ) {
        self.exists = exists
        self.version = version
        self.keyFingerprint = keyFingerprint
        self.updatedAt = updatedAt
        self.alarm = alarm
        self.backup = backup
        self.unlockTtlSeconds = unlockTtlSeconds
        self.criticalItems = criticalItems
    }
}

/// Vault status for Settings: the member API's advisory status plus the vault's own. Mirrors vettid-android
/// `VaultOverview`.
public struct VaultOverview: Equatable, Sendable {
    public var vaultID: String?
    /// `enrolling`, `locked`, `unlocked` (advisory).
    public var state: String?
    public var release: ReleaseInfoView?
    /// The release this device last unlocked into.
    public var lastRelease: UInt64
    public var recoveryState: String?
    public var provisional: Bool?
    public var devices: Int?
    public var connections: Int?
    /// The vault's signer binding from this app's own `device.list` entry (VAULT-MESSAGING §10.3), for the "Installed
    /// from" line; nil when the vault reports none or is not open.
    public var signer: SignerView?
    /// (Release R, §11.14.11) `vault.status`'s `recovery`; nil from an earlier release.
    public var recovery: RecoveryStatusView?
    /// (§11.10.9) Whether the vault's release offers recovery: false for a release with `recovery_r` and without
    /// `recovery_offered` (recovery is hidden).
    public var recoveryOffered: Bool

    public init(
        vaultID: String?,
        state: String?,
        release: ReleaseInfoView?,
        lastRelease: UInt64,
        recoveryState: String?,
        provisional: Bool?,
        devices: Int?,
        connections: Int?,
        signer: SignerView? = nil,
        recovery: RecoveryStatusView? = nil,
        recoveryOffered: Bool = true
    ) {
        self.vaultID = vaultID
        self.state = state
        self.release = release
        self.lastRelease = lastRelease
        self.recoveryState = recoveryState
        self.provisional = provisional
        self.devices = devices
        self.connections = connections
        self.signer = signer
        self.recovery = recovery
        self.recoveryOffered = recoveryOffered
    }
}

/// `vault.status`'s `recovery` for the status screen (VAULT-MESSAGING §11.14.11): never shown as "0 of 10" when [state]
/// is `unknown`. Mirrors vettid-android `RecoveryStatusView`.
public struct RecoveryStatusView: Equatable, Sendable {
    public var state: String
    public var used: Int?
    public var counterUnavailable: Bool
    /// (§11.14.5) Unavailable at every read for 24 hours: shown with the urgency of a used attempt.
    public var unknownForADay: Bool

    public init(state: String, used: Int?, counterUnavailable: Bool, unknownForADay: Bool = false) {
        self.state = state
        self.used = used
        self.counterUnavailable = counterUnavailable
        self.unknownForADay = unknownForADay
    }
}

/// MEMBER-API `ReleaseInfo` (advisory; the manifest decides). Mirrors vettid-android `ReleaseInfoView`.
public struct ReleaseInfoView: Equatable, Sendable {
    public var number: Int64?
    public var status: String
    public var endsAt: String?
    public var newestActive: Int64?
    public var notice: String?

    public init(number: Int64?, status: String, endsAt: String?, newestActive: Int64?, notice: String?) {
        self.number = number
        self.status = status
        self.endsAt = endsAt
        self.newestActive = newestActive
        self.notice = notice
    }
}

/// A recovery in progress, as `GET /api/vault/status` reports it (`recovery: {state, available_at}`, MEMBER-API).
/// Mirrors vettid-android `RecoveryView`.
public struct RecoveryView: Equatable, Sendable {
    public var state: String
    public var availableAt: String

    public init(state: String, availableAt: String) {
        self.state = state
        self.availableAt = availableAt
    }
}

/// What Settings shows about attestation: this device's key and the enclave last verified. The fields are Android's;
/// on iOS [keyLevel] names the Secure Enclave and the boot fields stay nil (chosen; not in the spec). Mirrors
/// vettid-android `AttestationInfo`.
public struct AttestationInfo: Equatable, Sendable {
    public var environment: String
    public var keyPresent: Bool
    /// Android: `STRONG_BOX`, `TEE`, `SOFTWARE` or `UNKNOWN`.
    public var keyLevel: String?
    public var strongBoxAvailable: Bool
    public var attestationVersion: Int?
    /// Android: `Verified`, `SelfSigned`, `Unverified`, `Failed`.
    public var verifiedBoot: String?
    public var deviceLocked: Bool?
    public var bootKeyFingerprint: String?
    public var lastRelease: UInt64
    public var lastReleaseFingerprint: String?

    public init(
        environment: String,
        keyPresent: Bool,
        keyLevel: String?,
        strongBoxAvailable: Bool,
        attestationVersion: Int?,
        verifiedBoot: String?,
        deviceLocked: Bool?,
        bootKeyFingerprint: String?,
        lastRelease: UInt64,
        lastReleaseFingerprint: String?
    ) {
        self.environment = environment
        self.keyPresent = keyPresent
        self.keyLevel = keyLevel
        self.strongBoxAvailable = strongBoxAvailable
        self.attestationVersion = attestationVersion
        self.verifiedBoot = verifiedBoot
        self.deviceLocked = deviceLocked
        self.bootKeyFingerprint = bootKeyFingerprint
        self.lastRelease = lastRelease
        self.lastReleaseFingerprint = lastReleaseFingerprint
    }
}
