import Foundation
import VettIDCrypto

/// The device's hardware attestation key (VAULT-MESSAGING §11.7): on the iPhone, App Attest (VettIDKeys, I1.4); in tests
/// and on the dev stack, VettIDTesting's TEST attester. Mirrors vettid-android `Attester`.
public protocol Attester: Sendable {
    /// A fresh key attested over [challenge] (an enrollment, a recovery's register).
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest

    /// The attested key's assertion over [message] (an unlock, a release approval).
    func assert(_ message: [UInt8]) throws -> DeviceAssertion

    /// The bound key's certificate chain, for an Android unlock while the vault has not shown this app its signer
    /// (§11.7.1). Nil on iOS: App Attest has no signer.
    func chain() -> [[UInt8]]?
}

extension Attester {
    public func chain() -> [[UInt8]]? { nil }
}
