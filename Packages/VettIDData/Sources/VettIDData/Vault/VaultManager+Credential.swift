import Foundation
import VettIDVault

// The credential screen (VAULT-MESSAGING §3.5: status, the unlock window, the password, the backup and the window's
// length) and the PIN change of release R (§11.14.9). Mirrors vettid-android `VaultManager`'s `CredentialRepository`
// part and `changePin`.
extension VaultManager {
    static let keyUnlockTtl = "credential.unlock_ttl_seconds"
    static let defaultUnlockTtl = 300
    /// The unlock window's length bounds (§10.8).
    public nonisolated static let unlockTtlRange = 30...3_600
    /// A page of `item.list` when counting the critical items, and at most this many pages (§10.7: a vault holds at most
    /// 1,000 items).
    static let listPage = 500
    static let maxPages = 4
    /// The key fingerprint shown: its first characters.
    static let keyFingerprintChars = 12
    /// The answer of an operation that needs a phone secret on a phone that holds none.
    public nonisolated static let codeNoPhoneSecret = "no_phone_secret"

    // MARK: - CredentialRepository

    public func status() async throws -> CredentialStatus {
        try await guarded {
            let api = try openApi(try await openSession())
            let info = try await api.credentialVersion()
            let a = info.alarm.flatMap { a in
                a.alarmID.map { CredentialAlarm(alarmID: $0, state: a.state ?? CredentialAlarm.stateFrozen, at: a.at) }
            }
            alarm = a
            let settings = try await api.settingsGet().values
            // The count is display only: without an answer it is shown as unknown.
            let critical = (try? await countCritical(api)) ?? nil
            return CredentialStatus(
                exists: info.exists,
                version: info.version,
                keyFingerprint: info.key.map { String($0.prefix(Self.keyFingerprintChars)) },
                updatedAt: info.updatedAt,
                alarm: a,
                backup: settings[Self.keyBackup].map { $0 != "false" } ?? true,
                unlockTtlSeconds: settings[Self.keyUnlockTtl].flatMap { Int($0) } ?? Self.defaultUnlockTtl,
                criticalItems: critical
            )
        }
    }

    /// Counts the critical items, a page of at most ``listPage`` at a time; nil (unknown) when pages remain after
    /// ``maxPages``.
    private func countCritical(_ api: VaultApi) async throws -> Int? {
        var n = 0
        var after: String?
        for _ in 0..<Self.maxPages {
            let page = try await api.itemCount(sensitivity: "critical", after: after, limit: Self.listPage)
            n += page.count
            guard let next = page.next else { return n }
            after = next
        }
        return nil
    }

    public func openUnlockWindow(password: String) async throws {
        try await guarded {
            let exp = try await openApi(try await openSession()).credentialUnlock(password: password)
            unlockWindow = OwnerCheckManager.instant(exp)
        }
    }

    public func closeUnlockWindow() async throws {
        try await guarded {
            try await openApi(try await openSession()).credentialLock()
            unlockWindow = nil
        }
    }

    /// The password change without the PIN (before release R): the iPhone app serves only vaults of release R
    /// (IOS-PLAN ID8), whose change carries the PIN.
    public func changePassword(_ password: String, newPassword: String) async throws {
        throw VaultFailure(.notSupported, code: ReleasePath.codeReleaseTooOld)
    }

    /// (Release R, §11.14.9) With the PIN, which the vault verifies; the change closes the recovery generation. No answer
    /// (``codeChangeUnanswered``): the vault may have made the change; the next credential operation fetches the rotated
    /// blob (`stale_credential`). The rotation offered after it (ANDROID-PLAN "Transfer") comes with the rotation.
    public func changePassword(_ password: String, newPassword: String, pin: String?) async throws {
        guard let pin else { throw VaultFailure(.notSupported, code: ReleasePath.codeReleaseTooOld) }
        try await unanswered {
            try await guarded {
                let api = try openApi(try await openSession())
                try await api.credentialChangePassword(password: password, newPassword: newPassword, pin: pin)
            }
        }
    }

    /// A change (of the PIN or the password) that got no answer: the vault may have made it. Its failure carries
    /// ``codeChangeUnanswered`` (chosen; not in the spec).
    private func unanswered(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let f as VaultFailure where f.kind == .noResponse || f.kind == .network {
            throw VaultFailure(f.kind, code: Self.codeChangeUnanswered, cause: f)
        }
    }

    /// The code of a change of the PIN or the password that got no answer (chosen; not in the spec).
    public nonisolated static let codeChangeUnanswered = "change_unanswered"

    public func setBackup(_ on: Bool) async throws {
        try await guarded { try await setSetting(try await openSession(), Self.keyBackup, on ? "true" : "false") }
    }

    public func setUnlockTtl(seconds: Int) async throws {
        guard Self.unlockTtlRange.contains(seconds) else { throw VaultFailure(.other, code: "bad_request") }
        try await guarded { try await setSetting(try await openSession(), Self.keyUnlockTtl, String(seconds)) }
    }

    // MARK: - The PIN (release R)

    /// `pin.change` (release R, §11.14.9): the current PIN, the new one, the password and the phone's next secret. The
    /// next epoch's record is written before the request is built (IOS-PLAN §6.3 item 1); it becomes current only with
    /// the answer's `epoch_advanced`, and a lost answer is caught by the next unlock. A retry after a failure reuses it
    /// (item 2); a new record is made only for a new change after one was confirmed. The rotation offered after it
    /// (ANDROID-PLAN "Transfer") comes with the rotation.
    ///
    /// No answer (``codeChangeUnanswered``): the vault may hold the new PIN already; the record stays a candidate for
    /// the next unlock. While this change is on its way a second one is refused (``FailureKind/busy``). A record that
    /// cannot be made current after `epoch_advanced` is a success all the same: it stays a candidate, and the next unlock
    /// confirms it.
    public func changePin(pin: String, newPin: String, password: String) async throws {
        try await unanswered {
            try await guarded {
                guard phoneSecrets.inUse else { throw VaultFailure(.notSupported, code: Self.codeNoPhoneSecret) }
                let api = try openApi(try await openSession())
                let operation = try pinOperation()
                let advanced = try await phoneSecrets.change(operation: operation, send: { next in
                    try await api.pinChange(pin: pin, newPin: newPin, password: password, newUnlockSecret: next)
                }, confirmed: { _ in false })
                guard advanced else { return }
                // The vault holds the new secret: a new change makes a new record, whether or not this one is current yet.
                pinChangeOperation = nil
                if let override = confirmPinChangeOverride { try? override(operation) } else {
                    try? phoneSecrets.confirmChange(operation: operation)
                }
            }
        }
    }

    /// The operation of this `pin.change`: the one still unconfirmed (a retry reuses its record, IOS-PLAN §6.3 item 2),
    /// else a new one. Refused while that operation is on its way.
    private func pinOperation() throws -> String {
        if let op = pinChangeOperation {
            if phoneSecrets.inFlight(operation: op) { throw VaultFailure(.busy, code: "change_in_flight") }
            // An operation whose record is no longer a candidate (an unlock confirmed it) is over.
            if try !phoneSecrets.records().candidates.contains(where: { $0.operation == op }) { pinChangeOperation = nil }
        }
        let operation = pinChangeOperation ?? "pin.change-\(UUID().uuidString)"
        pinChangeOperation = operation
        return operation
    }

    /// The PIN change before release R (§10.6): the iPhone app serves only vaults of release R (IOS-PLAN ID8), whose
    /// `pin.change` carries the password and the phone's next secret.
    public func changePin(pin: String, newPin: String) async throws {
        throw VaultFailure(.notSupported, code: ReleasePath.codeReleaseTooOld)
    }
}
