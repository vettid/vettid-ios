import Foundation
import VettIDCrypto

// Release R (VAULT-MESSAGING §11.14.9): the changes of PIN and phone secret, holder credential operations. Mirrors
// vettid-android `ReleaseRApi.kt`.
extension VaultApi {
    /// `pin.change`: the current PIN, the new one, the password and the phone's next epoch's secret, sealed to one UTK,
    /// with the blob. Returns the answer's `epoch_advanced`: only `true` lets the phone move to the next epoch
    /// (§11.14.1); anything else leaves the next epoch's record a candidate, for an unlock to decide.
    public func pinChange(pin: String, newPin: String, password: String, newUnlockSecret: [UInt8]) async throws -> Bool {
        let fields: [SealedField] = [
            .string("pin", pin), .string("new_pin", newPin), .string("password", password),
            .string("new_unlock_secret", Base64s.encodeStd(newUnlockSecret)),
        ]
        let body = try await credential.credOp("pin.change", fields)
        return VaultJSON.bool(VaultJSON.object(body), "epoch_advanced") == true
    }
}
