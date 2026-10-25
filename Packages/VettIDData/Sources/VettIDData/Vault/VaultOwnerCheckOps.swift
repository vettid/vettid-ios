import Foundation
import VettIDVault

/// A status read that may finish after its wait ended (it is then not used).
@MainActor
final class FreshStatus {
    var view: OwnerCheckView?
}

/// ``OwnerCheckOps`` over the vault client. Mirrors vettid-android `VaultOwnerCheckOps`.
struct VaultOwnerCheckOps: OwnerCheckOps {
    let api: VaultApi
    /// Runs before the check is sent: refuses it while a change of PIN or password is unresolved (VAULT-MESSAGING
    /// §11.14.9 "A lost answer").
    var gate: @Sendable () async throws -> Void = {}
    /// Hears each `vault.status` (its `time_scale`, STAGING-TIME-SCALE §5.2).
    var onStatus: @Sendable (VaultStatusInfo) async -> Void = { _ in }

    func statusAndRecovery() async throws -> (OwnerCheckStatus?, RecoveryStatus?) {
        let s = try await api.status()
        await onStatus(s)
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
