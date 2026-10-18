import Foundation
import VettIDCrypto

/// The app's side of the Protean Credential (VAULT-MESSAGING §3.5, §10.6) that enrollment needs, as vettid-vault's
/// `client/credential.go`: the device keeps the latest blob and a pool of UTKs; a sealed operation seals its payload to
/// a fresh UTK (bound to the vault id, the UTK id, the type and the inner id), and every blob the vault returns is kept
/// and confirmed with `credential.ack`. An operation with the blob (``credOp(_:_:)``, the holder's) fetches the latest
/// blob once on `stale_credential` and retries (§3.5.3). The reply-sealed values come with the rows that use them.
/// Mirrors vettid-android `CredentialOps`.
struct CredentialOps: Sendable {
    /// The payload members that carry a password (§11.14.7).
    static let passwordKeys: Set<String> = ["password", "new_password"]
    /// §6.7.1 step 3 (0.27.0): refused before the UTK was spent; a retry uses the same one.
    static let codeSignerUnconfirmed = "signer_unconfirmed"
    /// §3.5.3: the blob sent is not the vault's latest (the holder's own retry, after a lost answer).
    static let codeStaleCredential = "stale_credential"

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
            return try await sealed(type, utk: utk, fields: fields.map { .string($0.0, $0.1) }, withBlob: false)
        }
    }

    /// A credential operation with the blob (§3.5.3): [fields] sealed to a fresh UTK, the blob this device holds beside
    /// them; on `stale_credential` the latest blob is fetched once and the operation sent again with a fresh UTK.
    func credOp(_ type: String, _ fields: [SealedField]) async throws -> [UInt8] {
        try await device.credentialLock.withLock {
            // Nothing is taken from the pool for an operation that cannot be sent.
            if device.credentialBlob == nil { throw VaultStateError(message: "no credential on this device") }
            do {
                return try await sealed(type, utk: try await takeUTK(), fields: fields, withBlob: true)
            } catch let e as VaultOpError where e.code == Self.codeStaleCredential {
                try await fetch()
                return try await sealed(type, utk: try await takeUTK(), fields: fields, withBlob: true)
            }
        }
    }

    /// Fetches the latest blob the vault holds (the holder only).
    func fetch() async throws { try await keep(try await device.op("credential.get")) }

    private func sealed(_ type: String, utk: UtkRecord, fields: [SealedField], withBlob: Bool) async throws -> [UInt8] {
        guard let vaultID = device.vaultID else { throw VaultStateError(message: "no vault id") }
        let blob = withBlob ? device.credentialBlob : nil
        if withBlob, blob == nil { throw VaultStateError(message: "no credential on this device") }
        let nfc = normalizePasswords()
        let b = JsonBuilder()
        for f in fields {
            switch f {
            case .string(let k, let v): b.string(k, nfc && Self.passwordKeys.contains(k) ? Passwords.nfc(v) : v)
            case .bool(let k, let v): b.bool(k, v)
            }
        }
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
        let outer = JsonBuilder().string("utk_id", utk.id).base64("sealed", sealedPayload)
        if let blob { outer.string("credential", blob) }
        let body = outer.bytes()
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

/// One member of a sealed payload (§3.5.4): a string (a password is normalized for a vault of release R) or a bool.
enum SealedField: Sendable {
    case string(String, String)
    case bool(String, Bool)
}
