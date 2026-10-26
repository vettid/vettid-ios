import Foundation
import VettIDKeys

extension VaultManager {
    /// The highest manifest serial this phone has used for its vault (§11.10.1), 0 without a device: the canary
    /// manifest's installation check.
    func manifestSerialUsed() async throws -> UInt64 {
        try await storedSession()?.device.manifestSerialSeen() ?? 0
    }

    /// Whether any identity has a device state stored (reads the files only, not the record).
    func holdsDeviceState() throws -> Bool {
        try IdentitySet.all.contains { try config.file(VaultFiles.device(of: $0)).load() != nil }
    }

    /// The session when this phone has a device: the open one, or the one its stored state restores. Nil when it has
    /// none (nothing to protect, and no mailbox registered for nothing).
    func storedSession() async throws -> VaultSession? {
        if let session { return session }
        // The identity in use is in the record. A record that cannot be read is no reason to guess the first identity (a phone that
        // could not tell may live on a later one): if any identity has a device state, this fails (closed); if none has, there is
        // no device, as before.
        let identity: IdentitySet
        do {
            try prepared()
            identity = record.value.activeIdentity
        } catch {
            if try holdsDeviceState() { throw error }
            return nil
        }
        guard try config.file(VaultFiles.device(of: identity)).load() != nil else { return nil }
        return try await openSession()
    }
}
