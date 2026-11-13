import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto

extension FakeVaultService {
    /// ``enclaveCheck``: the descriptor as served and the manifest's entry for its release, recorded as every check passed;
    /// a descriptor that does not parse fails "Covers the key", a release in no entry the match.
    static func fakeVerification(_ descriptor: [UInt8], _ manifest: ReleaseManifest, _ now: Date) -> EnclaveVerification {
        guard let d = try? Descriptor.parse(descriptor) else {
            return EnclaveVerification(failure: .format("descriptor"), record: EnclaveRecord(at: now, passed: 3, failed: true))
        }
        guard let r = manifest.byPcr0(d.release) else {
            return EnclaveVerification(
                failure: .release("not listed", unknown: true), record: EnclaveRecord(at: now, passed: 8, failed: true)
            )
        }
        var rec = EnclaveRecord(at: now, passed: AttestationCheck.allCases.count, failed: false)
        rec.manifestKeyID = manifest.keyID
        rec.manifestSerial = manifest.serial
        rec.pcr0 = r.pcr0
        rec.pcr1 = r.pcr1
        rec.pcr2 = r.pcr2
        rec.notAfter = d.notAfter
        rec.releaseNumber = r.number
        rec.releaseStatus = r.status
        rec.releaseEndsAt = r.endsAt
        return EnclaveVerification(VerifiedEnclave(descriptor: d, measurements: r.measurements, release: r), record: rec)
    }
}
