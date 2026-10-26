import Foundation
import VettIDCrypto

/// The device's hardware attestation key (VAULT-MESSAGING §11.7): on the iPhone, App Attest (VettIDKeys, I1.4); in tests
/// and on the dev stack, VettIDTesting's TEST attester. Mirrors vettid-android `Attester`.
public protocol Attester: Sendable {
    /// A fresh key attested over [challenge] (an enrollment, a recovery's register).
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest

    /// The attested key's assertion over [signed] (an unlock's or a recovery open's challenge, a release approval).
    func assert(_ signed: AttestSigned) throws -> DeviceAssertion

    /// The bound key's certificate chain, for an Android unlock while the vault has not shown this app its signer
    /// (§11.7.1). Nil on iOS: App Attest has no signer.
    func chain() -> [[UInt8]]?

    /// The vault bound the key [keyID] (iOS: the App Attest key id): its request was answered `ok`, or its
    /// `vault.enrolled` arrived. Later assertions use that key (IOS-PLAN §6.2; chosen; not in the spec). A failure to
    /// record it is thrown.
    func confirm(keyID: [UInt8]) throws

    /// The request that carried the attestation of [keyID] certainly did not bind it: a sealed refusal, or a request
    /// that never reached the vault's processing. A failure to record it is thrown.
    func discard(keyID: [UInt8]) throws

    /// No unconfirmed key may be added (all slots taken): forget the unconfirmed keys outside [keyIDs], which no kept
    /// request names any more, so their `vault.enrolled` would never be accepted. A failure is thrown.
    func prune(keeping keyIDs: [[UInt8]]) throws

    /// The vault accepted an assertion of the key in use (an unlock answered `ok`): without a confirmed key, that one is
    /// the bound key.
    func confirmInUse() throws

    /// The vault refused an assertion of the key in use (`attestation`) while no key is confirmed: the next untried
    /// unconfirmed key, newest first, is used instead; then the keys of the identity's earlier registrations (IOS-PLAN 0.1.35
    /// §4.9). False when none is left.
    func nextCandidate() throws -> Bool

    /// (IOS-PLAN 0.1.33 §4.9) The phone's device identity [identity] (an index of ``IdentitySet``) is the one in use: the vault bound each identity's
    /// own key at its register, so this identity's keys are the current and pending ones from now on and the other's are kept
    /// as they are. Called before a session of the identity is used; the same identity again changes nothing.
    func use(identity: Int) throws

    /// (§4.9) The identity's keys are forgotten: the vault answered `ok` and the other identity's pairing completed. Never the
    /// identity in use.
    func forget(identity: Int) throws

    /// (§4.9) A forget (a start over, a deleted vault): the bookkeeping of identities is reset, so that the first identity is in use
    /// and the keys of the other identities are gone. Never a key of the identity in use is made the other's.
    func resetIdentities() throws

    /// (IOS-PLAN 0.1.35 §4.9) The identity in use registers again, with a new key: the keys its earlier registrations attested
    /// are kept beside it (the vault's binding may still be one of them) until ``settle(identity:)``.
    func keepReplacedKeys() throws

    /// (§4.9) The handshake completed with the identity [identity]: it is in use, and the keys of the other identities and of
    /// its own earlier registrations are forgotten.
    func settle(identity: Int) throws
}

/// What the device key signs (VAULT-MESSAGING §11.7, §11.10.3), as vettid-vault `devattest.Signed` carries it
/// (`ForChallenge`, `ForString`): Android signs ``message`` with ECDSA-SHA256; iOS asserts with ``clientDataHash``.
/// (The explicit kind is chosen; not in the spec, which states the two platforms' rules.)
public enum AttestSigned: Equatable, Sendable {
    /// The 32-byte challenge of an unlock (§11.4) or a recovery open (§11.14.6): Android signs its bytes; it is iOS's
    /// clientDataHash itself.
    case challenge([UInt8])
    /// A signing string such as a release approval (§11.10.3): Android signs its UTF-8 bytes; iOS's clientDataHash is
    /// SHA-256 of them.
    case string(String)

    /// The bytes Android's Keystore key signs.
    public var message: [UInt8] {
        switch self {
        case .challenge(let c): c
        case .string(let s): Array(s.utf8)
        }
    }

    /// The clientDataHash App Attest asserts with.
    public var clientDataHash: [UInt8] {
        switch self {
        case .challenge(let c): c
        case .string(let s): Bytes.sha256(Array(s.utf8))
        }
    }
}

extension Attester {
    public func chain() -> [[UInt8]]? { nil }
    public func confirm(keyID: [UInt8]) throws {}
    public func discard(keyID: [UInt8]) throws {}
    public func prune(keeping keyIDs: [[UInt8]]) throws {}
    public func confirmInUse() throws {}
    public func nextCandidate() throws -> Bool { false }
    public func use(identity: Int) throws {}
    public func forget(identity: Int) throws {}
    public func resetIdentities() throws {}
    public func keepReplacedKeys() throws {}
    public func settle(identity: Int) throws {}
}
