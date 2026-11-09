import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDVault

/// The pending epoch-1 record and the bundle's traits, as the alternate channel's callback (off the main actor) leaves
/// them.
final class TransferPath: @unchecked Sendable {
    private let lock = NSLock()
    private var epochID: String?
    private var caps: [String] = []
    private var scale: UInt64 = TimeScale.real

    func set(_ id: String, _ capabilities: [String], _ timeScale: UInt64) {
        lock.withLock { (epochID, caps, scale) = (id, capabilities, timeScale) }
    }

    struct Seen {
        let id: String?
        let capabilities: [String]
        let timeScale: UInt64
    }

    var value: Seen { lock.withLock { Seen(id: epochID, capabilities: caps, timeScale: scale) } }
}

/// The secret of a scan's `hs.init` (the secret callback of ``VaultDevice/startTransfer(link:attester:unlockSecretFor:)``):
/// the bundle's release and time scale are checked first, the epoch-1 records still pending for "" are dropped, and a new
/// record is made and stored with the transfer (`note`) before the secret is returned. Throws, and then nothing is sent,
/// when the drop or any step fails (VAULT-MESSAGING §6.7.1, §11.14.10 rule 5).
struct FreshTransferSecret: Sendable {
    let secrets: PhoneSecrets
    let policy: TimeScalePolicy
    let path: TransferPath

    func make(_ capabilities: [String], _ scale: UInt64, note: @Sendable (String) async throws -> Void) async throws -> [UInt8] {
        try ReleasePath.requireR(capabilities)
        try policy.check(scale)
        try secrets.dropPendings(keyVault: "")
        var epoch = try secrets.create(keyVault: "")
        path.set(epoch.id, capabilities, scale)
        // Known at once, so that a failure after it can delete the record (``VaultManager/dropTransfer(_:)``).
        do {
            try await note(epoch.id)
        } catch {
            // Not stored with the transfer, so no drop would find it: it goes here, and nothing is sent.
            _ = try? secrets.dropPending(id: epoch.id)
            Bytes.wipe(&epoch.secret)
            throw error
        }
        return epoch.secret
    }
}

extension VaultManager {
    /// The epoch-1 record of the transfer is stored with it, before anything is sent: a drop deletes this one (§11.14.10).
    func noteTransferEpoch(_ id: String) throws {
        guard try record.update(since: record.generation, { $0.transferEpochID = id }) else {
            throw VaultFailure(.localState, code: "transfer_epoch_not_stored")
        }
    }
}
