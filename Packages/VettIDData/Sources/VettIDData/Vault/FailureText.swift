import Foundation

// The member-facing texts of failures and of named limits (the package's strings `data_failure_*` and `data_limit_*`).
// Mirrors vettid-android `core/data` `vault/FailureText.kt`.

public extension FailureKind {
    /// The member-facing message of this failure. Mirrors vettid-android `FailureKind.messageRes`.
    var message: String {
        switch self {
        case .network: DataStrings.failureNetwork
        case .unauthorized: DataStrings.failureUnauthorized
        case .setupCodeInvalid: DataStrings.failureSetupCode
        case .termsRequired: DataStrings.failureTerms
        case .rateLimited: DataStrings.failureRateLimited
        case .vaultUnavailable: DataStrings.failureVaultUnavailable
        case .servicePaused: DataStrings.failureServicePaused
        case .releaseEnded: DataStrings.failureReleaseEnded
        case .badPin: DataStrings.failureBadPin
        case .badPassword: DataStrings.failureBadPassword
        case .backoff: DataStrings.failureBackoff
        case .credentialFrozen: DataStrings.failureFrozen
        case .rotationRequired: DataStrings.failureRotationRequired
        case .notSupported: DataStrings.failureNotSupported
        case .noResponse: DataStrings.failureNoResponse
        case .vaultExists: DataStrings.failureVaultExists
        case .attestation: DataStrings.failureAttestation
        case .rollback: DataStrings.failureRollback
        case .manifest: DataStrings.failureManifest
        case .manifestUnavailable: DataStrings.failureManifestUnavailable
        case .releaseUnknown: DataStrings.failureReleaseUnknown
        case .enclave: DataStrings.failureEnclave
        case .notFound: DataStrings.failureNotFound
        case .connectionUnavailable: DataStrings.failureConnectionUnavailable
        case .inviteInvalid: DataStrings.failureInviteInvalid
        case .inviteExpired: DataStrings.failureInviteExpired
        case .inviteNotConnection: DataStrings.failureInviteNotConnection
        case .inviteUnavailable: DataStrings.failureInviteUnavailable
        case .blocked: DataStrings.failureBlocked
        case .credentialLocked: DataStrings.failureCredentialLocked
        case .conflict: DataStrings.failureConflict
        case .limit: DataStrings.failureLimit
        case .inUse: DataStrings.failureInUse
        case .rejected: DataStrings.failureRejected
        case .ownerCheckRequired: DataStrings.failureOwnerCheckRequired
        case .signerRefused: DataStrings.failureSignerRefused
        case .clock: DataStrings.failureClock
        case .noVault: DataStrings.failureNoVault
        case .localState: DataStrings.failureLocalState
        case .eraseFailed: DataStrings.failureEraseFailed
        case .deviceSecret: Self.deviceSecretText(timeScale: 1)
        case .transferIncomplete: DataStrings.failureTransferIncomplete
        case .busy: DataStrings.failureBusy
        case .retry: DataStrings.failureRetry
        case .counterUnavailable: DataStrings.failureCounterUnavailable
        case .storedMismatch: DataStrings.failureStoredMismatch
        case .weakPassword: DataStrings.failureWeakPassword
        case .hardwareKeys: DataStrings.failureHardwareKeys
        case .appleUnreachable: DataStrings.failureAppleUnreachable
        case .phoneLocked: DataStrings.failurePhoneLocked
        case .unconfirmedChanges: DataStrings.failureUnconfirmedChanges
        case .capabilityRollback: DataStrings.failureCapabilityRollback
        case .releaseTooOld: DataStrings.failureReleaseTooOld
        case .enrollmentStarted: DataStrings.failureEnrollmentStarted
        case .responseTooLarge: DataStrings.failureResponseTooLarge
        case .changeUnresolved: DataStrings.failureChangeUnresolved
        case .changeChecking: DataStrings.failureChangeChecking
        case .timeScale: DataStrings.failureTimeScale
        case .other: DataStrings.failureOther
        }
    }

    /// ``message`` at the vault's time scale (STAGING-TIME-SCALE §5.2): the one text that names a scaled wait (a
    /// recovery's time, ``deviceSecret``) says it divided by [timeScale]; every other text is ``message``.
    func message(timeScale: UInt64) -> String {
        self == .deviceSecret ? Self.deviceSecretText(timeScale: timeScale) : message
    }

    /// ``deviceSecret``'s text: a recovery takes from its code delay (24 h) to its quiet period (72 h), at [timeScale].
    private static func deviceSecretText(timeScale: UInt64) -> String {
        DataStrings.failureDeviceSecret(
            TimeScales.text(TimeScales.recoveryDelay, by: timeScale), TimeScales.text(TimeScales.recoveryQuiet, by: timeScale)
        )
    }

    /// The key of ``message`` in `Localizable.xcstrings` (the Android string name).
    var messageKey: String {
        switch self {
        case .network: "data_failure_network"
        case .unauthorized: "data_failure_unauthorized"
        case .setupCodeInvalid: "data_failure_setup_code"
        case .termsRequired: "data_failure_terms"
        case .rateLimited: "data_failure_rate_limited"
        case .vaultUnavailable: "data_failure_vault_unavailable"
        case .servicePaused: "data_failure_service_paused"
        case .releaseEnded: "data_failure_release_ended"
        case .badPin: "data_failure_bad_pin"
        case .badPassword: "data_failure_bad_password"
        case .backoff: "data_failure_backoff"
        case .credentialFrozen: "data_failure_frozen"
        case .rotationRequired: "data_failure_rotation_required"
        case .notSupported: "data_failure_not_supported"
        case .noResponse: "data_failure_no_response"
        case .vaultExists: "data_failure_vault_exists"
        case .attestation: "data_failure_attestation"
        case .rollback: "data_failure_rollback"
        case .manifest: "data_failure_manifest"
        case .manifestUnavailable: "data_failure_manifest_unavailable"
        case .releaseUnknown: "data_failure_release_unknown"
        case .enclave: "data_failure_enclave"
        case .notFound: "data_failure_not_found"
        case .connectionUnavailable: "data_failure_connection_unavailable"
        case .inviteInvalid: "data_failure_invite_invalid"
        case .inviteExpired: "data_failure_invite_expired"
        case .inviteNotConnection: "data_failure_invite_not_connection"
        case .inviteUnavailable: "data_failure_invite_unavailable"
        case .blocked: "data_failure_blocked"
        case .credentialLocked: "data_failure_credential_locked"
        case .conflict: "data_failure_conflict"
        case .limit: "data_failure_limit"
        case .inUse: "data_failure_in_use"
        case .rejected: "data_failure_rejected"
        case .ownerCheckRequired: "data_failure_owner_check_required"
        case .signerRefused: "data_failure_signer_refused"
        case .clock: "data_failure_clock"
        case .noVault: "data_failure_no_vault"
        case .localState: "data_failure_local_state"
        case .eraseFailed: "data_failure_erase_failed"
        case .deviceSecret: "data_failure_device_secret"
        case .transferIncomplete: "data_failure_transfer_incomplete"
        case .busy: "data_failure_busy"
        case .retry: "data_failure_retry"
        case .counterUnavailable: "data_failure_counter_unavailable"
        case .storedMismatch: "data_failure_stored_mismatch"
        case .weakPassword: "data_failure_weak_password"
        case .hardwareKeys: "data_failure_hardware_keys"
        case .appleUnreachable: "data_failure_apple_unreachable"
        case .phoneLocked: "data_failure_phone_locked"
        case .unconfirmedChanges: "data_failure_unconfirmed_changes"
        case .capabilityRollback: "data_failure_capability_rollback"
        case .releaseTooOld: "data_failure_release_too_old"
        case .enrollmentStarted: "data_failure_ios_enrollment_started"
        case .responseTooLarge: "data_failure_response_too_large"
        case .changeUnresolved: "data_failure_change_unresolved"
        case .changeChecking: "data_failure_ios_change_checking"
        case .timeScale: "data_failure_time_scale"
        case .other: "data_failure_other"
        }
    }
}

public extension FailureKind {
    /// ``enrollmentStarted``'s text with the time from which the start-over is possible (iPhone only, no Android text).
    static func enrollmentStartedText(after: Date) -> String {
        DataStrings.failureEnrollmentStartedAfter(after.formatted(date: .abbreviated, time: .shortened))
    }
}

/// A limit's member-facing text: [key] formatted with [args] (counts, or kilobytes for a size; at most two). Mirrors
/// vettid-android `LimitText`.
public struct LimitText: Equatable, Sendable {
    /// The texts of the limits, by their Android string names.
    public enum Key: String, Equatable, Sendable, CaseIterable {
        case failureLimit = "data_failure_limit"
        case items = "data_limit_items"
        case criticalItems = "data_limit_critical_items"
        case itemSize = "data_limit_item_size"
        case itemSizeOf = "data_limit_item_size_of"
        case credentialSize = "data_limit_credential_size"
        case credentialSizeOf = "data_limit_credential_size_of"
        case profileItems = "data_limit_profile_items"
        case profileSize = "data_limit_profile_size"
        case profileSizeOf = "data_limit_profile_size_of"
        case tagRegistry = "data_limit_tag_registry"
        case appSettings = "data_limit_app_settings"
        case shareRulesSubject = "data_limit_share_rules_subject"
        case shareRules = "data_limit_share_rules"
        case sharePending = "data_limit_share_pending"
        case grantsGiven = "data_limit_grants_given"
        case grantRequests = "data_limit_grant_requests"
        case catalogRequests = "data_limit_catalog_requests"
        case grantFetches = "data_limit_grant_fetches"
        case heldApprovals = "data_limit_held_approvals"
        case connectionRequests = "data_limit_connection_requests"
        case blocks = "data_limit_blocks"
        case authChallenges = "data_limit_auth_challenges"
        case agentGrants = "data_limit_agent_grants"
        case criticalUseRequests = "data_limit_critical_use_requests"
        case actionInvocations = "data_limit_action_invocations"
        case introductions = "data_limit_introductions"
        case locationShares = "data_limit_location_shares"
        case locationRequests = "data_limit_location_requests"
        case wallets = "data_limit_wallets"
        case walletAddresses = "data_limit_wallet_addresses"
    }

    public let key: Key
    public let args: [Int64]

    public init(_ key: Key, _ args: [Int64] = []) {
        self.key = key
        self.args = args
    }

    /// How many arguments the text takes.
    public var arity: Int {
        switch key {
        case .failureLimit, .locationRequests: 0
        case .itemSizeOf, .credentialSizeOf, .profileSizeOf: 2
        default: 1
        }
    }

    /// The text with its arguments. Without the arguments it takes (Android throws), the generic "A limit was reached"
    /// text, never a made-up bound.
    public func format() -> String { // swiftlint:disable:this cyclomatic_complexity
        guard args.count >= arity else { return DataStrings.failureLimit }
        let a = args.first ?? 0
        let b = args.count > 1 ? args[1] : 0
        // One text per limit name.
        switch key {
        case .failureLimit: return DataStrings.failureLimit
        case .items: return DataStrings.limitItems(a)
        case .criticalItems: return DataStrings.limitCriticalItems(a)
        case .itemSize: return DataStrings.limitItemSize(a)
        case .itemSizeOf: return DataStrings.limitItemSizeOf(a, b)
        case .credentialSize: return DataStrings.limitCredentialSize(a)
        case .credentialSizeOf: return DataStrings.limitCredentialSizeOf(a, b)
        case .profileItems: return DataStrings.limitProfileItems(a)
        case .profileSize: return DataStrings.limitProfileSize(a)
        case .profileSizeOf: return DataStrings.limitProfileSizeOf(a, b)
        case .tagRegistry: return DataStrings.limitTagRegistry(a)
        case .appSettings: return DataStrings.limitAppSettings(a)
        case .shareRulesSubject: return DataStrings.limitShareRulesSubject(a)
        case .shareRules: return DataStrings.limitShareRules(a)
        case .sharePending: return DataStrings.limitSharePending(a)
        case .grantsGiven: return DataStrings.limitGrantsGiven(a)
        case .grantRequests: return DataStrings.limitGrantRequests(a)
        case .catalogRequests: return DataStrings.limitCatalogRequests(a)
        case .grantFetches: return DataStrings.limitGrantFetches(a)
        case .heldApprovals: return DataStrings.limitHeldApprovals(a)
        case .connectionRequests: return DataStrings.limitConnectionRequests(a)
        case .blocks: return DataStrings.limitBlocks(a)
        case .authChallenges: return DataStrings.limitAuthChallenges(a)
        case .agentGrants: return DataStrings.limitAgentGrants(a)
        case .criticalUseRequests: return DataStrings.limitCriticalUseRequests(a)
        case .actionInvocations: return DataStrings.limitActionInvocations(a)
        case .introductions: return DataStrings.limitIntroductions(a)
        case .locationShares: return DataStrings.limitLocationShares(a)
        case .locationRequests: return DataStrings.limitLocationRequests
        case .wallets: return DataStrings.limitWallets(a)
        case .walletAddresses: return DataStrings.limitWalletAddresses(a)
        }
    }
}

public extension VaultLimit {
    /// The limit names of VAULT-MESSAGING §10.1, as the vault sends them. Mirrors vettid-android `LIMIT_NAMES`.
    static let names: [String] = [
        "items", "critical_items", "item_size", "credential_size", "profile_items", "profile_size", "tag_registry",
        "app_settings", "share_rules_subject", "share_rules", "share_pending", "grants_given", "grant_requests",
        "catalog_requests", "grant_fetches", "held_approvals", "connection_requests", "blocks", "auth_challenges",
        "agent_grants", "critical_use_requests", "action_invocations", "introductions", "location_shares",
        "location_requests", "wallets", "wallet_addresses",
    ]

    /// This limit in the member's words (``text()``, formatted). Mirrors vettid-android `VaultLimit.message`.
    var message: String { text().format() }

    /// A `limit` error in the member's words (VAULT-MESSAGING §10.1): one text per name of the spec's table, with its
    /// bound (``max``; kilobytes for a `*_size` limit, with the refused ``size`` when given). A name this app does not
    /// know, or a limit without its bound, reads as the generic "limit reached". Mirrors vettid-android `VaultLimit.text`.
    func text() -> LimitText { // swiftlint:disable:this cyclomatic_complexity
        guard let m = max else { return LimitText(.failureLimit) }
        let kb = { (b: Int64) -> Int64 in (b + Self.kilobyte - 1) / Self.kilobyte }
        let sized = { (withSize: LimitText.Key, without: LimitText.Key) -> LimitText in
            size.map { LimitText(withSize, [kb($0), kb(m)]) } ?? LimitText(without, [kb(m)])
        }
        let count = { (key: LimitText.Key) in LimitText(key, [m]) }
        // One text per limit name.
        switch name {
        case "items": return count(.items)
        case "critical_items": return count(.criticalItems)
        case "item_size": return sized(.itemSizeOf, .itemSize)
        case "credential_size": return sized(.credentialSizeOf, .credentialSize)
        case "profile_items": return count(.profileItems)
        case "profile_size": return sized(.profileSizeOf, .profileSize)
        case "tag_registry": return count(.tagRegistry)
        case "app_settings": return count(.appSettings)
        case "share_rules_subject": return count(.shareRulesSubject)
        case "share_rules": return count(.shareRules)
        case "share_pending": return count(.sharePending)
        case "grants_given": return count(.grantsGiven)
        case "grant_requests": return count(.grantRequests)
        case "catalog_requests": return count(.catalogRequests)
        case "grant_fetches": return count(.grantFetches)
        case "held_approvals": return count(.heldApprovals)
        case "connection_requests": return count(.connectionRequests)
        case "blocks": return count(.blocks)
        case "auth_challenges": return count(.authChallenges)
        case "agent_grants": return count(.agentGrants)
        case "critical_use_requests": return count(.criticalUseRequests)
        case "action_invocations": return count(.actionInvocations)
        case "introductions": return count(.introductions)
        case "location_shares": return count(.locationShares)
        case "location_requests": return LimitText(.locationRequests)
        case "wallets": return count(.wallets)
        case "wallet_addresses": return count(.walletAddresses)
        default: return LimitText(.failureLimit)
        }
    }

    private static let kilobyte: Int64 = 1024
}
