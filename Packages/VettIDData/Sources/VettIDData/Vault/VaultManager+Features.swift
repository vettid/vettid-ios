import Foundation
import VettIDVault

// The managers of the features over this manager's session: the name change (VAULT-MESSAGING §10.8) and the connections
// (§6.4, §10.4).
extension VaultManager {
    /// The name change over this manager's session: the request kept with the account record it was sent for, the checks
    /// left read again after a wrong PIN or password.
    static func profiles(_ ref: ManagerRef, checks: OwnerCheckManager, record rec: AccountRecord) -> ProfileManager {
        ProfileManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                return VaultProfileOps(api: try m.openApi(try await m.openSession()), gate: Self.pinGate(ref))
            },
            onRequest: { r, since in ref.manager?.keepNameRequest(r, since: since) },
            checksLeft: {
                try? await checks.refreshOwnerCheck()
                return checks.ownerCheck?.checksLeft
            },
            mark: { rec.generation }
        )
    }

    /// The connections over this manager's session, what only this phone learns kept in their encrypted file.
    static func connectionsManager(_ config: VaultManagerConfig, _ ref: ManagerRef, _ rec: AccountRecord) -> ConnectionsManager {
        let file = config.file(VaultFiles.connections)
        return ConnectionsManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                return try m.openApi(try await m.openSession())
            },
            load: { try file.load() },
            // Nothing is written while a wipe runs or after one that did not finish.
            persist: { b in
                guard !rec.closed else { return }
                if b.isEmpty { try file.clear() } else { try file.save(b) }
            },
            now: config.now
        )
    }
}
