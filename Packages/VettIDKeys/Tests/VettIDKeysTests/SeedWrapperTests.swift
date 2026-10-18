import CryptoKit
import Foundation
import Testing
import VettIDCrypto
@testable import VettIDKeys
import VettIDKeysTesting

/// The wrap format with a software key-agreement key standing in for the Secure Enclave key. Mirrors vettid-android
/// `SeedWrapperTest`.
@Suite struct SeedWrapperTests {
    let source = SoftwareSeedWrapKeySource()
    var wrapper: SeedWrapper { SeedWrapper(source: source) }

    @Test func roundTripAndBinding() throws {
        let seed = (0 ..< 32).map { UInt8($0) }
        let blob = try wrapper.wrap(.identity, seed)
        #expect(blob.count == 1 + 12 + 32 + 16)
        #expect(blob[0] == 1)
        #expect(try wrapper.unwrap(.identity, blob) == seed)
        // Randomized: wrapping twice gives different blobs.
        #expect(try wrapper.wrap(.identity, seed) != blob)
        // Bound to the slot: a relay blob does not unwrap as the identity.
        #expect(throws: KeysError.corrupt("wrapped relay key")) { try wrapper.unwrap(.relay, blob) }
        // Tampering, truncation, another key.
        var tampered = blob
        tampered[20] &+= 1
        #expect(throws: KeysError.self) { try wrapper.unwrap(.identity, tampered) }
        #expect(throws: KeysError.self) { try wrapper.unwrap(.identity, Array(blob.prefix(20))) }
        // Another format byte: its own error (a newer app's blob), never "damaged".
        var newer = blob
        newer[0] = 0x02
        #expect(throws: KeysError.unknownFormat("wrapped identity key")) { try wrapper.unwrap(.identity, newer) }
        #expect(throws: KeysError.corrupt("wrapped identity key")) { try wrapper.unwrap(.identity, []) }
        let other = SeedWrapper(source: SoftwareSeedWrapKeySource())
        #expect(throws: KeysError.self) { try other.unwrap(.identity, blob) }
    }

    /// The wrapping key is HKDF of the key's agreement with its own public key, so the same hardware key always gives it.
    @Test func theWrappingKeyComesFromTheKeyAgreement() throws {
        let key = try SoftwareKeyAgreementKey(raw: [UInt8](repeating: 0x49, count: 32))
        let w = SeedWrapper { key }
        let blob = try w.wrap(.kem, [UInt8](repeating: 7, count: 32))
        let z = try key.agree(try key.publicKey())
        let k = SymmetricKey(data: try Hkdf.derive(ikm: z, salt: [], info: Array("vettid/ios/seed-wrap/1".utf8), length: 32))
        let aad = Array("vettid/keystore/1".utf8) + [0] + Array("kem".utf8)
        #expect(try AesGcmBlob.open(k, aad: aad, blob, what: "test") == [UInt8](repeating: 7, count: 32))
        // A key that is locked or invalid gives no seed, with its own error.
        key.state.behaviour = .locked
        #expect(throws: KeysError.unavailable("key agreement key")) { try w.unwrap(.kem, blob) }
        key.state.behaviour = .invalid
        #expect(throws: KeysError.invalid("key agreement key")) { try w.unwrap(.kem, blob) }
    }

    @Test func deviceKeys() throws {
        let store = InMemoryWrappedKeyStore()
        let keys = DeviceKeys(wrapper: wrapper, store: store)
        for slot in KeySlot.allCases { try keys.generate(slot) }
        #expect(try KeySlot.allCases.allSatisfy { try keys.has($0) })
        let relay = try keys.ed25519(.relay)
        let ik = try keys.ed25519(.identity)
        let kem = try keys.kem()
        #expect(relay.publicKey != ik.publicKey)
        // Unwrapping again yields the same keys.
        #expect(try keys.ed25519(.identity).publicKey == ik.publicKey)
        #expect(try keys.kem().publicKey == kem.publicKey)
        // The stored blobs hold no seed in the clear.
        let seed = try ik.seed()
        #expect(store.all.allSatisfy { blob in !(0 ... blob.count - 32).contains { Array(blob[$0 ..< $0 + 32]) == seed } })
        try keys.clear()
        #expect(throws: KeysError.missing("identity key")) { try keys.ed25519(.identity) }
        #expect(throws: KeysError.missing("kem key")) { try keys.kem() }
    }
}
