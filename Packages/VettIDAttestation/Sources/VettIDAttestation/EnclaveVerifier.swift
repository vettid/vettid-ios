import Foundation
import VettIDCrypto

/// A verified enclave instance (VAULT-MESSAGING §11.2): its ETK descriptor, measurements and manifest entry.
public struct VerifiedEnclave: Sendable {
    public let descriptor: Descriptor
    public let measurements: Measurements
    public let release: Release

    public init(descriptor: Descriptor, measurements: Measurements, release: Release) {
        self.descriptor = descriptor
        self.measurements = measurements
        self.release = release
    }
}

/// The app's checks of an enclave before it seals anything to it (§11.2, §11.3), as vettid-vault's reference client
/// does (`client.VerifyEnclave`, `checkEnrolledAttestation`). Mirrors vettid-android `EnclaveVerifier`.
public struct EnclaveVerifier: Sendable {
    /// §11.2 step 3.
    public static let maxAttestationAge: TimeInterval = 26 * 3600
    public static let attestationSkew: TimeInterval = 5 * 60
    /// §11.2 step 3: not_after at most 24 h + 5 min after the attestation's timestamp.
    static let maxDescriptorLife: TimeInterval = 24 * 3600 + 5 * 60

    private let nitro: NitroVerifier

    public init(nitro: NitroVerifier = NitroVerifier()) { self.nitro = nitro }

    /// Checks an ETK descriptor and its attestation document: the chain to the pinned Nitro root,
    /// user_data = SHA-256("vettid/vms/2/etk" || descriptor), an attestation less than 26 h old, no debug PCRs,
    /// release = PCR0, not_after in the future and at most 24 h + 5 min after the attestation, and PCR0–2 equal to a manifest
    /// entry (an `active` one to enroll).
    public func verifyEnclave(
        descriptor: [UInt8],
        attestation: [UInt8],
        manifest: ReleaseManifest,
        enroll: Bool,
        now: Date
    ) throws -> VerifiedEnclave {
        let ds: Descriptor
        do {
            ds = try Descriptor.parse(descriptor)
        } catch is CryptoError {
            throw AttestationError.format("descriptor")
        }
        let doc = try nitro.verify(attestation)
        try doc.checkUserData(AltChannel.etkUserData(descriptor))
        try doc.checkFresh(now: now, maxAge: Self.maxAttestationAge, skew: Self.attestationSkew)
        let ms = doc.measurements
        guard !ms.isDebug else { throw AttestationError.debug }
        guard Bytes.constantTimeEquals(Array(ms.pcr0.utf8), Array(ds.release.utf8)) else { throw AttestationError.pcr("release") }
        guard now < ds.notAfter, ds.notAfter <= doc.timestamp.addingTimeInterval(Self.maxDescriptorLife) else {
            throw AttestationError.stale
        }
        guard let e = manifest.byPcr0(ms.pcr0) else { throw AttestationError.release("not listed", unknown: true) }
        guard e.measurements.matches(ms) else { throw AttestationError.pcr("manifest") }
        if enroll, e.status != .active { throw AttestationError.release("not active") }
        return VerifiedEnclave(descriptor: ds, measurements: ms, release: e)
    }

    /// Checks vault.enrolled's attestation (§11.3): nonce = the app's enroll nonce,
    /// user_data = SHA-256("vettid/vms/2/vault" || vault_bundle), the PCRs of the enclave the request was sealed to, and
    /// freshness.
    public func verifyEnrolled(attestation: [UInt8], vaultBundle: [UInt8], nonce: [UInt8], expected: Measurements, now: Date) throws {
        let doc = try nitro.verify(attestation)
        try doc.checkNonce(nonce)
        try doc.checkUserData(AltChannel.vaultUserData(vaultBundle))
        guard doc.measurements.matches(expected) else { throw AttestationError.pcr("enrolled") }
        try doc.checkFresh(now: now, maxAge: Self.maxAttestationAge, skew: Self.attestationSkew)
    }
}
