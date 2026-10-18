import Foundation

/// The manifest public keys pinned in the app (VAULT-MESSAGING §11.10.1: apps and images MAY pin two keys to allow
/// rotation; `key_id` selects one).
///
/// VettID's production keys (VAULT-RELEASES §6.1), the same two that the production enclave images pin and vettid.org's
/// `manifestKeys`:
///  - key A: AWS KMS ECC_NIST_P256 in vettid-vault-prod, signs every manifest;
///  - key B: an offline YubiKey (PIV, P-256, PIN and touch on every use), the standby if key A is ever lost.
///
/// Changing either is an app release; the tests pin their key ids. The staging channel's key is not here: only the
/// Staging and Debug builds pin it, so it lives in the app target (with the unlock flow), never in Release.
/// Never pin the §16 test key (private scalar 32 × 0x21 is public) in a build. Tests and the local dev stack pass their
/// keys explicitly. Mirrors vettid-android `ManifestKeys`.
public enum ManifestKeys {
    /// Key A (SPKI DER, base64); key_id 4353463f85c4012f.
    public static let keyASPKIBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7xDU6CSVsFDJvP7UXigsN9SDB+KIppU85Y3DRvo0oMQZYKHZ1S/3OaNdFk2/HJX+hohYdyU6QIFPXiDBirflCQ=="

    /// Key B, the offline standby (SPKI DER, base64); key_id 1abd49da96970b6e.
    public static let keyBSPKIBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIcIodW3liYaxACuOdB0If8igq/oWfVOcLGbWTy1vUNzTlvsVNe3ljfqpqfTCZwtR611EYk7UPTCfjaEEMPLxfQ=="

    /// The pinned keys of production builds.
    public static let production: [ManifestKey] = [keyASPKIBase64, keyBSPKIBase64].map { b64 in
        do {
            return try ManifestKey(base64: b64)
        } catch {
            preconditionFailure("pinned manifest key")
        }
    }
}
