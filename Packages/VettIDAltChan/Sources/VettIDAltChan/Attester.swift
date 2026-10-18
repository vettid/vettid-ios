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
}
