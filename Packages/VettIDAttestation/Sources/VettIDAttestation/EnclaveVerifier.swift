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
    /// §11.2 "Lifetime and clock allowance" (VAULT-MESSAGING 0.53.0): not_after at most 24 h + 5 min after the attestation's
    /// timestamp.
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
        try verify(descriptor: descriptor, attestation: attestation, manifest: manifest, enroll: enroll, now: now).enclave()
    }

    /// ``verifyEnclave(descriptor:attestation:manifest:enroll:now:)`` with its record (ANDROID-PLAN 0.1.124 §4 "Attestation
    /// in detail"): the same checks, in the order of ``AttestationCheck`` ([manifest] has passed line 1), each recorded as it
    /// passes; the first that fails is recorded failed and every later one not run. A release that passed every check and
    /// is not `active` for an enrollment is refused after them (``EnclaveRefusal/notActive``). Mirrors vettid-android
    /// `EnclaveVerifier.verify`.
    public func verify( // swiftlint:disable:this function_body_length cyclomatic_complexity
        descriptor: [UInt8],
        attestation: [UInt8],
        manifest: ReleaseManifest,
        enroll: Bool,
        now: Date
    ) -> EnclaveVerification {
        // Line 1 passes only for a manifest verified under a pinned key (``ReleaseManifest/keyID``).
        guard manifest.keyID != nil else {
            return EnclaveVerification(failure: .signature("manifest"), record: .manifestFailed(at: now))
        }
        var r = EnclaveRecord(at: now, passed: 1, failed: false)
        r.manifestKeyID = manifest.keyID
        r.manifestSerial = manifest.serial
        var passed = 1
        func pass() {
            passed += 1
            r = r.with(passed: passed, failed: false)
        }
        func fail(_ e: AttestationError) -> EnclaveVerification {
            EnclaveVerification(failure: e, record: r.with(passed: passed, failed: true))
        }
        // Lines 2 and 3: the chain (and the document's format) is checked before the signature, which is the last thing
        // NitroVerifier checks and the only one it reports as a `signature` failure.
        let doc: NitroDocument
        do {
            doc = try nitro.verify(attestation)
        } catch AttestationError.signature(let what) {
            pass()
            return fail(.signature(what))
        } catch let e as AttestationError {
            return fail(e)
        } catch {
            return fail(.format("attestation"))
        }
        let ms = doc.measurements
        r.pcr0 = ms.pcr0
        r.pcr1 = ms.pcr1
        r.pcr2 = ms.pcr2
        r.attestedAt = doc.timestamp
        pass()
        pass()
        // Line 4: the descriptor's format and user_data over it.
        let ds: Descriptor
        do {
            ds = try Descriptor.parse(descriptor)
        } catch {
            return fail(.format("descriptor"))
        }
        r.notAfter = ds.notAfter
        do {
            try doc.checkUserData(AltChannel.etkUserData(descriptor))
        } catch {
            return fail(.userData)
        }
        pass()
        do {
            try doc.checkFresh(now: now, maxAge: Self.maxAttestationAge, skew: Self.attestationSkew)
        } catch {
            return fail(.stale)
        }
        pass()
        guard !ms.isDebug else { return fail(.debug) }
        pass()
        guard Bytes.constantTimeEquals(Array(ms.pcr0.utf8), Array(ds.release.utf8)) else { return fail(.pcr("release")) }
        pass()
        guard now < ds.notAfter, ds.notAfter <= doc.timestamp.addingTimeInterval(Self.maxDescriptorLife) else {
            return fail(.stale)
        }
        pass()
        guard let e = manifest.byPcr0(ms.pcr0) else { return fail(.release("not listed", unknown: true)) }
        guard e.measurements.matches(ms) else { return fail(.pcr("manifest")) }
        pass()
        r.releaseNumber = e.number
        r.releaseStatus = e.status
        r.releaseEndsAt = e.endsAt
        if enroll, e.status != .active {
            r.refusal = .notActive
            return EnclaveVerification(failure: .release("not active"), record: r)
        }
        return EnclaveVerification(VerifiedEnclave(descriptor: ds, measurements: ms, release: e), record: r)
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
