import Foundation
import VettIDCrypto

/// The app key (VAULT-MESSAGING §11.12.2, 0.15.0): a P-256 signing key held in hardware that signs every app request
/// to the member API. The app never signs in; this key is what the API knows the app by. The iPhone's signer is a
/// Secure Enclave key (VettIDKeys, IOS-PLAN §6.1). Mirrors vettid-android `AppKeySigner`.
public protocol AppKeySigner: Sendable {
    /// The public key's SubjectPublicKeyInfo DER.
    func spki() throws -> [UInt8]

    /// ECDSA P-256 with SHA-256 over [message], DER-encoded.
    func sign(_ message: [UInt8]) throws -> [UInt8]
}

/// The `X-VettID-App` header (§11.12.2):
///
/// ```
/// X-VettID-App: v=1; vault=<vault_id or empty>; kid=<akid>; ts=<Unix s>; nonce=<b64url, 16 bytes>; sig=<b64url DER ECDSA>
/// ```
///
/// `sig` signs (each `\n` a literal newline, no trailing newline)
/// `"vettid/member-api/app/1" \n METHOD \n path \n query \n vault_id \n akid \n ts \n nonce \n hex(SHA-256(body))`.
/// `nonce` and `sig` are base64url without padding (the member API refuses padding). Mirrors vettid-android
/// `AppRequestSigning`.
public enum AppRequestSigning {
    public static let header = "X-VettID-App"
    public static let context = "vettid/member-api/app/1"
    public static let nonceSize = 16
    private static let akidBytes = 16

    /// `akid`: the first 16 bytes of SHA-256(SPKI DER), 32 lowercase hex.
    public static func akid(_ spki: [UInt8]) -> String { Bytes.hex(Array(Bytes.sha256(spki).prefix(akidBytes))) }

    /// The string the signature covers. [query] is the raw query without `?` (or empty). One parameter per line of it.
    public static func signingString( // swiftlint:disable:this function_parameter_count
        method: String, path: String, query: String, vaultID: String, akid: String, ts: UInt64, nonce: String, body: [UInt8]
    ) -> String {
        [context, method, path, query, vaultID, akid, String(ts), nonce, Bytes.hex(Bytes.sha256(body))].joined(separator: "\n")
    }

    /// The header's value for a request; [nonceBytes] and [ts] are injectable for tests.
    public static func headerValue( // swiftlint:disable:this function_parameter_count
        signer: AppKeySigner,
        method: String,
        path: String,
        query: String?,
        vaultID: String?,
        body: [UInt8],
        ts: UInt64 = UInt64(Date().timeIntervalSince1970),
        nonceBytes: [UInt8] = Randomness.bytes(nonceSize)
    ) throws -> String {
        let kid = akid(try signer.spki())
        let vault = vaultID ?? ""
        let nonce = Base64s.encodeRawUrl(nonceBytes)
        let message = signingString(
            method: method, path: path, query: query ?? "", vaultID: vault, akid: kid, ts: ts, nonce: nonce, body: body
        )
        let sig = try signer.sign(Array(message.utf8))
        return "v=1; vault=\(vault); kid=\(kid); ts=\(ts); nonce=\(nonce); sig=\(Base64s.encodeRawUrl(sig))"
    }
}
