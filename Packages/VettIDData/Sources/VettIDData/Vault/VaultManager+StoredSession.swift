import Foundation

extension VaultManager {
    /// The highest manifest serial this phone has used for its vault (§11.10.1), 0 without a device: the canary
    /// manifest's installation check.
    func manifestSerialUsed() async throws -> UInt64 {
        try await storedSession()?.device.manifestSerialSeen() ?? 0
    }

    /// The session when this phone has a device: the open one, or the one its stored state restores. Nil when it has
    /// none (nothing to protect, and no mailbox registered for nothing).
    func storedSession() async throws -> VaultSession? {
        if let session { return session }
        // The identity in use is in the record; a record that cannot be read now leaves the first (as before it was asked), and
        // opening the session then fails as it did.
        let identity = (try? prepared()) != nil ? record.value.activeIdentity : .first
        guard try config.file(VaultFiles.device(of: identity)).load() != nil else { return nil }
        return try await openSession()
    }
}
