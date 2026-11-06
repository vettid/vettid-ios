import Foundation
import VettIDVault

/// A status read that may finish after its wait ended (it is then not used).
@MainActor
final class FreshStatus {
    var view: OwnerCheckView?
    /// `vault.status` answered (with or without an `owner_check`).
    var answered = false
}

/// ``OwnerCheckOps`` over the vault client. Mirrors vettid-android `VaultOwnerCheckOps`.
struct VaultOwnerCheckOps: OwnerCheckOps {
    let api: VaultApi
    /// Runs before the check is sent: refuses it while a change of PIN or password is unresolved (VAULT-MESSAGING
    /// §11.14.9 "A lost answer").
    var gate: @Sendable () async throws -> Void = {}
    /// Runs each `vault.status` read, which hears it (its `time_scale`, STAGING-TIME-SCALE §5.2; its `relay`, 0.84.0).
    var around: @Sendable (@Sendable () async throws -> VaultStatusInfo) async throws -> VaultStatusInfo = { try await $0() }

    func statusAndRecovery() async throws -> (OwnerCheckStatus?, RecoveryStatus?) {
        let s = try await around { try await api.status() }
        return (s.ownerCheck, s.recovery)
    }

    func check(pin: String, password: String, hold: Bool?, holdOffUntil: String?) async throws -> OwnerCheckPassed {
        try await gate()
        return try await api.ownerCheck(pin: pin, password: password, hold: hold, holdOffUntil: holdOffUntil)
    }

    func settingsGet() async throws -> VaultSettings { try await api.settingsGet() }

    func settingsSet(version: UInt64, set: [(key: String, json: String)]) async throws {
        _ = try await api.settingsSet(version: version, set: set)
    }
}
