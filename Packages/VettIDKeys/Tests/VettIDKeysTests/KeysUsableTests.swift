import CryptoKit
import Foundation
import Testing
import VettIDCrypto
@testable import VettIDKeys
import VettIDKeysTesting

/// The "keys usable" check (IOS-PLAN §6.1): each key must sign or agree once, not only exist; a locked key is refused for
/// now, never lost.
@Suite struct KeysUsableTests {
    @Test func theAppKeySignsOnce() throws {
        let store = SoftwareAppKeyStore()
        #expect(KeysUsableCheck.appKey(store) == .lost)
        let key = try store.getOrCreate()
        #expect(KeysUsableCheck.appKey(store) == .usable)
        // The same key until regenerated; akid is the first 16 bytes of SHA-256(SPKI).
        #expect(try store.getOrCreate().spki() == key.spki())
        #expect(try key.akid() == Bytes.hex(Array(Bytes.sha256(try key.spki()).prefix(16))))
        #expect(try store.regenerate().spki() != key.spki())
        store.current?.state.behaviour = .locked
        #expect(KeysUsableCheck.appKey(store) == .unavailable)
        store.current?.state.behaviour = .invalid
        #expect(KeysUsableCheck.appKey(store) == .lost)
        store.current?.state.behaviour = .normal
        store.source.behaviour = .locked
        #expect(KeysUsableCheck.appKey(store) == .unavailable)
        store.source.behaviour = .normal
        try store.deleteAll()
        #expect(KeysUsableCheck.appKey(store) == .lost)
    }

    /// A signature that does not verify under the stored SPKI (a key that came back without its private half).
    @Test func aKeyWhoseSignatureDoesNotVerifyIsLost() throws {
        struct Mismatched: AppKeyStore {
            let a = SoftwareAppSigningKey()
            let b = SoftwareAppSigningKey()
            func getOrCreate() throws -> any AppSigningKey { Pair(spkiOf: a, signer: b) }
            func regenerate() throws -> any AppSigningKey { try getOrCreate() }
            func lookup() -> ItemLookup<any AppSigningKey> { .found(Pair(spkiOf: a, signer: b)) }
            func deleteAll() throws {}
        }
        struct Pair: AppSigningKey {
            let spkiOf: SoftwareAppSigningKey
            let signer: SoftwareAppSigningKey
            func spki() throws -> [UInt8] { try spkiOf.spki() }
            func sign(_ message: [UInt8]) throws -> [UInt8] { try signer.sign(message) }
        }
        #expect(KeysUsableCheck.appKey(Mismatched()) == .lost)
    }

    @Test func aKeyAgreementKeyAgreesOnce() throws {
        let source = SoftwarePhoneSecretSource()
        #expect(KeysUsableCheck.agreement(source.lookup(keyVault: "v1", keyID: "none")) == .lost)
        let id = try source.create(keyVault: "v1").keyID
        #expect(KeysUsableCheck.agreement(source.lookup(keyVault: "v1", keyID: id)) == .usable)
        #expect(source.key("v1")?.agreements == 1)
        source.key("v1")?.state.behaviour = .locked
        #expect(KeysUsableCheck.agreement(source.lookup(keyVault: "v1", keyID: id)) == .unavailable)
        source.key("v1")?.state.behaviour = .invalid
        #expect(KeysUsableCheck.agreement(source.lookup(keyVault: "v1", keyID: id)) == .lost)
        source.source.behaviour = .locked
        #expect(KeysUsableCheck.agreement(source.lookup(keyVault: "v1", keyID: id)) == .unavailable)
    }

    @Test func theVerdictOverSeveralKeys() {
        #expect(KeysUsability.combine([.usable, .usable]) == .usable)
        #expect(KeysUsability.combine([.usable, .unavailable]) == .unavailable)
        #expect(KeysUsability.combine([.unavailable, .lost]) == .lost)
        #expect(KeysUsability.of(KeysError.unavailable("x")) == .unavailable)
        #expect(KeysUsability.of(KeysError.noSecureHardware) == .unavailable)
        #expect(KeysUsability.of(KeysError.missing("x")) == .lost)
        #expect(KeysUsability.of(KeysError.invalid("x")) == .lost)
        // Only an explicit missing or invalid key, or a blob that fails authentication, is a loss; anything else is refused
        // for now.
        #expect(KeysUsability.of(KeysError.corrupt("x")) == .lost)
        #expect(KeysUsability.of(KeysError.unknownFormat("x")) == .unknownFormat)
        #expect(KeysUsability.of(CocoaError(.fileReadUnknown)) == .unavailable)
        #expect(KeysUsability.of(CryptoKitError.incorrectKeySize) == .unavailable)
        #expect(KeysUsability.of(CryptoError.decrypt) == .unavailable)
        #expect(KeysUsability.combine([.lost, .unknownFormat]) == .unknownFormat)
    }

    /// Every ECDH input is a full SEC1 point; anything else counts as keys that no longer work.
    @Test func peersAreParsedWithFullPointValidation() throws {
        let k = SoftwareKeyAgreementKey()
        var bad = try k.publicKey()
        bad[64] ^= 1
        #expect(throws: KeysError.invalid("peer point")) { try k.agree(bad) }
        #expect(throws: KeysError.invalid("peer point")) { try k.agree(Array(bad.prefix(33))) }
        #expect(throws: KeysError.invalid("peer point")) { try k.agree([0]) }
    }

    @Test func theSoftwareKeysCarryTheReleaseCheckMarker() {
        #expect(SoftwareKeys.testOnlyMarker.hasPrefix("VETTID TEST ONLY"))
        #expect(SoftwareKeyState().description == SoftwareKeys.testOnlyMarker)
    }
}
