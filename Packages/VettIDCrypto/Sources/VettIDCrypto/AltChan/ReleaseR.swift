import CryptoKit
import Foundation

/// The phone-held unlock secret of VAULT-MESSAGING 0.33.0 §11.14.1 (release R), in Android's form 1:
///
/// ```
/// unlock_secret = HMAC-SHA-256(phone key, "vettid/vms/2/unlock-secret" || 0x00 || vault_id || 0x00 || epoch (8, big-endian))
/// ```
///
/// The iPhone makes its secret differently (``PhoneSecretIOS``); this form is here for the shared vector and for the
/// software `PhoneSecretSource` of tests. Mirrors vettid-android `UnlockSecret`.
public enum UnlockSecret {
    public static let label = "vettid/vms/2/unlock-secret"
    public static let size = 32

    /// The HMAC's message for [vaultID] at [epoch] (1 after enrollment, a transfer or a recovery). A transfer's new phone
    /// does not know the vault id when it sends its `hs.init` and uses "" there and at every later unlock.
    public static func message(vaultID: String, epoch: UInt64) throws -> [UInt8] {
        guard epoch >= 1 else { throw CryptoError.format("unlock secret input") }
        return Array(label.utf8) + [0] + Array(vaultID.utf8) + [0] + Bytes.uintBE(epoch, 8)
    }

    /// The secret, from the phone key's HMAC [hmac] over the message.
    public static func compute(vaultID: String, epoch: UInt64, hmac: ([UInt8]) throws -> [UInt8]) throws -> [UInt8] {
        let out = try hmac(try message(vaultID: vaultID, epoch: epoch))
        guard out.count == size else { throw CryptoError.key("unlock secret size") }
        return out
    }
}

/// The phone-held unlock secret **on an iPhone** (VAULT-MESSAGING 0.35.0 §11.14.1 "On an iPhone", IOS-PLAN §6.3 and
/// ID9). The phone key `P` is a Secure Enclave P-256 key-agreement key (VettIDKeys, I1.4); for each epoch the app makes
/// a fresh software key pair `E_e`, keeps only its public key in a record, and derives
///
/// ```
/// z_e           = ECDH(priv(E_e), pub(P)) = ECDH(priv(P), pub(E_e)): the x-coordinate, 32 bytes
/// info_e        = "vettid/vms/2/unlock-secret-ios" || 0x00 || key_vault || 0x00 || epoch (8, big-endian)
///                 || pub(P) (65) || pub(E_e) (65)
/// unlock_secret = HKDF-SHA-256(ikm = z_e, salt = empty, info = info_e, L = 32)
/// check_e       = the first 16 bytes of HMAC-SHA-256(key = unlock_secret, msg = "vettid/vms/2/unlock-secret-ios-check")
/// ```
///
/// Public keys are SEC1 uncompressed (65 bytes) and parsed with full point validation. The functions take the Secure
/// Enclave's ECDH as a closure, so the same code runs with the hardware key and with the vectors' software stand-in.
public enum PhoneSecretIOS {
    public static let label = "vettid/vms/2/unlock-secret-ios"
    public static let checkLabel = "vettid/vms/2/unlock-secret-ios-check"
    public static let checkSize = 16
    public static let publicKeySize = 65

    /// A stored public key parsed with full point validation: 65-byte SEC1 uncompressed and on the curve. Anything
    /// else (a point off the curve, the point at infinity, a compressed or truncated encoding) counts as keys that no
    /// longer work.
    public static func publicKey(_ b: [UInt8]) throws -> P256.KeyAgreement.PublicKey {
        guard b.count == publicKeySize, b[0] == 0x04, let k = try? P256.KeyAgreement.PublicKey(x963Representation: b) else {
            throw CryptoError.key("phone secret point")
        }
        return k
    }

    /// `info_e`. [keyVault] is fixed for the life of the phone key (the vault id, or "" for a transfer's new phone);
    /// vault ids contain no 0x00 byte.
    public static func info(keyVault: String, epoch: UInt64, phoneKey: [UInt8], ephemeral: [UInt8]) throws -> [UInt8] {
        guard epoch >= 1, !keyVault.utf8.contains(0) else { throw CryptoError.format("phone secret input") }
        _ = try publicKey(phoneKey)
        _ = try publicKey(ephemeral)
        return Array(label.utf8) + [0] + Array(keyVault.utf8) + [0] + Bytes.uintBE(epoch, 8) + phoneKey + ephemeral
    }

    /// unlock_secret = HKDF-SHA-256(z_e, salt = empty, info_e, 32).
    public static func secret(z: [UInt8], info: [UInt8]) throws -> [UInt8] {
        guard z.count == 32 else { throw CryptoError.key("phone secret z") }
        return try Hkdf.derive(ikm: z, salt: [], info: info, length: UnlockSecret.size)
    }

    /// check_e: the first 16 bytes of HMAC-SHA-256(unlock_secret, "vettid/vms/2/unlock-secret-ios-check").
    public static func check(_ secret: [UInt8]) -> [UInt8] {
        Array(hmacSHA256(key: secret, Array(checkLabel.utf8)).prefix(checkSize))
    }

    /// ECDH with a software private key: the x-coordinate of the shared point.
    static func softwareECDH(_ privateKey: P256.KeyAgreement.PrivateKey, _ peer: P256.KeyAgreement.PublicKey) throws -> [UInt8] {
        try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
    }

    /// A new epoch's record and secret. [ephemeral] is the epoch's fresh software key `E_e` (dropped by the caller
    /// afterwards: never written, logged or reported); [phoneECDH] is the Secure Enclave's ECDH(priv(P), ·). Key
    /// confirmation: both directions must give the same `z_e`, which proves the Secure Enclave can make the secret
    /// before the vault holds it. The caller stores the record **before** it builds the request that carries the secret.
    public static func newEpoch(
        keyVault: String,
        epoch: UInt64,
        phoneKey: [UInt8],
        ephemeral: P256.KeyAgreement.PrivateKey,
        phoneECDH: ([UInt8]) throws -> [UInt8]
    ) throws -> (record: PhoneSecretRecord, secret: [UInt8]) {
        let pubE = Array(ephemeral.publicKey.x963Representation)
        let info = try info(keyVault: keyVault, epoch: epoch, phoneKey: phoneKey, ephemeral: pubE)
        var z = try softwareECDH(ephemeral, try publicKey(phoneKey))
        var confirm = try phoneECDH(pubE)
        defer {
            Bytes.wipe(&z)
            Bytes.wipe(&confirm)
        }
        guard Bytes.constantTimeEquals(z, confirm) else { throw CryptoError.key("phone secret confirmation") }
        let s = try secret(z: z, info: info)
        return (PhoneSecretRecord(keyVault: keyVault, epoch: epoch, ephemeral: pubE, check: check(s)), s)
    }

    /// The secret of a stored [record], recomputed with the Secure Enclave's ECDH and checked against the record's tag.
    /// A point that does not parse or a tag that does not match means the keys no longer work.
    public static func recompute(
        _ record: PhoneSecretRecord,
        phoneKey: [UInt8],
        phoneECDH: ([UInt8]) throws -> [UInt8]
    ) throws -> [UInt8] {
        let info = try info(keyVault: record.keyVault, epoch: record.epoch, phoneKey: phoneKey, ephemeral: record.ephemeral)
        var z = try phoneECDH(record.ephemeral)
        defer { Bytes.wipe(&z) }
        var s = try secret(z: z, info: info)
        guard Bytes.constantTimeEquals(check(s), record.check) else {
            Bytes.wipe(&s)
            throw CryptoError.key("phone secret check")
        }
        return s
    }
}

/// One epoch's record of the iPhone's unlock secret (VAULT-MESSAGING §11.14.1 "On an iPhone"):
/// `(key_vault, epoch, pub(E_e), check_e)`. It holds nothing secret by itself: without the Secure Enclave key, `pub(E_e)`
/// gives nothing. The record store (VettIDKeys, I1.4) keeps the current record and up to four candidates in the
/// encrypted file store, never in Caches or tmp.
public struct PhoneSecretRecord: Equatable, Sendable {
    public let keyVault: String
    public let epoch: UInt64
    /// pub(E_e), SEC1 uncompressed.
    public let ephemeral: [UInt8]
    /// check_e, 16 bytes.
    public let check: [UInt8]

    public init(keyVault: String, epoch: UInt64, ephemeral: [UInt8], check: [UInt8]) {
        self.keyVault = keyVault
        self.epoch = epoch
        self.ephemeral = ephemeral
        self.check = check
    }

    /// The stored form: `{"v":1,"key_vault","epoch","pub_e","check"}`, compact JSON, base64 values.
    public func marshal() -> [UInt8] {
        JsonBuilder()
            .uint("v", 1)
            .string("key_vault", keyVault)
            .uint("epoch", epoch)
            .base64("pub_e", ephemeral)
            .base64("check", check)
            .bytes()
    }

    public static func parse(_ b: [UInt8]) throws -> PhoneSecretRecord {
        let o = try StrictJson.parseObject(b)
        _ = try o.uint("v", min: 1, max: 1)
        let keyVault = try o.string("key_vault")
        guard !keyVault.utf8.contains(0) else { throw CryptoError.format("phone secret record") }
        return PhoneSecretRecord(
            keyVault: keyVault,
            epoch: try o.uint("epoch", min: 1, max: StrictJson.maxSafeInteger),
            ephemeral: try o.base64("pub_e", PhoneSecretIOS.publicKeySize),
            check: try o.base64("check", PhoneSecretIOS.checkSize)
        )
    }
}

/// Passwords from release R (§11.14.7): one form, NFC, before any use. Mirrors vettid-android `Passwords`.
public enum Passwords {
    public static let maxBytes = 1024
    private static let maxLength = 0xFFFF

    /// [password] in Unicode NFC, as the enclave normalizes it.
    public static func nfc(_ password: String) -> String { password.precomposedStringWithCanonicalMapping }

    /// The `secrets` byte string of §11.14.3: `len(PIN) (2) || PIN || len(password) (2) || NFC(password)`, lengths
    /// big-endian in bytes.
    public static func recoverySecrets(pin: String, password: String) throws -> [UInt8] {
        let p = Array(pin.utf8)
        let w = Array(nfc(password).utf8)
        guard pin.allSatisfy(\.isASCII), !p.isEmpty, p.count <= maxLength, !w.isEmpty, w.count <= maxBytes else {
            throw CryptoError.format("recovery secrets")
        }
        return Bytes.uintBE(UInt64(p.count), 2) + p + Bytes.uintBE(UInt64(w.count), 2) + w
    }
}

/// `vault.recovery.open` (§11.14.6, release R): the registered phone opens its recovery with the PIN, the password and
/// its unlock secret, sealed to the ETK and signed by its device key; the result is sealed to its `kem`. Mirrors
/// vettid-android `RecoveryOpen`.
public enum RecoveryOpen {
    public static let type = "vault.recovery.open"
    public static let typeResult = "vault.recovery.open.result"
    public static let label = "vettid/vms/2/recovery-open"

    /// What `sig` covers.
    public struct Fields: Sendable {
        public let userGuid: String
        public let vaultID: String
        public let requestID: String
        public let recoveryID: String
        public let ts: String
        public let etkKid: Kid
        public let secrets: [UInt8]
        public let token: String
        /// hex(SHA-256(manifest bytes)): the request's manifest_sha256.
        public let manifestSHA256: String
        public let unlockSecret: [UInt8]

        public init(
            userGuid: String, vaultID: String, requestID: String, recoveryID: String, ts: String, etkKid: Kid,
            secrets: [UInt8], token: String, manifestSHA256: String, unlockSecret: [UInt8]
        ) {
            self.userGuid = userGuid
            self.vaultID = vaultID
            self.requestID = requestID
            self.recoveryID = recoveryID
            self.ts = ts
            self.etkKid = etkKid
            self.secrets = secrets
            self.token = token
            self.manifestSHA256 = manifestSHA256
            self.unlockSecret = unlockSecret
        }
    }

    /// label \n user_guid \n vault_id \n request_id \n recovery_id \n ts \n etk_kid_hex \n hex(SHA-256(secrets)) \n
    /// hex(SHA-256(token)) \n hex(SHA-256(manifest_bytes)) \n hex(SHA-256(unlock_secret)); no trailing newline.
    public static func signingString(_ f: Fields) throws -> String {
        let parts = [f.userGuid, f.vaultID, f.requestID, f.recoveryID, f.ts, f.token]
        guard !parts.contains(where: { $0.isEmpty || $0.utf8.contains(0x0D) || $0.utf8.contains(0x0A) }),
              Bytes.isLowerHex(f.manifestSHA256, 64)
        else { throw CryptoError.format("recovery open field") }
        guard f.unlockSecret.count == UnlockSecret.size else { throw CryptoError.format("recovery open secret") }
        return [
            label, f.userGuid, f.vaultID, f.requestID, f.recoveryID, f.ts, f.etkKid.description,
            Bytes.hex(Bytes.sha256(f.secrets)), Bytes.hex(Bytes.sha256(Array(f.token.utf8))), f.manifestSHA256,
            Bytes.hex(Bytes.sha256(f.unlockSecret)),
        ].joined(separator: "\n")
    }

    /// The request body in §11.14.6 member order; [password] is sent in NFC.
    public static func marshal( // swiftlint:disable:this function_parameter_count
        userGuid: String, vaultID: String, requestID: String, recoveryID: String, deviceIk: [UInt8], pin: String,
        password: String, unlockSecret: [UInt8], token: String, assertion: DeviceAssertion, manifestSHA256: String,
        manifestSerial: UInt64, sig: [UInt8]
    ) throws -> [UInt8] {
        guard AltChannel.isValidPin(pin), unlockSecret.count == UnlockSecret.size, Ulid.isValid(requestID), manifestSerial >= 1 else {
            throw CryptoError.format("recovery open request")
        }
        return JsonBuilder()
            .string("user_guid", userGuid).string("vault_id", vaultID).string("request_id", requestID)
            .string("recovery_id", recoveryID).base64("device_ik", deviceIk).string("pin", pin)
            .string("password", Passwords.nfc(password)).base64("unlock_secret", unlockSecret).string("token", token)
            .raw("device_assertion", assertion.marshal()).string("manifest_sha256", manifestSHA256)
            .uint("manifest_serial", manifestSerial).base64("sig", sig).bytes()
    }

    /// `vault.recovery.open.result`. [used] is attempts.used when the counter answered ([counted]).
    public struct Result: Sendable {
        public static let attempts: UInt64 = 10

        public let ok: Bool
        public let code: String
        public let stateSeq: UInt64
        public let headerSeq: UInt64
        public let token: String
        public let vaultBundle: [UInt8]?
        public let release: String
        public let releaseNumber: UInt64
        public let unlockID: String?
        public let counted: Bool
        public let used: Int
        public let retryAt: Date?
        /// (0.34.0) Whether THIS request used an attempt (the spend happened), as the vault says; nil from a vault that
        /// does not send it. The app never infers it from the code, `attempts` or `retry_at`.
        public let attemptUsed: Bool?

        public static func parse(_ o: JsonObject) throws -> Result {
            let ok = try o.bool("ok")
            let attempts = try o.optObj("attempts")
            let used = Int(try attempts?.uint("used", min: 0, max: Self.attempts) ?? 0)
            let retry = try o.optString("retry_at").flatMap { (try? Timestamps.parseSeconds($0)) ?? (try? Timestamps.parseMillis($0)) }
            let attemptUsed = o.has("attempt_used") ? try o.bool("attempt_used") : nil
            let max = StrictJson.maxSafeInteger
            if ok {
                return Result(
                    ok: true, code: "", stateSeq: try o.uint("state_seq", min: 0, max: max),
                    headerSeq: try o.uint("header_seq", min: 0, max: max),
                    token: try o.string("token"), vaultBundle: try Base64s.decodeStd(try o.string("vault_bundle")),
                    release: try o.optString("release") ?? "", releaseNumber: try o.optUint("release_number", min: 0, max: max) ?? 0,
                    unlockID: try o.optString("unlock_id"), counted: attempts != nil, used: used, retryAt: retry, attemptUsed: attemptUsed
                )
            }
            return Result(
                ok: false, code: try o.string("code"), stateSeq: 0, headerSeq: 0, token: "", vaultBundle: nil, release: "",
                releaseNumber: 0, unlockID: nil, counted: attempts != nil, used: used, retryAt: retry, attemptUsed: attemptUsed
            )
        }

        public static func parse(_ raw: [UInt8]) throws -> Result { try parse(try StrictJson.parseObject(raw)) }
    }
}
