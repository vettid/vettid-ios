import CryptoKit
import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys

/// The hardware keys the app runs on (IOS-PLAN §6.1–§6.3): the Secure Enclave's app key, seed-wrapping key, phone keys
/// and app-lock key, and App Attest, when this iPhone has a Secure Enclave; otherwise (the simulator, a device without
/// one) ``NoSecureHardware``, which refuses before anything is made or sent.
struct HardwareKeys {
    let appKeys: any AppKeyStore
    let seedWrap: any SeedWrapKeySource
    let phone: any PhoneSecretSource
    let attester: any Attester
    let appLock: any AppLockKeys
    /// What the first-run cleanup and a wipe erase through the key protocols, after ``KeychainEraser``.
    let erasers: [any KeyEraser]

    /// Whether this device has a Secure Enclave: its keys are chosen on that alone, so that a phone where App Attest is
    /// unsupported still finds its keys (the App Attest key refuses each call itself, before anything is sent). Never
    /// the simulator: it reports a Secure Enclave whose keys ignore the access control's protection class.
    static var available: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    /// [startOver]: whether no vault can hold an App Attest key of this phone, which the vault manager keeps current.
    static func current(protectedData: any ProtectedData, startOver: AttestStartOver) -> HardwareKeys {
        available ? secureEnclave(protectedData: protectedData, startOver: startOver) : none()
    }

    /// The Secure Enclave and App Attest, under the app's own tags and keychain items.
    static func secureEnclave(protectedData: any ProtectedData, startOver: AttestStartOver) -> HardwareKeys {
        let appKeys = SecureEnclaveAppKeyStore(protectedData: protectedData)
        let seedWrap = SecureEnclaveSeedWrapKeySource(protectedData: protectedData)
        let phone = SecureEnclavePhoneSecretSource(protectedData: protectedData)
        let attest = AppAttestKey(
            service: DeviceCheckAppAttestService(), keyID: KeychainKeyIDStore(protectedData: protectedData),
            aside: KeychainKeyIDStore(account: AppAttestKey.asideAccount, protectedData: protectedData),
            mayStartOver: { startOver.value }
        )
        let appLock = SecureEnclaveAppLockKeys()
        return HardwareKeys(
            appKeys: appKeys, seedWrap: seedWrap, phone: phone, attester: AppAttestAttester(key: attest), appLock: appLock,
            erasers: [appKeys, seedWrap, phone, attest, appLock]
        )
    }

    static func none() -> HardwareKeys {
        let h = NoSecureHardware()
        return HardwareKeys(appKeys: h, seedWrap: h, phone: h, attester: h, appLock: NoAppLockKeys(), erasers: [h])
    }
}

/// The App Attest attester (VAULT-MESSAGING §11.7; IOS-PLAN §6.2), with the TEST attester's clientDataHash rules
/// (``AttestSigned/clientDataHash``): an attestation's clientDataHash is the challenge; an assertion's is the challenge
/// of an unlock or a recovery open, or SHA-256 of an approval string. Blocks its thread while Apple answers. Mirrors
/// vettid-android `KeystoreAttester`.
struct AppAttestAttester: Attester {
    let key: AppAttestKey

    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { try key.attest(clientDataHash: challenge) }

    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { try key.assert(clientDataHash: signed.clientDataHash) }

    func confirm(keyID: [UInt8]) throws { try key.confirm(keyID: keyID) }

    func discard(keyID: [UInt8]) throws { try key.discard(keyID: keyID) }

    func prune(keeping keyIDs: [[UInt8]]) throws { try key.prune(keeping: keyIDs) }

    func confirmInUse() throws { try key.confirmInUse() }

    func nextCandidate() throws -> Bool { try key.nextCandidate() }

    func use(identity: Int) throws { try key.use(identity: identity) }

    func forget(identity: Int) throws { try key.forget(identity: identity) }

    func resetIdentities() throws { try key.resetIdentities() }

    func keepReplacedKeys() throws { try key.keepReplacedKeys() }

    func settle(identity: Int) throws { try key.settle(identity: identity) }
}
