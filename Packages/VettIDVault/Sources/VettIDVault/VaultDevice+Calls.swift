import Foundation
import VettIDCrypto

// What call signalling (VAULT-MESSAGING §10.10, `VaultApi+Calls.swift`) needs of the device: its identity key to sign a
// call's key-exchange share, the vault's current identity key, and the device's clock.
extension VaultDevice {
    /// The type of the hang-up: durable, kept in the outbox until the relay has it (§10.10).
    static let typeCallEnd = "call.end"

    /// This device's signature over a call's key-exchange share (§10.10; ``CallWire/signShare(deviceIk:message:)``).
    func signCallShare(_ message: [UInt8]) throws -> [UInt8] {
        try CallWire.signShare(deviceIk: secrets.identity, message: message)
    }

    /// The vault's current identity key (followed through `identity.rotate`).
    func vaultIdentityKey() throws -> [UInt8] {
        try mem.withLock { try Base64s.decodeStd(requireVault().ik) }
    }

    /// The device's clock.
    func clockNow() -> Date { now() }
}
