import Foundation
import VettIDCrypto

/// The app's side of the Protean Credential (VAULT-MESSAGING §3.5, §10.6) that enrollment needs, as vettid-vault's
/// `client/credential.go`: the device keeps the latest blob and a pool of UTKs; a sealed operation seals its payload to
/// a fresh UTK (bound to the vault id, the UTK id, the type and the inner id), and every blob the vault returns is kept
/// and confirmed with `credential.ack`. The operations with the blob (the holder's, `stale_credential` and its retry)
/// and the reply-sealed values come with the rows that use them. Mirrors vettid-android `CredentialOps`.
struct CredentialOps: Sendable {
    /// The payload members that carry a password (§11.14.7).
    static let passwordKeys: Set<String> = ["password", "new_password"]
    /// §6.7.1 step 3 (0.27.0): refused before the UTK was spent; a retry uses the same one.
    static let codeSignerUnconfirmed = "signer_unconfirmed"

    let device: VaultDevice
    let normalizePasswords: @Sendable () -> Bool

    /// Stores the UTKs and the blob a response carries, and confirms the blob (`credential.ack`, §3.5.3).
    func keep(_ body: [UInt8]) async throws {
        let o = try StrictJson.parseObject(body.isEmpty ? VaultJSON.empty : body)
        if let arr = try o.optArray("utks") {
            let list = try arr.map { v -> UtkRecord in
                let u = try Utk.parse(try v.asObject())
                return UtkRecord(id: u.id, ek: Base64s.encodeStd(u.ek.bytes), expiresAtMs: VaultDevice.ms(u.expiresAt))
            }
            try await device.keepUTKs(list)
        }
        guard let blob = VaultJSON.string(o, "credential") else { return }
        // Item operations carry the item's version as `version` and the credential's as `credential_version` (§10.6).
        guard let v = VaultJSON.int(o, "credential_version") ?? VaultJSON.int(o, "version"), v >= 0 else {
            throw VaultStateError(message: "credential without version")
        }
        try await device.keepCredential(blob: blob, version: v)
        _ = try await device.op("credential.ack", body: JsonBuilder().uint("version", UInt64(v)).bytes())
    }

    /// An unexpired UTK, fetching a pool (`credential.utk.get`) when the device holds none.
    func takeUTK() async throws -> UtkRecord {
        for _ in 0..<2 {
            if let u = try await device.takeUTK() { return u }
            try await keep(try await device.op("credential.utk.get"))
        }
        throw VaultStateError(message: "no UTK")
    }

    /// A sealed operation without the blob (create): [fields] sealed to a fresh UTK, in this order, each a string; the
    /// passwords among them normalized to NFC for a vault of release R. Returns the response body once its blob and UTKs
    /// are kept.
    func sealedOp(_ type: String, _ fields: [(String, String)]) async throws -> [UInt8] {
        try await device.credentialLock.withLock {
            let utk = try await takeUTK()
            return try await sealed(type, utk: utk, fields: fields)
        }
    }

    /// Fetches the latest blob the vault holds (the holder only).
    func fetch() async throws { try await keep(try await device.op("credential.get")) }

    private func sealed(_ type: String, utk: UtkRecord, fields: [(String, String)]) async throws -> [UInt8] {
        guard let vaultID = device.vaultID else { throw VaultStateError(message: "no vault id") }
        let nfc = normalizePasswords()
        let b = JsonBuilder()
        for (k, v) in fields { b.string(k, nfc && Self.passwordKeys.contains(k) ? Passwords.nfc(v) : v) }
        var plaintext = b.bytes()
        let id = device.newRequestID()
        let sealedPayload: [UInt8]
        do {
            defer { Bytes.wipe(&plaintext) }
            let ek = try KemPublicKey.parse(try Base64s.decodeStd(utk.ek))
            let key = Utk(id: utk.id, ek: ek, expiresAt: Date(timeIntervalSince1970: Double(utk.expiresAtMs) / 1000))
            sealedPayload = try CredentialSeal.sealPayload(
                utk: key, vaultID: vaultID, type: type, innerID: id, payload: plaintext
            )
        }
        let body = JsonBuilder().string("utk_id", utk.id).base64("sealed", sealedPayload).bytes()
        let r = try await device.request(type, body: body, innerID: id)
        guard r.inner.status == Inner.statusOK else {
            if r.inner.error?.code == Self.codeSignerUnconfirmed { try await device.returnUTK(utk) }
            // The error's body: `weak_password` carries `reason` (§11.14.7), `backoff` its `retry_after` (§10.1).
            throw VaultOpError(
                type: type, code: r.inner.error?.code ?? "error", detail: r.inner.error?.message ?? "",
                body: r.inner.body.isEmpty ? nil : r.inner.body
            )
        }
        try await keep(r.body)
        return r.body
    }
}
