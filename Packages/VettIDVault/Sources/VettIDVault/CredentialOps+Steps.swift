import Foundation

// The steps a change, a reset or a renew takes right before its send (VAULT-MESSAGING §11.14.9; ANDROID-PLAN "While
// pending"), apart from ``CredentialOps``.
extension CredentialOps {
    /// The blob this device holds is still the one [change] was fixed on, right before the request is built: a blob kept
    /// outside the credential lock (a fetch or a UTK top-up of a decision) never goes with a request fixed on another
    /// version. Else refused with nothing sent; the caller clears the marker it stored (``VaultManager`` `changing`).
    func sameVersion(_ change: ChangeRequest, _ type: String) throws {
        guard device.credentialVersion == change.version else { throw CredentialUnsettled(type: type, reason: .inFlight) }
    }

    /// [onMarker] for [change]; [utk] goes back to the pool when it fails: it never left the phone (IOS-PLAN 0.1.16 §4.5
    /// (1)).
    func marked(_ change: ChangeRequest, _ utk: UtkRecord, _ onMarker: OnMarker) async throws -> [SealedField] {
        do {
            return try await onMarker(change)
        } catch {
            try? await device.returnUTK(utk)
            throw error
        }
    }

    /// [send], whose request the lock gate may hold before it is sent (``OutboxHeld``): [utk] then goes back to the pool, since
    /// it never left the phone.
    func heldGivesBack<T>(_ utk: UtkRecord, _ send: () async throws -> T) async throws -> T {
        do {
            return try await send()
        } catch let e as OutboxHeld {
            try? await device.returnUTK(utk)
            throw e
        }
    }
}
