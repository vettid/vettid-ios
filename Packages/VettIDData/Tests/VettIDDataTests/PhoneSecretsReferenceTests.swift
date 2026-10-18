import CryptoKit
import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// `PhoneSecrets` with the software phone key against the Go reference (`Resources/reference/phone_ios.json`, the values
/// of VAULT-MESSAGING §16 for §11.14.1 "On an iPhone"): every intermediate value byte for byte, ECDH in both directions,
/// the records it writes, the end-to-end unlock key, secret check and `dek_wrap`, and the refusals.
@Suite struct PhoneSecretsReferenceTests {
    let doc: ReferenceDoc
    let epochs: [JsonObject]

    init() throws {
        doc = try ReferenceDoc.load("phone_ios.json")
        epochs = try doc.o.array("epochs").map { try $0.asObject() }
    }

    /// The phone with priv(P) from the reference and each new epoch's E from [privE], in order.
    func phone(_ privE: [[UInt8]]) throws -> TestPhone {
        let p = try doc.hex("priv_p_hex")
        let queue = EphemeralQueue(privE)
        return try TestPhone(keys: SoftwarePhoneSecretSource { try SoftwareKeyAgreementKey(raw: p) }, ephemeral: { queue.next() })
    }

    @Test func everyIntermediateValueMatches() throws {
        #expect(try doc.o.string("vettid_vault_commit") == "057236379992e48e7f356b4994fc2d11c174d365")
        let p = try P256.KeyAgreement.PrivateKey(rawRepresentation: try doc.hex("priv_p_hex"))
        let pubP = Array(p.publicKey.x963Representation)
        #expect(pubP == (try doc.hex("pub_p_hex")))
        for e in epochs {
            let privE = try P256.KeyAgreement.PrivateKey(rawRepresentation: try e.hex("priv_e_hex"))
            let pubE = Array(privE.publicKey.x963Representation)
            #expect(pubE == (try e.hex("pub_e_hex")))
            // ECDH in both directions.
            #expect(try SoftwareECDH.agree(privE, pubP) == e.hex("z_hex"))
            #expect(try SoftwareECDH.agree(p, pubE) == e.hex("z_hex"))
            let epoch = try e.uint("epoch", min: 1, max: 2)
            let info = try PhoneSecretIOS.info(keyVault: try e.string("key_vault"), epoch: epoch, phoneKey: pubP, ephemeral: pubE)
            #expect(Bytes.hex(info) == (try e.string("info_hex")))
            let secret = try PhoneSecretIOS.secret(z: try e.hex("z_hex"), info: info)
            #expect(secret == (try e.hex("unlock_secret_hex")))
            #expect(PhoneSecretIOS.check(secret) == (try e.hex("check_hex")))
            // Not the Android form for the same key bytes and epoch.
            #expect(secret != (try e.hex("android_form_hex")))
        }
    }

    /// Enrollment (epoch 1) and a renew (epoch 2) through `PhoneSecrets`, and a transfer's new phone (`key_vault` "").
    @Test func phoneSecretsMakesTheReferenceSecretsAndRecords() async throws {
        let (e1, e2, empty) = (epochs[0], epochs[1], epochs[2])
        let t = try phone([try e1.hex("priv_e_hex"), try e2.hex("priv_e_hex")])
        let s1 = try t.secrets.createConfirmed(keyVault: try e1.string("key_vault"))
        #expect(s1 == (try e1.hex("unlock_secret_hex")))
        let rec1 = try #require(try t.records.current)
        #expect(rec1.epoch == 1)
        #expect(try rec1.ephemeral == e1.hex("pub_e_hex"))
        #expect(try rec1.check == e1.hex("check_hex"))
        let s2 = try t.secrets.beginChange(operation: "renew-1")
        #expect(s2 == (try e2.hex("unlock_secret_hex")))
        #expect(try t.records.candidates.map(\.entry.record.check) == [try e2.hex("check_hex")])
        try t.secrets.confirmChange(operation: "renew-1")
        #expect(try t.secrets.currentSecret() == e2.hex("unlock_secret_hex"))
        // The reopened app recomputes the same secret from the stored record.
        t.reopen()
        #expect(try t.secrets.currentSecret() == e2.hex("unlock_secret_hex"))

        let n = try phone([try empty.hex("priv_e_hex")])
        #expect(try n.secrets.createConfirmed(keyVault: "") == empty.hex("unlock_secret_hex"))
        #expect(try n.records.current?.keyVault == "")
        #expect(try n.records.current?.check == empty.hex("check_hex"))
    }

    /// The iPhone secrets through the vault's unchanged formulas: unlock key, secret check, and a `dek_wrap` that opens.
    @Test func theSecretsWorkWithTheVaultsFormulas() throws {
        let x = try doc.hex("x_hex")
        let pepper = try doc.hex("pepper_hex")
        let vault = try doc.o.string("vault_id")
        let version = try doc.o.uint("dek_version", min: 1, max: 1)
        for e in epochs {
            let secret = try e.hex("unlock_secret_hex")
            let info = Array("vettid/vms/2/unlock-key".utf8) + [0] + Array(vault.utf8)
            let key = try Hkdf.derive(ikm: x + secret, salt: pepper, info: info, length: 32)
            #expect(key == (try e.hex("unlock_key_hex")))
            let check = hmacSHA256(key: pepper, Array("vettid/vms/2/unlock-secret-check".utf8) + [0] + Array(vault.utf8) + [0] + secret)
            #expect(check == (try e.hex("secret_check_hex")))
            let wrap = try e.hex("dek_wrap_hex")
            #expect(Array(wrap.prefix(24)) == (try doc.hex("nonce_hex")))
            let aad = Array("vettid/vms/2/dek-wrap".utf8) + [0] + Array(vault.utf8) + [0] + Bytes.uintBE(version, 8)
            let dek = try XChaCha20Poly1305.open(key: key, nonce: Array(wrap.prefix(24)), aad: aad, ciphertext: Array(wrap.dropFirst(24)))
            #expect(dek == (try doc.hex("dek_hex")))
        }
    }

    /// Every refused encoding of pub(E): refused when parsed, and a stored record carrying it is a lost key, never a
    /// secret. Epoch 0 and a `key_vault` with 0x00 are refused too.
    @Test func theRefusals() throws {
        let pubP = try doc.hex("pub_p_hex")
        let refusals = try doc.o.array("refusals").map { try $0.asObject() }
        #expect(refusals.count == 7)
        let t = try phone([try epochs[0].hex("priv_e_hex")])
        _ = try t.secrets.createConfirmed(keyVault: "test-vault-0001")
        let good = try #require(try t.records.current)
        for r in refusals {
            let pub = try r.hex("pub_e_hex")
            #expect(throws: CryptoError.self) { try PhoneSecretIOS.publicKey(pub) }
            #expect(throws: KeysError.invalid("peer point")) { try SoftwareECDH.publicKey(pub) }
            #expect(throws: CryptoError.self) {
                try PhoneSecretIOS.info(keyVault: "test-vault-0001", epoch: 1, phoneKey: pubP, ephemeral: pub)
            }
            // The record format holds 65-byte points only; a stored 65-byte point that is refused gives "this phone no
            // longer holds the keys", never a secret.
            guard pub.count == PhoneSecretIOS.publicKeySize else { continue }
            let bad = PhoneRecords.Entry(keyID: good.keyID, record: PhoneSecretRecord(
                keyVault: good.keyVault, epoch: 1, ephemeral: pub, check: good.check))
            #expect(failureKind { try t.secrets.secret(of: bad) } == .deviceSecret)
        }
        #expect(throws: CryptoError.format("phone secret input")) {
            try PhoneSecretIOS.info(keyVault: "test-vault-0001", epoch: 0, phoneKey: pubP, ephemeral: good.ephemeral)
        }
        #expect(throws: CryptoError.format("phone secret input")) {
            try PhoneSecretIOS.info(keyVault: "test\u{0}vault", epoch: 1, phoneKey: pubP, ephemeral: good.ephemeral)
        }
    }
}

/// Fixed ephemeral keys handed out in order.
final class EphemeralQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [[UInt8]]

    init(_ keys: [[UInt8]]) {
        left = keys
    }

    func next() -> P256.KeyAgreement.PrivateKey {
        lock.withLock {
            guard !left.isEmpty else { return P256.KeyAgreement.PrivateKey() }
            // Force-try: the test keys are valid scalars.
            return try! P256.KeyAgreement.PrivateKey(rawRepresentation: left.removeFirst()) // swiftlint:disable:this force_try
        }
    }
}

/// The failure kind [body] throws, if it throws a `VaultFailure`.
func failureKind(_ body: () throws -> some Any) -> FailureKind? {
    do {
        _ = try body()
        return nil
    } catch let f as VaultFailure {
        return f.kind
    } catch {
        return nil
    }
}

func failureKind(_ body: () async throws -> some Any) async -> FailureKind? {
    do {
        _ = try await body()
        return nil
    } catch let f as VaultFailure {
        return f.kind
    } catch {
        return nil
    }
}
