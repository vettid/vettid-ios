import Foundation

/// A one-time transaction key as the vault issues it (VAULT-MESSAGING §3.5.4):
/// `{"utk_id": "<16 lowercase hex>", "ek": "<b64 1,216 bytes>", "expires_at": "<ts>"}`. Mirrors vettid-android `Utk`.
public struct Utk: Sendable {
    public let id: String
    public let ek: KemPublicKey
    public let expiresAt: Date

    public init(id: String, ek: KemPublicKey, expiresAt: Date) {
        self.id = id
        self.ek = ek
        self.expiresAt = expiresAt
    }

    public static func parse(_ o: JsonObject) throws -> Utk {
        let id = try o.string("utk_id")
        guard Bytes.isLowerHex(id, 16) else { throw CryptoError.format("utk_id") }
        return Utk(
            id: id,
            ek: try KemPublicKey.parse(try o.base64("ek", Suite.ekSize)),
            expiresAt: try Timestamps.parseMillis(try o.string("expires_at"))
        )
    }
}

/// The Protean Credential's wire crypto on the app side (§3.5.4): critical payloads sealed to a single-use vault key
/// (UTK) inside the session, and critical values the vault seals to a one-time reply key. One HPKE context per message.
/// Mirrors vettid-android `CredentialSeal` and vettid-vault's `credwire`.
public enum CredentialSeal {
    public static let maxPayload = 16 * 1024
    public static let maxValue = 64 * 1024

    private static func utkInfo(vaultID: String, utkID: String) -> [UInt8] {
        Array("\(Labels.utk)\u{0}\(vaultID)\u{0}\(utkID)".utf8)
    }

    private static func utkAad(type: String, innerID: String) -> [UInt8] { Array("\(type)\u{0}\(innerID)".utf8) }

    private static func replyInfo(vaultID: String, innerID: String) -> [UInt8] {
        Array("\(Labels.reply)\u{0}\(vaultID)\u{0}\(innerID)".utf8)
    }

    /// `sealed = enc (1,120) || ct`, with `SetupBaseS(ek_UTK, info = "vettid/vms/2/utk" || 0 || vault_id || 0 || utk_id)`
    /// and `ct = Seal(aad = type || 0 || inner id, pt = payload JSON)`. The payload is bound to the request type and
    /// id, so it cannot be moved.
    public static func sealPayload(utk: Utk, vaultID: String, type: String, innerID: String, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= maxPayload else { throw CryptoError.format("utk payload too large") }
        let s = try HpkeSender.setup(utk.ek, info: utkInfo(vaultID: vaultID, utkID: utk.id))
        return s.enc + (try s.seal(aad: utkAad(type: type, innerID: innerID), plaintext: payload))
    }

    /// The vault side of ``sealPayload(utk:vaultID:type:innerID:payload:)`` (tests and tooling).
    public static func openPayload( // swiftlint:disable:this function_parameter_count
        ltk: KemPrivateKey, vaultID: String, utkID: String, type: String, innerID: String, sealed: [UInt8]
    ) throws -> [UInt8] {
        let (enc, ct) = try split(sealed, max: maxPayload)
        let r = try HpkeRecipient.setup(enc: enc, key: ltk, info: utkInfo(vaultID: vaultID, utkID: utkID))
        return try r.open(aad: utkAad(type: type, innerID: innerID), ciphertext: ct)
    }

    /// Opens a reply-sealed value with the request's one-time key:
    /// `SetupBaseR(enc, reply, info = "vettid/vms/2/reply" || 0 || vault_id || 0 || inner id)`, aad empty.
    public static func openValue(reply: KemPrivateKey, vaultID: String, innerID: String, sealed: [UInt8]) throws -> [UInt8] {
        let (enc, ct) = try split(sealed, max: maxValue)
        let r = try HpkeRecipient.setup(enc: enc, key: reply, info: replyInfo(vaultID: vaultID, innerID: innerID))
        return try r.open(aad: [], ciphertext: ct)
    }

    /// The vault side of ``openValue(reply:vaultID:innerID:sealed:)`` (tests and tooling).
    public static func sealValue(reply: KemPublicKey, vaultID: String, innerID: String, value: [UInt8]) throws -> [UInt8] {
        guard value.count <= maxValue else { throw CryptoError.format("value too large") }
        let s = try HpkeSender.setup(reply, info: replyInfo(vaultID: vaultID, innerID: innerID))
        return s.enc + (try s.seal(aad: [], plaintext: value))
    }

    /// `enc || ct` with ct holding at most [max] bytes of plaintext; anything else does not open.
    static func split(_ sealed: [UInt8], max: Int) throws -> (enc: [UInt8], ct: [UInt8]) {
        guard sealed.count >= Suite.encSize + Suite.tagSize, sealed.count <= Suite.encSize + max + Suite.tagSize else {
            throw CryptoError.decrypt
        }
        return (Array(sealed[..<Suite.encSize]), Array(sealed[Suite.encSize...]))
    }
}

/// The header of a credential blob (§3.5.2): `blob = 0x01 || version (8, BE) || kid(CEK) (8) || enc (1,120) || ct`. The
/// app stores the blob as opaque bytes; it reads the header to know which version it holds. The length bounds are
/// vettid-vault's (`features/credential.ParseHeader`): the HPKE layer around the password-locked inner layer
/// (`t (1) || m (4) || p (1) || salt (16) || nonce (24) || XChaCha20-Poly1305(inner ≤ 131,072)`).
public struct CredentialBlobHeader: Sendable, Equatable {
    public static let format: UInt8 = 0x01
    public static let headerSize = 17
    public static let maxInner = 131_072
    private static let lockedOverhead = 22 + Suite.xNonceSize + Suite.tagSize
    public static let minSize = headerSize + Suite.encSize + Suite.tagSize + lockedOverhead
    public static let maxSize = minSize + maxInner

    public let version: UInt64
    public let cekKid: Kid

    public static func parse(_ blob: [UInt8]) throws -> CredentialBlobHeader {
        guard blob.count >= minSize, blob.count <= maxSize, blob[0] == format else {
            throw CryptoError.format("credential blob")
        }
        let version = Bytes.readUintBE(blob, 1, 8)
        guard version >= 1, version <= StrictJson.maxSafeInteger else { throw CryptoError.format("credential blob version") }
        return CredentialBlobHeader(version: version, cekKid: try Kid(Array(blob[9..<headerSize])))
    }
}

/// A credential-key rotation statement (§3.5.5), delivered to connections that pinned the member's key:
/// `{"v":1,"old_key","new_key","sig_old","sig_new"}`, m = old_key || new_key, each signature
/// Ed25519(key, "vettid/vms/2/credential-rotate" || m). Mirrors vettid-android `CredentialKeyRotation` and
/// vettid-vault's `credwire.KeyRotation`.
public struct CredentialKeyRotation: Sendable {
    public static let maxChain = 32

    public let oldKey: [UInt8]
    public let newKey: [UInt8]
    let sigOld: [UInt8]
    let sigNew: [UInt8]

    public func verify() throws {
        let m = oldKey + newKey
        guard !Ed25519.equalPublic(oldKey, newKey),
              Ed25519.verify(oldKey, label: Labels.credentialRotate, m, sigOld),
              Ed25519.verify(newKey, label: Labels.credentialRotate, m, sigNew)
        else { throw CryptoError.signature("credential rotation") }
    }

    public func marshal() -> String {
        JsonBuilder()
            .uint("v", 1)
            .base64("old_key", oldKey)
            .base64("new_key", newKey)
            .base64("sig_old", sigOld)
            .base64("sig_new", sigNew)
            .build()
    }

    public static func create(old: Ed25519PrivateKey, new: Ed25519PrivateKey) throws -> CredentialKeyRotation {
        guard !Ed25519.equalPublic(old.publicKey, new.publicKey) else { throw CryptoError.signature("credential rotation") }
        let m = old.publicKey + new.publicKey
        return CredentialKeyRotation(
            oldKey: old.publicKey,
            newKey: new.publicKey,
            sigOld: try old.sign(label: Labels.credentialRotate, m),
            sigNew: try new.sign(label: Labels.credentialRotate, m)
        )
    }

    /// Parses one statement strictly (signatures unchecked: ``verify()`` or ``followChain(pinned:_:)``).
    public static func parse(_ o: JsonObject) throws -> CredentialKeyRotation {
        _ = try o.uint("v", min: 1, max: 1)
        return CredentialKeyRotation(
            oldKey: try o.base64("old_key", Suite.ed25519PublicSize),
            newKey: try o.base64("new_key", Suite.ed25519PublicSize),
            sigOld: try o.base64("sig_old", Suite.ed25519SignatureSize),
            sigNew: try o.base64("sig_new", Suite.ed25519SignatureSize)
        )
    }

    /// Follows a non-empty chain (≤ 32 links) from the pinned key; returns the key it leads to.
    public static func followChain(pinned: [UInt8], _ chain: [CredentialKeyRotation]) throws -> [UInt8] {
        guard pinned.count == Suite.ed25519PublicSize, !chain.isEmpty, chain.count <= maxChain else {
            throw CryptoError.signature("credential chain")
        }
        var cur = pinned
        for r in chain {
            guard Ed25519.equalPublic(r.oldKey, cur) else { throw CryptoError.signature("credential chain") }
            try r.verify()
            cur = r.newKey
        }
        return cur
    }
}
