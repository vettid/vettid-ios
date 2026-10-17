import Foundation
import Testing
@testable import VettIDCrypto

/// Mirrors vettid-android `PrimitivesTest` (the HPKE and KEM cases come with I0.4).
struct PrimitivesTests {
    @Test func hkdfRFC5869Case1() throws {
        let ikm = rep(0x0B, 22)
        let salt = try Bytes.unhex("000102030405060708090a0b0c")
        let info = try Bytes.unhex("f0f1f2f3f4f5f6f7f8f9")
        let prk = Hkdf.extract(salt: salt, ikm: ikm)
        #expect(Bytes.hex(prk) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        #expect(
            Bytes.hex(try Hkdf.expand(prk: prk, info: info, length: 42)) ==
                "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        )
        let okm = try Hkdf.expand(prk: prk, info: info, length: 42)
        #expect(try Hkdf.derive(ikm: ikm, salt: salt, info: info, length: 42) == okm)
        expectCrypto(.key) { _ = try Hkdf.expand(prk: prk, info: [], length: 255 * 32 + 1) }
    }

    @Test func hkdfRFC5869Case3EmptySaltAndInfo() throws {
        let prk = Hkdf.extract(salt: [], ikm: rep(0x0B, 22))
        #expect(Bytes.hex(prk) == "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
        #expect(
            Bytes.hex(try Hkdf.expand(prk: prk, info: [], length: 42)) ==
                "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
        )
    }

    @Test func xchachaDraftVector() throws {
        // draft-irtf-cfrg-xchacha-03, A.3.1.
        let pt = Array(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8
        )
        let aad = try Bytes.unhex("50515253c0c1c2c3c4c5c6c7")
        let key = (0..<32).map { UInt8(0x80 + $0) }
        let nonce = (0..<24).map { UInt8(0x40 + $0) }
        var ct = try XChaCha20Poly1305.seal(key: key, nonce: nonce, aad: aad, plaintext: pt)
        #expect(
            Bytes.hex(ct) ==
                "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb" +
                "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4" +
                "522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e" +
                "c0875924c1c7987947deafd8780acf49"
        )
        #expect(try XChaCha20Poly1305.open(key: key, nonce: nonce, aad: aad, ciphertext: ct) == pt)
        ct[3] ^= 1
        expectCrypto(.decrypt) { _ = try XChaCha20Poly1305.open(key: key, nonce: nonce, aad: aad, ciphertext: ct) }
        expectCrypto(.decrypt) { _ = try XChaCha20Poly1305.open(key: key, nonce: nonce, aad: aad, ciphertext: rep(0, 15)) }
        expectCrypto(.key) { _ = try XChaCha20Poly1305.seal(key: rep(0, 31), nonce: nonce, aad: aad, plaintext: [1]) }
    }

    /// The phc-winner-argon2 reference vector (test.c: argon2id v19, t=2, m=2^16 KiB, p=1, "password", "somesalt")
    /// has an 8-byte salt, which libsodium's API does not take. Go's golang.org/x/crypto/argon2 (v0.58.0) reproduces
    /// that reference (09316115…3cf7), and gave these values for the 16-byte salt "somesaltsomesalt": a cross-check
    /// of libsodium against an independent implementation.
    @Test func argon2idAgainstAnIndependentImplementation() throws {
        let salt = Array("somesaltsomesalt".utf8)
        let a = try Argon2id.derive(password: Array("password".utf8), salt: salt, t: 2, mKiB: 65_536, p: 1)
        #expect(Bytes.hex(a) == "fc33b78139231d34b71626bd6245c1d72efa190ad605c3d8166a72adcedfa2c2")
        let b = try Argon2id.derive(password: Array("password".utf8), salt: salt, t: 3, mKiB: 8192, p: 1)
        #expect(Bytes.hex(b) == "02950b5580d9c4909f78967fb3a6bfe9f0839ed64b932b118aba21ec89705b29")
        expectCrypto(.key) { try Argon2id.checkParams(t: 0, mKiB: 65_536, p: 1) }
        expectCrypto(.key) { try Argon2id.checkParams(t: 3, mKiB: 8191, p: 1) }
        expectCrypto(.key) { _ = try Argon2id.derive(password: [], salt: Array("somesalt".utf8), t: 1, mKiB: 8192) }
        expectCrypto(.key) { _ = try Argon2id.derive(password: [], salt: salt, t: 1, mKiB: 65_536, p: 2) }
        // An empty password is a value like any other.
        #expect(try Argon2id.derive(password: [], salt: salt, t: 1, mKiB: 8192).count == 32)
    }

    @Test func ed25519LabelsAndStrictness() throws {
        let k = try Ed25519PrivateKey.fromSeed(rep(4, 32))
        let m = Array("m".utf8)
        let sig = try k.sign(label: "vettid/vms/2/test", m)
        #expect(Ed25519.verify(k.publicKey, label: "vettid/vms/2/test", m, sig))
        #expect(!Ed25519.verify(k.publicKey, label: "vettid/vms/2/other", m, sig))
        #expect(!Ed25519.verify(Array(k.publicKey.prefix(31)), label: "vettid/vms/2/test", m, sig))
        // Deterministic: the same signature every time.
        #expect(try k.sign(label: "vettid/vms/2/test", m) == sig)
        // Non-canonical S (S + L) is rejected.
        let l = try Bytes.unhex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
        var s = Array(sig[32..<64])
        var carry = 0
        for i in 0..<32 {
            let v = Int(s[i]) + Int(l[i]) + carry
            s[i] = UInt8(truncatingIfNeeded: v)
            carry = v >> 8
        }
        #expect(!Ed25519.verify(k.publicKey, label: "vettid/vms/2/test", m, Array(sig.prefix(32)) + s))
        k.destroy()
        expectCrypto(.key) { _ = try k.sign(label: "x", []) }
        #expect(k.description == "Ed25519PrivateKey[redacted]")
        expectCrypto(.key) { _ = try Ed25519PrivateKey.fromSeed(rep(4, 31)) }
    }

    @Test func ed25519RFC8032Test1() throws {
        // RFC 8032 §7.1, TEST 1 (empty message, no label).
        let seed = try Bytes.unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let k = try Ed25519PrivateKey.fromSeed(seed)
        #expect(Bytes.hex(k.publicKey) == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        #expect(
            Bytes.hex(try k.signRaw([])) ==
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
                "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
        )
    }

    @Test func x25519RFC7748() throws {
        // RFC 7748 §6.1.
        let a = try Bytes.unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let b = try Bytes.unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        #expect(Bytes.hex(try X25519.publicKey(a)) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(Bytes.hex(try X25519.publicKey(b)) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        #expect(Bytes.hex(try X25519.sharedSecret(a, X25519.publicKey(b))) == shared)
        #expect(Bytes.hex(try X25519.sharedSecret(b, X25519.publicKey(a))) == shared)
        // A small-order public key (here zero) gives the all-zero secret: refused.
        expectCrypto(.key) { _ = try X25519.sharedSecret(a, rep(0, 32)) }
        expectCrypto(.key) { _ = try X25519.publicKey(rep(1, 31)) }
    }

    @Test func base64IsCanonical() throws {
        #expect(Base64s.encodeStd([1, 2]) == "AQI=")
        #expect(try Base64s.decodeStd("AQI=") == [1, 2])
        for bad in ["AQI", "AQJ=", "AQI=\n", "AQ\r\nI=", "AQI==", "A-I="] {
            expectCrypto(.format, "\(bad)") { _ = try Base64s.decodeStd(bad) }
        }
        expectCrypto(.format) { _ = try Base64s.decodeStd("AQI=", 3) }
        #expect(Base64s.encodeRawUrl([0xFF, 0xEF]) == "_-8")
        expectCrypto(.format) { _ = try Base64s.decodeRawUrl("_-8=") }
        expectCrypto(.format) { _ = try Base64s.decodeRawUrl("_-9") }
        #expect(try Base64s.decodeRawUrl("_-8") == [0xFF, 0xEF])
        #expect(try Base64s.decodeStd("") == [])
    }

    @Test func constantTimeHelpers() throws {
        #expect(Bytes.constantTimeEquals([1, 2], [1, 2]))
        #expect(!Bytes.constantTimeEquals([1, 2], [1, 3]))
        #expect(!Bytes.constantTimeEquals([1, 2], [1, 2, 3]))
        #expect(!Bytes.constantTimeEquals(nil, []))
        var b: [UInt8] = [1, 2, 3]
        Bytes.wipe(&b)
        #expect(b == [0, 0, 0])
        expectCrypto(.format) { _ = try Bytes.unhex("0G") }
        expectCrypto(.format) { _ = try Bytes.unhex("0A") } // lowercase only
        #expect(Bytes.uintBE(0x0102, 4) == [0, 0, 1, 2])
        #expect(Bytes.readUintBE([9, 0, 0, 1, 2], 1, 4) == 0x0102)
    }

    @Test func suiteNegotiation() throws {
        #expect(try Suite.negotiate([2], pinned: 0) == 2)
        #expect(try Suite.negotiate([2, 3, 9], pinned: 0) == 2)
        expectCrypto(.suite) { _ = try Suite.negotiate([1, 2], pinned: 0) }
        expectCrypto(.suite) { _ = try Suite.negotiate([3, 2], pinned: 0) }
        expectCrypto(.suite) { _ = try Suite.negotiate([], pinned: 0) }
        expectCrypto(.suite) { _ = try Suite.negotiate(Array(2...10), pinned: 0) }
        expectCrypto(.suite) { _ = try Suite.negotiate([2], pinned: 3) } // downgrade
        expectCrypto(.suite) { try Suite.checkChosen(2, offered: [3], pinned: 0) }
        expectCrypto(.suite) { try Suite.check(1, pinned: 0) }
    }

    @Test func randomnessDrawsAndTheTestHook() {
        #expect(Randomness.bytes(32).count == 32)
        #expect(Randomness.bytes(32) != Randomness.bytes(32))
        #expect(deterministic([7, 7, 7]) { Randomness.bytes(3) } == [7, 7, 7])
        // Outside the block, real randomness again.
        #expect(Randomness.bytes(3) != [7, 7, 7] || Randomness.bytes(3) != [7, 7, 7])
    }

    @Test func kids() throws {
        let k = try Kid.parseHex("40d6c2c8471844a9")
        #expect(k.description == "40d6c2c8471844a9")
        #expect(!k.isAnonymous)
        #expect(Kid.anonymous.isAnonymous)
        #expect(k == (try Kid(Bytes.unhex("40d6c2c8471844a9"))))
        expectCrypto(.format) { _ = try Kid.parseHex("40D6C2C8471844A9") }
        expectCrypto(.format) { _ = try Kid.parseHex("40d6c2c8471844") }
        expectCrypto(.key) { _ = try Kid([1, 2, 3]) }
    }
}
