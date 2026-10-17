import Foundation

/// A granted item's content sealed to the fetching device's one-time reply key (VAULT-MESSAGING §10.12, vettid-vault's
/// `vms/sharewire`): `value_sealed = enc (1,120) || Seal(aad = "", content)` with
/// `SetupBaseS(reply_key, info = "vettid/vms/2/grant" || 0x00 || grant_id || 0x00 || fetch_id)`. Mirrors vettid-android
/// `GrantSeal`.
public enum GrantSeal {
    public static let label = "vettid/vms/2/grant"
    public static let maxValue = 65_536

    private static func info(grantID: String, fetchID: String) -> [UInt8] { Array("\(label)\u{0}\(grantID)\u{0}\(fetchID)".utf8) }

    public static func openValue(reply: KemPrivateKey, grantID: String, fetchID: String, sealed: [UInt8]) throws -> [UInt8] {
        let (enc, ct) = try CredentialSeal.split(sealed, max: maxValue)
        let r = try HpkeRecipient.setup(enc: enc, key: reply, info: info(grantID: grantID, fetchID: fetchID))
        return try r.open(aad: [], ciphertext: ct)
    }

    /// The granting vault's side of ``openValue(reply:grantID:fetchID:sealed:)`` (tests and tooling).
    public static func sealValue(reply: KemPublicKey, grantID: String, fetchID: String, value: [UInt8]) throws -> [UInt8] {
        guard value.count <= maxValue else { throw CryptoError.format("value too large") }
        let s = try HpkeSender.setup(reply, info: info(grantID: grantID, fetchID: fetchID))
        return s.enc + (try s.seal(aad: [], plaintext: value))
    }
}
