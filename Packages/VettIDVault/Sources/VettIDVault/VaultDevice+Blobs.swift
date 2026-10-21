import Foundation
import VettIDCrypto
import VettIDRelay

// Blobs (RELAY-PROTOCOL §6.8, VAULT-MESSAGING §10.5.1): the photo this device uploads to its vault's mailbox, and the
// fresh blobs the vault uploads to this device's own mailbox when the member opens a photo. Mirrors the blob part of
// vettid-android `VaultDevice`.
extension VaultDevice {
    /// Uploads [blob] to the vault's mailbox under the standing token the vault issued this device. Once: the caller never
    /// uploads the same photo again after a lost answer (every abandoned upload fills the mailbox's shared storage).
    /// A `token_revoked` refusal counts as a deposit's (§7.4). Returns the relay's `blob_id`.
    public func uploadBlobToVault(_ blob: [UInt8]) async throws -> String {
        let v = try mem.withLock { try requireVault() }
        guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
        do {
            return try await relayFor(v.relayURL).putBlob(mailboxID: v.mailbox, token: v.token, ciphertext: blob).id
        } catch let x as RelayError {
            countRefusal(x, mailbox: v.mailbox, token: v.token)
            throw x
        }
    }

    /// Fetches a blob the vault uploaded to this device's own mailbox (`blob_unknown` for any other), at most
    /// [maxBytes]: a larger one is refused before it is read whole.
    public func fetchOwnBlob(_ blobID: String, maxBytes: Int = RelayClient.maxBlobRead) async throws -> [UInt8] {
        try await own.getBlob(blobID, maxBytes: maxBytes)
    }

    /// Deletes a blob in this device's own mailbox (idempotent): every fetched blob is deleted, good or bad.
    public func deleteOwnBlob(_ blobID: String) async throws { try await own.deleteBlob(blobID) }
}
