import CryptoKit
import Foundation
import SwiftASN1
import X509

/// TEST ONLY. A key whose private scalar is the curve's size in bytes of [seed]: vettid-vault `enclavetest.TestKey`.
/// Every such key is public; nothing but a test may trust it.
public enum TestKey {
    public static func p256(_ seed: UInt8) -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: seed, count: 32))
        } catch {
            preconditionFailure("bad test key seed")
        }
    }

    public static func p384(_ seed: UInt8) -> P384.Signing.PrivateKey {
        do {
            return try P384.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: seed, count: 48))
        } catch {
            preconditionFailure("bad test key seed")
        }
    }
}

/// TEST ONLY. The stand-in for Apple's App Attest PKI that the dev enclave's TEST device policy trusts: vettid-vault
/// `enclavetest.TestAppleCA`. Root `TestKey(P-384, 0x51)`, intermediate `TestKey(P-384, 0x52)`; both certificates have
/// the Go code's `tbsCertificate` byte for byte (only the randomized ECDSA signatures differ), so a credential
/// certificate issued here chains to the root the vault's TEST policy pins.
///
/// What Go's `x509.CreateCertificate` writes, reproduced here: names as PrintableStrings, `O` before `CN`; validity from
/// 2020-01-01 for 40 years (the root) or 30 (the others), UTCTime before 2050 and GeneralizedTime from 2050; key usage
/// always critical; basic constraints (critical, CA, no path length) on the CAs; a CA's subject key identifier is the
/// first 20 bytes of SHA-256 of its public key's point (Go 1.25 and later); the authority key identifier is the issuer's.
public final class TestAppleCA: CustomStringConvertible, Sendable {
    public static let shared = TestAppleCA()
    public static let testOnlyMarker = "VETTID TEST ONLY: the TEST Apple App Attest CA"
    public var description: String { Self.testOnlyMarker }

    static let rootName = "TEST Apple App Attestation Root CA"
    static let intermediateName = "TEST Apple App Attestation CA 1"
    static let credentialName = "TEST App Attest credential"
    static let organization = "VettID TEST ONLY"
    /// vettid-vault `enclavetest` `epoch`: 2020-01-01T00:00:00Z.
    static let epoch = Date(timeIntervalSince1970: 1_577_836_800)
    /// The epoch plus 30 years (2050-01-01) and plus 40 years (2060-01-01).
    static let plus30 = Date(timeIntervalSince1970: 2_524_608_000)
    static let plus40 = Date(timeIntervalSince1970: 2_840_140_800)
    /// The App Attest nonce extension (1.2.840.113635.100.8.2).
    public static let nonceOID: ASN1ObjectIdentifier = [1, 2, 840, 113_635, 100, 8, 2]

    /// The root and intermediate certificates (DER).
    public let rootDER: [UInt8]
    public let intermediateDER: [UInt8]
    private let intermediateSKID: [UInt8]
    private let intermediateSubject: DistinguishedName
    private let intermediateSigner: P384.Signing.PrivateKey
    private let serials = SerialCounter(after: 1000)

    init() {
        do {
            let rootKey = TestKey.p384(0x51)
            let interKey = TestKey.p384(0x52)
            let rootSubject = try Self.name(Self.rootName, organization: true)
            let interSubject = try Self.name(Self.intermediateName, organization: true)
            let rootSKID = Self.subjectKeyID(Array(rootKey.publicKey.x963Representation))
            let interSKID = Self.subjectKeyID(Array(interKey.publicKey.x963Representation))
            let root = try Certificate(
                version: .v3, serialNumber: Certificate.SerialNumber(Int64(1)),
                publicKey: Certificate.PublicKey(rootKey.publicKey), notValidBefore: Self.epoch, notValidAfter: Self.plus40,
                issuer: rootSubject, subject: rootSubject, signatureAlgorithm: .ecdsaWithSHA384,
                extensions: Certificate.Extensions([
                    try Certificate.Extension(KeyUsage(keyCertSign: true, cRLSign: true), critical: true),
                    try Certificate.Extension(BasicConstraints.isCertificateAuthority(maxPathLength: nil), critical: true),
                    try Certificate.Extension(SubjectKeyIdentifier(keyIdentifier: rootSKID[...]), critical: false),
                ]),
                issuerPrivateKey: Certificate.PrivateKey(rootKey)
            )
            let inter = try Certificate(
                version: .v3, serialNumber: Certificate.SerialNumber(Int64(2)),
                publicKey: Certificate.PublicKey(interKey.publicKey), notValidBefore: Self.epoch, notValidAfter: Self.plus30,
                issuer: rootSubject, subject: interSubject, signatureAlgorithm: .ecdsaWithSHA384,
                extensions: Certificate.Extensions([
                    try Certificate.Extension(KeyUsage(keyCertSign: true), critical: true),
                    try Certificate.Extension(BasicConstraints.isCertificateAuthority(maxPathLength: nil), critical: true),
                    try Certificate.Extension(SubjectKeyIdentifier(keyIdentifier: interSKID[...]), critical: false),
                    try Certificate.Extension(AuthorityKeyIdentifier(keyIdentifier: rootSKID[...]), critical: false),
                ]),
                issuerPrivateKey: Certificate.PrivateKey(rootKey)
            )
            rootDER = try Self.der(root)
            intermediateDER = try Self.der(inter)
            intermediateSKID = interSKID
            intermediateSubject = interSubject
            intermediateSigner = interKey
        } catch {
            preconditionFailure("the TEST Apple CA could not be built: \(error)")
        }
    }

    /// The next credential certificate serial: 1001, 1002, … in this process, as `enclavetest` numbers them.
    public func nextSerial() -> Int64 { serials.next() }

    /// A credential certificate (DER) for [publicKey] carrying the nonce extension `SEQUENCE { [1] EXPLICIT OCTET STRING
    /// nonce }`, issued by the intermediate: what `enclavetest.AppleCA.Attest` issues.
    public func issueCredential(publicKey: P256.Signing.PublicKey, nonce: [UInt8], serial: Int64) throws -> [UInt8] {
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(serial),
            publicKey: Certificate.PublicKey(publicKey), notValidBefore: Self.epoch, notValidAfter: Self.plus30,
            issuer: intermediateSubject, subject: try Self.name(Self.credentialName, organization: false),
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: Certificate.Extensions([
                try Certificate.Extension(KeyUsage(digitalSignature: true), critical: true),
                try Certificate.Extension(AuthorityKeyIdentifier(keyIdentifier: intermediateSKID[...]), critical: false),
                Certificate.Extension(oid: Self.nonceOID, critical: false, value: Self.nonceExtension(nonce)[...]),
            ]),
            issuerPrivateKey: Certificate.PrivateKey(intermediateSigner)
        )
        return try Self.der(cert)
    }

    /// `SEQUENCE { [1] EXPLICIT OCTET STRING nonce }` (the nonce is 32 bytes, so every length is one byte).
    static func nonceExtension(_ nonce: [UInt8]) -> [UInt8] {
        let octets = [0x04, UInt8(nonce.count)] + nonce
        let tagged = [0xA1, UInt8(octets.count)] + octets
        return [0x30, UInt8(tagged.count)] + tagged
    }

    /// The `tbsCertificate` of a DER certificate.
    public static func tbs(_ der: [UInt8]) throws -> [UInt8] {
        Array(try Certificate(derEncoded: der).tbsCertificateBytes)
    }

    static func name(_ commonName: String, organization: Bool) throws -> DistinguishedName {
        var rdns: [RelativeDistinguishedName] = []
        if organization {
            rdns.append(RelativeDistinguishedName([
                try .init(type: .RDNAttributeType.organizationName, printableString: Self.organization),
            ]))
        }
        rdns.append(RelativeDistinguishedName([try .init(type: .RDNAttributeType.commonName, printableString: commonName)]))
        return DistinguishedName(rdns)
    }

    /// Go's subject key identifier: SHA-256 of the subjectPublicKey bits (the uncompressed point), first 20 bytes.
    static func subjectKeyID(_ point: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: point).prefix(20)) }

    static func der(_ cert: Certificate) throws -> [UInt8] {
        var s = DER.Serializer()
        try s.serialize(cert)
        return s.serializedBytes
    }
}

/// A process-wide increasing counter.
final class SerialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64

    init(after: Int64) { last = after }

    func next() -> Int64 {
        lock.withLock {
            last += 1
            return last
        }
    }
}
