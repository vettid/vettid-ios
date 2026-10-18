import Foundation

/// A canary manifest refused at installation (after its signature and format verified).
public enum CanaryManifestError: Error, Equatable, Sendable {
    /// Its serial is lower than the highest serial this device has already used (VAULT-MESSAGING §11.10.1).
    case older
    /// The published manifest already has this serial or a higher one: nothing to test.
    case published
}

/// A canary manifest installed on this device (VAULT-RELEASES §10.1 step 9): a served document signed with a pinned
/// manifest key but not published yet. VettID signs serial s+1 with the release under test `active`, copies it to the
/// vault data bucket (so that the enclave host can hand it to the enclave by hash, VAULT-MESSAGING §11.5) and does not
/// serve it; the canary phone gets it out of band.
///
/// It adds no trust: it is verified exactly like the published manifest (signature under a key this build pins,
/// `key_id` selecting it; the strict format of §11.10.1; the serial rule), and it is used only while its serial is
/// higher than the published one. Once VettID publishes it (the same document) or anything newer, the published
/// manifest wins and the canary document is forgotten. Mirrors vettid-android `CanaryManifests`.
public enum CanaryManifests {
    /// Verifies [served] for installation: its signature under a key [verifier] pins, the strict manifest format, a
    /// serial not lower than [seen] (the highest this device has used for its vault, 0 without one) and higher than
    /// [published] (the published manifest's serial, nil when nothing is published or it could not be read). Throws
    /// ``AttestationError`` for the signature and format, ``CanaryManifestError`` for the serial rules.
    public static func check(verifier: ManifestVerifier, served: [UInt8], seen: UInt64, published: UInt64?) throws -> ReleaseManifest {
        let m = try verifier.verify(served)
        guard m.serial >= seen else { throw CanaryManifestError.older }
        if let published, published >= m.serial { throw CanaryManifestError.published }
        return m
    }

    /// Which manifest an enroll, unlock or recovery uses (§11.10.1 "How apps learn the manifest", with the canary of
    /// VAULT-RELEASES §10.1): the one with the higher serial; the published one when they are equal (the canary document
    /// published as it was). [published] is nil only when nothing is served yet.
    public static func choose(published: ReleaseManifest?, canary: ReleaseManifest?) -> ReleaseManifest? {
        guard let canary else { return published }
        guard let published else { return canary }
        return published.serial >= canary.serial ? published : canary
    }
}
