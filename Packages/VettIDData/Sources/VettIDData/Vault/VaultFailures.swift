import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDKeys
import VettIDRelay
import VettIDVault

/// Turns every failure of the layers below into a ``VaultFailure`` for the screens. Mirrors vettid-android `vaultGuard`
/// and `VaultManager`'s `memberFailure`, `opFailure` and `enrollFailure`.
enum VaultFailures {
    /// The code of a failure of this phone's stored keys or files: what it stores for the vault could not be read (the
    /// root screen says ``FailureKind/localState``).
    static let codeKeystore = "keystore"

    // swiftlint:disable cyclomatic_complexity
    /// [e] as a ``VaultFailure``; a cancellation stays one.
    static func map(_ e: any Error) -> any Error {
        switch e {
        case let f as VaultFailure: f
        case is CancellationError: e
        case let m as MemberApiError:
            VaultFailure(memberFailure(m), code: m.code, retryAfterSeconds: Int64(m.retryAfterSeconds), cause: m)
        case let o as VaultOpError:
            VaultFailure(opFailure(o.code), code: o.code, retryAfterSeconds: retryAfter(o), cause: o, limit: limit(o))
        case let r as AltRefused: refused(r)
        case let t as TimeScaleRefused: VaultFailure(.timeScale, code: "time_scale", cause: t)
        case let a as AttestationError: VaultFailure(enclaveFailure(a), code: "enclave", cause: a)
        case let r as AltResultFailure: VaultFailure(.other, code: "unreadable_result", cause: r)
        case let c as AltChannelFailure: VaultFailure(.noResponse, cause: c)
        case let s as VaultStateError: VaultFailure(noResponse(s) ? .noResponse : .other, cause: s)
        case let p as PairingRejected: VaultFailure(.rejected, code: "rejected", cause: p)
        case let r as RelayError: VaultFailure(.network, cause: r)
        case let u as URLError: VaultFailure(.network, cause: u)
        case let k as KeysError: keys(k)
        case let a as AppAttestError: appAttest(a)
        case let m as MemberApiMalformed: VaultFailure(.other, code: "malformed", cause: m)
        case let c as CryptoError: VaultFailure(.other, code: "crypto", cause: c)
        default: VaultFailure(.other, cause: e)
        }
    }
    // swiftlint:enable cyclomatic_complexity

    /// A refusal of the app's own rules before anything was sent (§11.10.6, §13.2).
    private static func refused(_ r: AltRefused) -> VaultFailure {
        switch r {
        case .rollbackRelease: VaultFailure(.rollback, code: "rollback_release", cause: r)
        case .notYetRouted: VaultFailure(.vaultUnavailable, code: VaultManager.codeReleaseNotRouted, cause: r)
        case .manifestOlder: VaultFailure(.manifest, code: "manifest_older", cause: r)
        case .notPaired: VaultFailure(.other, code: "not_paired", cause: r)
        }
    }

    /// The keys (IOS-PLAN §6.3): a locked iPhone is temporary and never a loss; no secure hardware refuses before
    /// anything is made or sent; anything else is this phone's stored state.
    private static func keys(_ k: KeysError) -> VaultFailure {
        switch k {
        case .unavailable: VaultFailure(.phoneLocked, code: "phone_locked", cause: k)
        case .noSecureHardware: VaultFailure(.hardwareKeys, code: "secure_hardware", cause: k)
        case .missing, .invalid, .corrupt, .unknownFormat: VaultFailure(.other, code: codeKeystore, cause: k)
        }
    }

    /// App Attest (IOS-PLAN §6.2): Apple unreachable after the retries; the attested key gone at an assertion is "this
    /// phone no longer holds the keys" (``FailureKind/deviceSecret``); any other refusal is tried again.
    private static func appAttest(_ a: AppAttestError) -> VaultFailure {
        switch a {
        case .appleUnreachable: VaultFailure(.appleUnreachable, code: "app_attest_unreachable", cause: a)
        case .keyGone: VaultFailure(.deviceSecret, code: VaultFailure.codeAppAttestKeyGone, cause: a)
        // Temporary: the next enrollment request first forgets the keys no kept request names (``Attester/prune``).
        case .pendingFull: VaultFailure(.retry, code: "app_attest_pending_full", cause: a)
        case .failed: VaultFailure(.other, code: "app_attest", cause: a)
        }
    }

    /// The device client's waits that ran out (an answer, `vault.enrolled`, `device.paired`).
    private static func noResponse(_ s: VaultStateError) -> Bool {
        s.message.contains("no response") || s.message.hasPrefix("no ") && s.message.contains(" within ")
    }

    /// The opened `vault.enroll.result`'s refusal (§11.3).
    static func enrollFailure(_ code: String?) -> FailureKind {
        switch code {
        case "vault_exists": .vaultExists
        case "attestation": .attestation
        case "manifest", "release_key": .manifest
        default: .other
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func memberFailure(_ e: MemberApiError) -> FailureKind {
        switch e.code {
        case MemberApiError.unauthorized: .unauthorized
        case MemberApiError.clockSkew: .clock
        case MemberApiError.invalidCode: .setupCodeInvalid
        case MemberApiError.termsRequired: .termsRequired
        case MemberApiError.rateLimited: .rateLimited
        case MemberApiError.vaultUnavailable: e.servicePaused ? .servicePaused : .vaultUnavailable
        case MemberApiError.releaseStarting: .vaultUnavailable
        case MemberApiError.releaseUnavailable: .releaseEnded
        case MemberApiError.notFound: .notFound
        case MemberApiError.manifestUnavailable: .manifestUnavailable
        default: .other
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func opFailure(_ code: String) -> FailureKind {
        switch code {
        case "bad_pin": .badPin
        case "bad_password": .badPassword
        case "backoff": .backoff
        case "credential_frozen": .credentialFrozen
        case "rotation_required": .rotationRequired
        case "not_found": .notFound
        case "unsupported_type", "ttl_not_allowed": .notSupported
        case "connection_unavailable": .connectionUnavailable
        case "claim_unavailable", "accept_failed": .inviteUnavailable
        case "blocked": .blocked
        case "credential_locked": .credentialLocked
        case "conflict": .conflict
        case "limit": .limit
        case "in_use": .inUse
        case "stale_credential", "utk_invalid": .noResponse
        case "owner_check_required": .ownerCheckRequired
        // Release R (§11.14).
        case "busy": .busy
        case "retry": .retry
        case "counter_unavailable": .counterUnavailable
        case "stored_mismatch": .storedMismatch
        case "weak_password": .weakPassword
        case "device_secret": .deviceSecret
        case "transfer_incomplete": .transferIncomplete
        case "response_too_large": .responseTooLarge
        default: .other
        }
    }

    /// What a failed check of the vault's software means for the member (§11.2, §11.10.1). None of these is
    /// ``FailureKind/attestation``, which is the vault refusing this PHONE's attestation.
    static func enclaveFailure(_ e: AttestationError) -> FailureKind {
        if case .release(_, unknown: true) = e { return .releaseUnknown }
        return e.isManifest ? .manifest : .enclave
    }

    /// A vault error's `retry_after` (§10.1, 0.17.0): 0 when absent or not a positive integer.
    static func retryAfter(_ e: VaultOpError) -> Int64 {
        guard let body = e.body, let n = VaultJSON.int(VaultJSON.object(body), "retry_after"), n > 0 else { return 0 }
        return n
    }

    /// A `limit` error's limit (§10.1, 0.21.0: `{limit, max, size?}`); nil for another error or a body without a name.
    static func limit(_ e: VaultOpError) -> VaultLimit? {
        guard e.code == "limit", let body = e.body else { return nil }
        let o = VaultJSON.object(body)
        guard let name = VaultJSON.string(o, "limit"), !name.isEmpty else { return nil }
        func n(_ k: String) -> Int64? { VaultJSON.int(o, k).flatMap { $0 >= 0 ? $0 : nil } }
        return VaultLimit(name, max: n("max"), size: n("size"))
    }
}

/// Which vaults this app serves (IOS-PLAN ID8; VAULT-MESSAGING §11.10.9): only those whose release lists `recovery_r`.
/// The iPhone app has none of the requests from before release R. Mirrors vettid-android `ReleasePath` without its
/// earlier path.
enum ReleasePath {
    static let codeReleaseTooOld = "release_too_old"

    /// Refuses, before anything is built or sent, an instance (or bundle) whose [capabilities] lack `recovery_r`.
    static func requireR(_ capabilities: [String]) throws {
        guard capabilities.contains(Capabilities.recoveryR) else { throw VaultFailure(.releaseTooOld, code: codeReleaseTooOld) }
    }

    /// Whether recovery is offered: always for a release before R, else only with `recovery_offered`.
    static func recoveryOffered(_ capabilities: [String]) -> Bool {
        !capabilities.contains(Capabilities.recoveryR) || capabilities.contains(Capabilities.recoveryOffered)
    }
}

public extension VaultFailure {
    /// (iPhone, IOS-PLAN §6.2) The attested App Attest key is gone: "this phone no longer holds the keys", which an
    /// earlier phone secret cannot help.
    static let codeAppAttestKeyGone = "app_attest_key_gone"
}
