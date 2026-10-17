import CryptoKit
import Foundation
import Testing
@testable import VettIDCrypto

// Vector checks stay on one line each.
// swiftlint:disable line_length

/// VAULT-MESSAGING 0.33.0 §11.14 (release R), the app's side, against vettid-vault's `unlock.json` and
/// `recovery.json`: the phone-held unlock secret per epoch, the recovery `secrets` string with NFC, the recovery open's
/// signing string and result, and the unlock signing string's last line. Mirrors vettid-android `ReleaseRVectorsTest`.
@Suite struct ReleaseRVectorsTests {
    let unlock: VectorDoc
    let rr: VectorDoc

    init() throws {
        unlock = try VectorDoc.load("unlock.json")
        rr = try VectorDoc.load("recovery.json").sub("release_r")
    }

    @Test func theUnlockSecretOfEachEpoch() throws {
        let phone = try unlock.sub("phone")
        let key = try phone.hex("phone_key_hex")
        let vault = try unlock.str("vault_id")
        let mac = { (m: [UInt8]) in hmacSHA256(key: key, m) }
        #expect(try UnlockSecret.compute(vaultID: vault, epoch: 1, hmac: mac) == phone.hex("epoch_1_hex"))
        #expect(try UnlockSecret.compute(vaultID: vault, epoch: 2, hmac: mac) == phone.hex("epoch_2_hex"))
        expectCrypto(.format) { _ = try UnlockSecret.message(vaultID: vault, epoch: 0) }
    }

    /// The unlock key and the secret check the vault derives (§11.14.1, §11.14.2), as unlock.json states them: the
    /// formula the phone_ios end-to-end values below rely on.
    @Test func theUnlockKeyFormula() throws {
        let vault = try unlock.str("vault_id")
        let (key, check) = try ReleaseRFormula.derive(x: unlock.hex("x_hex"), pepper: unlock.hex("pepper_hex"), vaultID: vault, secret: unlock.hex("unlock_secret_hex"))
        #expect(key == (try unlock.hex("unlock_key_hex")))
        #expect(check == (try unlock.hex("secret_check_hex")))
        let next = try unlock.sub("next")
        let (nextKey, nextCheck) = try ReleaseRFormula.derive(x: unlock.hex("x_hex"), pepper: unlock.hex("pepper_hex"), vaultID: vault, secret: next.hex("unlock_secret_hex"))
        #expect(nextKey == (try next.hex("unlock_key_hex")))
        #expect(nextCheck == (try next.hex("secret_check_next_hex")))
    }

    @Test func theRecoverySecretsString() throws {
        let s = try Passwords.recoverySecrets(pin: rr.str("pin"), password: rr.str("password"))
        #expect(s == (try rr.hex("secrets_hex")))
        #expect(Bytes.hex(Bytes.sha256(s)) == (try rr.str("secrets_sha256_hex")))
    }

    @Test func passwordsAreNormalizedToNfc() throws {
        // "café" typed with a combining accent (NFD) is the same password as with the precomposed letter.
        let nfd = "cafe\u{0301} horse battery"
        let nfc = "caf\u{00E9} horse battery"
        #expect(Array(nfd.utf8) != Array(nfc.utf8))
        #expect(try Passwords.recoverySecrets(pin: "123456", password: nfd) == Passwords.recoverySecrets(pin: "123456", password: nfc))
        #expect(Array(Passwords.nfc(nfd).utf8) == Array(nfc.utf8))
    }

    @Test func theRecoveryOpenSigningString() throws {
        let f = RecoveryOpen.Fields(
            userGuid: "test-user-guid", vaultID: try rr.str("vault_id"), requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T31", recoveryID: try rr.str("recovery_id"),
            ts: "2026-10-15T12:00:00.000Z", etkKid: try Kid.parseHex("40d6c2c8471844a9"),
            secrets: try Passwords.recoverySecrets(pin: rr.str("pin"), password: rr.str("password")), token: "test-token",
            manifestSHA256: Bytes.hex(Bytes.sha256(Array("manifest".utf8))), unlockSecret: rep(0x42, 32)
        )
        #expect(try RecoveryOpen.signingString(f) == rr.str("open_signing_string"))
    }

    @Test func theUnlockSigningStringEndsWithTheSecretsHash() throws {
        func fields(cancel: Bool = false, secret: [UInt8]? = nil) throws -> AltChannel.UnlockFields {
            AltChannel.UnlockFields(
                userGuid: "test-user-guid", vaultID: "test-vault-0001", requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T31", ts: "2026-10-15T12:00:00.000Z",
                etkKid: try Kid.parseHex("40d6c2c8471844a9"), minStateSeq: 3, minHeaderSeq: 4, pin: "123456", token: "test-token",
                manifestSHA256: Bytes.hex(Bytes.sha256(Array("manifest".utf8))), cancelRecovery: cancel, unlockSecret: secret
            )
        }
        let before = try AltChannel.unlockSigningString(fields())
        let secret = try unlock.hex("unlock_secret_hex")
        let tail = Bytes.hex(Bytes.sha256(secret))
        #expect(try AltChannel.unlockSigningString(fields(secret: secret)) == before + "\n" + tail)
        #expect(try AltChannel.unlockSigningString(fields(cancel: true, secret: secret)).hasSuffix("\ncancel_recovery\n" + tail))
        expectCrypto(.format) { _ = try AltChannel.unlockSigningString(fields(secret: rep(0, 31))) }
    }

    @Test func aRecoveryOpenResultIsRead() throws {
        let wrong = try RecoveryOpen.Result.parse(Array(#"{"ok":false,"code":"wrong","attempts":{"used":3,"of":10},"retry_at":"2026-10-17T12:00:00Z","attempt_used":true}"#.utf8))
        #expect(wrong.code == "wrong" && wrong.counted && wrong.used == 3 && wrong.attemptUsed == true)
        #expect(wrong.retryAt == (try Timestamps.parseSeconds("2026-10-17T12:00:00Z")))
        let busy = try RecoveryOpen.Result.parse(Array(#"{"ok":false,"code":"busy"}"#.utf8))
        #expect(!busy.counted && busy.retryAt == nil && busy.attemptUsed == nil)
        let ok = try RecoveryOpen.Result.parse(Array(#"{"ok":true,"state_seq":5,"header_seq":6,"token":"t","vault_bundle":"AAEC","release":"aa","release_number":13,"unlock_id":"00","attempts":{"used":1,"of":10},"attempt_used":false}"#.utf8))
        #expect(ok.ok && ok.used == 1 && ok.stateSeq == 5 && ok.headerSeq == 6 && ok.vaultBundle == [0, 1, 2] && ok.releaseNumber == 13)
        #expect(ok.attemptUsed == false)
    }
}

/// The vault's side of §11.14.1 and §11.14.2, for checking the phone's secrets end to end:
/// unlock_key = HKDF-SHA-256(ikm = x || unlock_secret, salt = pepper, info = "vettid/vms/2/unlock-key" || 0x00 || vault_id);
/// secret_check = HMAC-SHA-256(pepper, "vettid/vms/2/unlock-secret-check" || 0x00 || vault_id || 0x00 || unlock_secret).
enum ReleaseRFormula {
    static func derive(x: [UInt8], pepper: [UInt8], vaultID: String, secret: [UInt8]) throws -> (key: [UInt8], check: [UInt8]) {
        let key = try Hkdf.derive(ikm: x + secret, salt: pepper, info: Array("vettid/vms/2/unlock-key".utf8) + [0] + Array(vaultID.utf8), length: 32)
        let check = hmacSHA256(key: pepper, Array("vettid/vms/2/unlock-secret-check".utf8) + [0] + Array(vaultID.utf8) + [0] + secret)
        return (key, check)
    }
}

/// The iPhone's unlock secret (VAULT-MESSAGING 0.35.0 §11.14.1 "On an iPhone"), against the values §16 gives for it
/// (not yet in a vettid-vault vector file): software keys priv(P) = 32 × 0x46, priv(E_1) = 32 × 0x47,
/// priv(E_2) = 32 × 0x48, key_vault "test-vault-0001".
@Suite struct PhoneSecretIOSTests {
    static let keyVault = "test-vault-0001"
    static let pubP = "041bec1250aa8f78275f99a6663688f31085848d0ed92f1203e447125f927b7486976e19d2eecfd3d40f935f10be09e63bcbc8a24a71efb67848d97725c3a0dc73"
    static let pubE1 = "0472dabf79df448c7a5bfaecb7bc0dbc990a0ffd43b7a52b502c860ac0ab8340ff239d8129976e853067907d98c231e9e349f8aedfc1e1ccb2fa47fe4945de2460"
    static let pubE2 = "0442a51e039eb9e0b5ce58c4f1b8ebcb281fae32b90729711640b0cad4fc5c38c1173c7e7b5be6ea94bb10e09fbee7c7b0838f3f4f88e01e911d30e44f4f3e9b32"

    let p: P256.KeyAgreement.PrivateKey
    let e1: P256.KeyAgreement.PrivateKey
    let e2: P256.KeyAgreement.PrivateKey

    init() throws {
        p = try P256.KeyAgreement.PrivateKey(rawRepresentation: rep(0x46, 32))
        e1 = try P256.KeyAgreement.PrivateKey(rawRepresentation: rep(0x47, 32))
        e2 = try P256.KeyAgreement.PrivateKey(rawRepresentation: rep(0x48, 32))
    }

    var phoneKey: [UInt8] { Array(p.publicKey.x963Representation) }

    /// The Secure Enclave's ECDH(priv(P), ·), with the software stand-in.
    func phoneECDH(_ peer: [UInt8]) throws -> [UInt8] {
        try PhoneSecretIOS.softwareECDH(p, try PhoneSecretIOS.publicKey(peer))
    }

    @Test func thePublicKeys() throws {
        #expect(Bytes.hex(phoneKey) == Self.pubP)
        #expect(Bytes.hex(Array(e1.publicKey.x963Representation)) == Self.pubE1)
        #expect(Bytes.hex(Array(e2.publicKey.x963Representation)) == Self.pubE2)
    }

    @Test func infoOfEpochOne() throws {
        let info = try PhoneSecretIOS.info(keyVault: Self.keyVault, epoch: 1, phoneKey: phoneKey, ephemeral: Bytes.unhex(Self.pubE1))
        #expect(info.count == 185)
        #expect(Bytes.hex(info) == "7665747469642f766d732f322f756e6c6f636b2d7365637265742d696f7300746573742d7661756c742d303030310000000000000000" + "01" + Self.pubP + Self.pubE1)
    }

    @Test(arguments: [
        (UInt8(0x47), UInt64(1), "test-vault-0001", "6446035b6d1d9d8c9e9ad89a55f5467c2314c952d343db2598e6d2acd1698d5a", "f3bdc50cabb32a8a89b614ca518b946b4fe255e31dff4b6ac411a9e62b160edd", "264d1e12c9481fc0f7962fcf320303a3"),
        (UInt8(0x48), UInt64(2), "test-vault-0001", "9a93ac29a6e2ebad209fae69db3d3d5c5134cc0b5492479186c53b476ff27a6d", "f8829246f449f3289640772dd12afa4812aab9c01d90b89ab4bbd01a88ede5f2", "6d2551c0f2bdfdf90c83d0f8e0d19fd0"),
        (UInt8(0x47), UInt64(1), "", "6446035b6d1d9d8c9e9ad89a55f5467c2314c952d343db2598e6d2acd1698d5a", "417e8255ff4d7ffb33120f8b5a70d1878f728f597dd5de8c7606565f0d4895cc", "3a12751cd1b3e2a53728adda53e9d401"),
    ])
    func eachEpoch(eByte: UInt8, epoch: UInt64, keyVault: String, z: String, secret: String, check: String) throws { // swiftlint:disable:this function_parameter_count
        let e = try P256.KeyAgreement.PrivateKey(rawRepresentation: rep(eByte, 32))
        let pubE = Array(e.publicKey.x963Representation)
        // Both directions of the ECDH give z_e.
        #expect(Bytes.hex(try PhoneSecretIOS.softwareECDH(e, p.publicKey)) == z)
        #expect(Bytes.hex(try phoneECDH(pubE)) == z)
        let made = try PhoneSecretIOS.newEpoch(keyVault: keyVault, epoch: epoch, phoneKey: phoneKey, ephemeral: e, phoneECDH: phoneECDH)
        #expect(Bytes.hex(made.secret) == secret)
        #expect(Bytes.hex(made.record.check) == check)
        #expect(made.record == PhoneSecretRecord(keyVault: keyVault, epoch: epoch, ephemeral: pubE, check: try Bytes.unhex(check)))
        // At unlock, the record and the Secure Enclave's ECDH give the secret again.
        #expect(Bytes.hex(try PhoneSecretIOS.recompute(made.record, phoneKey: phoneKey, phoneECDH: phoneECDH)) == secret)
    }

    /// §16's end-to-end values: x = 32 × 0x41, pepper = 32 × 0x32, vault_id "test-vault-0001".
    @Test(arguments: [
        ("test-vault-0001", UInt64(1), UInt8(0x47), "c62a381da79b90f73004b06e83e5c50102f0c1af6cef9dade936acf71a87a5e0", "b25667bbca0901faa080ace5d92f317d46adbb0b0543ae227da0f78367526b69"),
        ("test-vault-0001", UInt64(2), UInt8(0x48), "9a179f25ba0cded41d14c6bcb854637df8650645732e7edf2e37ecfca07597ad", "8c1da453b5ab92bf5affdad9c460f0a0b617c8db349bdaade91764f5a89afeac"),
        ("", UInt64(1), UInt8(0x47), "bbf1eb9f19ec263d821395609e266d906c7a8aa4a6c573003df116e241cf9e22", "0eed2888668319b2b085f09d8b94de8c65c3e5b2bfd15cb636e63bd511d1acac"),
    ])
    func endToEnd(keyVault: String, epoch: UInt64, eByte: UInt8, unlockKey: String, secretCheck: String) throws {
        let e = try P256.KeyAgreement.PrivateKey(rawRepresentation: rep(eByte, 32))
        let made = try PhoneSecretIOS.newEpoch(keyVault: keyVault, epoch: epoch, phoneKey: phoneKey, ephemeral: e, phoneECDH: phoneECDH)
        let (key, check) = try ReleaseRFormula.derive(x: rep(0x41, 32), pepper: rep(0x32, 32), vaultID: "test-vault-0001", secret: made.secret)
        #expect(Bytes.hex(key) == unlockKey)
        #expect(Bytes.hex(check) == secretCheck)
    }

    @Test func notTheAndroidForm() throws {
        let made = try PhoneSecretIOS.newEpoch(keyVault: Self.keyVault, epoch: 1, phoneKey: phoneKey, ephemeral: e1, phoneECDH: phoneECDH)
        let android = try UnlockSecret.compute(vaultID: Self.keyVault, epoch: 1) { hmacSHA256(key: rep(0x46, 32), $0) }
        #expect(made.secret != android)
        #expect(PhoneSecretIOS.label != UnlockSecret.label)
    }

    @Test func refusals() throws {
        let good = try Bytes.unhex(Self.pubE1)
        var offCurve = good
        offCurve[64] &+= 1 // x valid, y + 1
        let refused: [(String, [UInt8])] = [
            ("off curve", offCurve),
            ("point at infinity", [0x00]),
            ("infinity, padded", [0x04] + rep(0, 64)),
            ("compressed", [0x02 | (good[64] & 1)] + good[1...32]),
            ("truncated", Array(good.prefix(64))),
        ]
        for (what, pub) in refused {
            expectCrypto(.key, "\(what)") { _ = try PhoneSecretIOS.publicKey(pub) }
            expectCrypto(.key, "\(what) in info") { _ = try PhoneSecretIOS.info(keyVault: Self.keyVault, epoch: 1, phoneKey: phoneKey, ephemeral: pub) }
            let record = PhoneSecretRecord(keyVault: Self.keyVault, epoch: 1, ephemeral: pub, check: rep(0, 16))
            expectCrypto(.key, "\(what) in a record") { _ = try PhoneSecretIOS.recompute(record, phoneKey: phoneKey, phoneECDH: phoneECDH) }
        }
        expectCrypto(.format, "epoch 0") { _ = try PhoneSecretIOS.info(keyVault: Self.keyVault, epoch: 0, phoneKey: phoneKey, ephemeral: good) }
        expectCrypto(.format, "0x00 in key_vault") { _ = try PhoneSecretIOS.info(keyVault: "test\u{0}vault", epoch: 1, phoneKey: phoneKey, ephemeral: good) }
    }

    @Test func aWrongTagOrAFailedConfirmationIsRefused() throws {
        let made = try PhoneSecretIOS.newEpoch(keyVault: Self.keyVault, epoch: 1, phoneKey: phoneKey, ephemeral: e1, phoneECDH: phoneECDH)
        var check = made.record.check
        check[0] ^= 1
        let tampered = PhoneSecretRecord(keyVault: Self.keyVault, epoch: 1, ephemeral: made.record.ephemeral, check: check)
        expectCrypto(.key) { _ = try PhoneSecretIOS.recompute(tampered, phoneKey: phoneKey, phoneECDH: phoneECDH) }
        // A different epoch under the same record keys gives a different secret, so the tag no longer matches.
        let otherEpoch = PhoneSecretRecord(keyVault: Self.keyVault, epoch: 2, ephemeral: made.record.ephemeral, check: made.record.check)
        expectCrypto(.key) { _ = try PhoneSecretIOS.recompute(otherEpoch, phoneKey: phoneKey, phoneECDH: phoneECDH) }
        // A Secure Enclave key that is not P: the confirmation fails before anything is stored.
        expectCrypto(.key) {
            _ = try PhoneSecretIOS.newEpoch(keyVault: Self.keyVault, epoch: 1, phoneKey: phoneKey, ephemeral: e1) { peer in
                try PhoneSecretIOS.softwareECDH(e2, try PhoneSecretIOS.publicKey(peer))
            }
        }
    }

    @Test func theRecordRoundTrips() throws {
        let made = try PhoneSecretIOS.newEpoch(keyVault: Self.keyVault, epoch: 2, phoneKey: phoneKey, ephemeral: e2, phoneECDH: phoneECDH)
        let raw = made.record.marshal()
        let o = try StrictJson.parseObject(raw)
        #expect(try o.uint("v", min: 1, max: 1) == 1)
        #expect(try PhoneSecretRecord.parse(raw) == made.record)
        let text = try #require(String(bytes: raw, encoding: .utf8))
        #expect(text.hasPrefix(#"{"v":1,"key_vault":"test-vault-0001","epoch":2,"pub_e":""#))
        expectCrypto(.format) { _ = try PhoneSecretRecord.parse(Array(#"{"v":2,"key_vault":"","epoch":1,"pub_e":"","check":""}"#.utf8)) }
        let zeroEpoch = text.replacingOccurrences(of: #""epoch":2"#, with: #""epoch":0"#)
        expectCrypto(.format) { _ = try PhoneSecretRecord.parse(Array(zeroEpoch.utf8)) }
    }
}

/// VAULT-MESSAGING 0.33.0 §11.14.7: the app's password rules against vettid-vault's shared verdict file
/// (`testdata/passwords/verdicts.json`), at the vault's floor and at the app's slightly higher one. Mirrors
/// vettid-android `PasswordRulesTest`.
@Suite struct PasswordRulesTests {
    let pin: String
    let cases: [(password: String, verdict: String?)]

    init() throws {
        let doc = try VectorDoc.load("verdicts.json")
        pin = try doc.str("pin")
        cases = try doc.o.array("cases").map { v in
            guard case .object(let c) = v else { throw CryptoError.format("verdict case") }
            let verdict = try c.string("verdict")
            return (try c.string("password"), verdict == "ok" ? nil : verdict)
        }
    }

    @Test func everyVerdictMatchesAtTheVaultsFloor() {
        #expect(cases.count == 16)
        for c in cases {
            #expect(PasswordRules.check(c.password, pin: pin, floor: PasswordRules.vaultFloor) == c.verdict, "\(c.password)")
        }
    }

    @Test func everyVerdictMatchesAtTheAppsHigherFloor() {
        for c in cases { #expect(PasswordRules.check(c.password, pin: pin) == c.verdict, "\(c.password)") }
        #expect(PasswordRules.appFloor > PasswordRules.vaultFloor)
    }

    @Test func thePinAndCharactersNotBytes() {
        #expect(PasswordRules.check("135792468024", pin: "135792468024", floor: PasswordRules.vaultFloor) == PasswordRules.sameAsPin)
        // Twelve characters of which some take several bytes: long enough by characters.
        #expect(PasswordRules.check("ünïcödé-Qx7#mñ", pin: nil) != PasswordRules.short)
        #expect(PasswordRules.check("ééééééééééé", pin: nil) == PasswordRules.short)
    }
}

// swiftlint:enable line_length
