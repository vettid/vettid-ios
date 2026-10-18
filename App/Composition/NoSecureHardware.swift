import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys

/// The keys and App Attest of a device without a Secure Enclave or App Attest (the simulator, an unsupported device):
/// every key operation refuses with ``KeysError/noSecureHardware``, which the screens show as "This phone cannot keep
/// your vault's keys in its secure hardware." (``FailureKind/hardwareKeys``), before anything is made or sent
/// (IOS-PLAN §6.2, §6.3). No software key is linked into any build of the app (IOS-PLAN §6.3: never into Release or
/// Staging; XcodeGen links a package product for every configuration of a target alike, so Debug and DevStack refuse
/// too). The simulator's dev stack will use VettIDAltChanTesting's TEST iOS attester and VettIDKeysTesting's software
/// keys once an app target of its own, built only in the DevStack configuration, links them.
struct NoSecureHardware: AppKeyStore, SeedWrapKeySource, PhoneSecretSource, Attester {
    /// One phone key source serves one records file (``PhoneSecretSource``): the app's own, unless a test names another.
    let sourceID: String

    init(sourceID: String = "vettid.no-secure-enclave") {
        self.sourceID = sourceID
    }

    /// What a lookup answers. On the simulator nothing is held: missing. On an iPhone this placeholder is never chosen
    /// while a Secure Enclave is reported, so it may stand in for keys it cannot see: a lookup is refused for now, never
    /// "missing", so that nothing is declared lost or rewritten on its answer.
    static var absent: ItemLookupAnswer {
        #if targetEnvironment(simulator)
        .missing
        #else
        .unavailable
        #endif
    }

    enum ItemLookupAnswer {
        case missing
        case unavailable

        func lookup<T>() -> ItemLookup<T> { self == .missing ? .missing : .unavailable }
    }

    // AppKeyStore.
    func getOrCreate() throws -> any AppSigningKey { throw KeysError.noSecureHardware }
    func regenerate() throws -> any AppSigningKey { throw KeysError.noSecureHardware }
    func lookup() -> ItemLookup<any AppSigningKey> { Self.absent.lookup() }

    // SeedWrapKeySource.
    func getOrCreate() throws -> any KeyAgreementKey { throw KeysError.noSecureHardware }

    // PhoneSecretSource.
    func create(keyVault: String) throws -> (keyID: String, key: any KeyAgreementKey) { throw KeysError.noSecureHardware }
    func lookup(keyVault: String, keyID: String) -> ItemLookup<any KeyAgreementKey> { Self.absent.lookup() }
    func delete(keyVault: String, keyID: String) throws {}
    func keyNames() throws -> [PhoneKeyName] {
        guard Self.absent == .missing else { throw KeysError.unavailable("phone keys") }
        return []
    }

    // KeyEraser: there is nothing to erase.
    func deleteAll() throws {}

    // Attester.
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { throw KeysError.noSecureHardware }
    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { throw KeysError.noSecureHardware }
}

/// The app-lock key without a Secure Enclave: no key can be made, so the app lock cannot be turned on and stays off.
/// Never in place of the PIN or the password either way (IOS-PLAN ID17).
struct NoAppLockKeys: AppLockKeys {
    func create(_ method: AppLockMethod) throws { throw KeysError.noSecureHardware }
    func exists() -> Bool { false }
    func seal(_ plaintext: [UInt8]) throws -> [UInt8] { throw KeysError.noSecureHardware }
    func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] { throw AppLockKeyError.invalidated }
    func delete() throws {}
}
