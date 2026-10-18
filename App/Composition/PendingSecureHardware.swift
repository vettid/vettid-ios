import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys

/// The Secure Enclave keys and App Attest until they arrive (I1.4b; the dev stack's TEST attester: a DevStack app
/// target): every key operation refuses with ``KeysError/noSecureHardware``, which the screens show as "This phone cannot
/// keep your vault's keys in its secure hardware." (``FailureKind/hardwareKeys``), before anything is made or sent. No
/// software key is linked into any build of the app (IOS-PLAN §6.3: never into Release or Staging; XcodeGen links a
/// package product for every configuration of a target alike, so Debug and DevStack refuse too).
///
/// Replaced by I1.4b (the Secure Enclave app key, seed-wrapping key and phone key, and the App Attest attester) and, for
/// the dev stack on the simulator, by VettIDAltChanTesting's TEST iOS attester and VettIDKeysTesting's software keys,
/// once an app target of its own, built only in the DevStack configuration, links them (TEST ONLY products are never
/// linked into this target, whose Release and Staging builds the release check scans).
struct PendingSecureHardware: AppKeyStore, SeedWrapKeySource, PhoneSecretSource, Attester {
    /// One phone key source serves one records file (``PhoneSecretSource``): the app's own, unless a test names another.
    let sourceID: String

    init(sourceID: String = "vettid.pending-secure-enclave") {
        self.sourceID = sourceID
    }

    // AppKeyStore.
    func getOrCreate() throws -> any AppSigningKey { throw KeysError.noSecureHardware }
    func regenerate() throws -> any AppSigningKey { throw KeysError.noSecureHardware }
    func lookup() -> ItemLookup<any AppSigningKey> { .missing }

    // SeedWrapKeySource.
    func getOrCreate() throws -> any KeyAgreementKey { throw KeysError.noSecureHardware }

    // PhoneSecretSource.
    func create(keyVault: String) throws -> (keyID: String, key: any KeyAgreementKey) { throw KeysError.noSecureHardware }
    func lookup(keyVault: String, keyID: String) -> ItemLookup<any KeyAgreementKey> { .missing }
    func delete(keyVault: String, keyID: String) throws {}
    func keyNames() throws -> [PhoneKeyName] { [] }

    // KeyEraser: there is nothing to erase.
    func deleteAll() throws {}

    // Attester.
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { throw KeysError.noSecureHardware }
    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { throw KeysError.noSecureHardware }
}
