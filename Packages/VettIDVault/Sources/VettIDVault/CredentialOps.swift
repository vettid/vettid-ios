import Foundation
import VettIDCrypto

/// The app's side of the Protean Credential (VAULT-MESSAGING §3.5, §10.6) that enrollment needs, as vettid-vault's
/// `client/credential.go`: the device keeps the latest blob and a pool of UTKs; a sealed operation seals its payload to
/// a fresh UTK (bound to the vault id, the UTK id, the type and the inner id), and every blob the vault returns is kept
/// and confirmed with `credential.ack`. An operation with the blob (``credOp(_:_:)``, the holder's) fetches the latest
/// blob once on `stale_credential` and retries (§3.5.3), each step after its gate (``VaultApi/credentialGate``). The
/// reply-sealed values come with the rows that use them.
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
    /// ``VaultApi/credentialGate``.
    var gate: @Sendable () async throws -> Void = {}

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
            return try await sealed(type, utk: utk, fields: fields.map { .string($0.0, $0.1) }, CredOpOptions(withBlob: false))
        }
    }

    /// A credential operation with the blob (§3.5.3): [fields] sealed to a fresh UTK, the blob this device holds beside
    /// them (and [options]' outer members); on `stale_credential` the latest blob is fetched once and the operation sent
    /// again with a fresh UTK.
    func credOp(_ type: String, _ fields: [SealedField], _ options: CredOpOptions = CredOpOptions()) async throws -> [UInt8] {
        try await device.credentialLock.withLock {
            // Nothing is taken from the pool for an operation that cannot be sent.
            if device.credentialBlob == nil { throw VaultStateError(message: "no credential on this device") }
            // Under the lock: a change that started after the caller's own check is seen here.
            try await gate()
            do {
                return try await sealed(type, utk: try await takeUTK(), fields: fields, options)
            } catch let e as VaultOpError where e.code == Self.codeStaleCredential {
                try await fetch()
                // Never resent with the typed secrets while a change may have moved them (§11.14.9 step 4).
                try await gate()
                return try await sealed(type, utk: try await takeUTK(), fields: fields, options)
            }
        }
    }

    /// Fetches the latest blob the vault holds (the holder only).
    func fetch() async throws { try await keep(try await device.op("credential.get")) }

    private func sealed(_ type: String, utk: UtkRecord, fields: [SealedField], _ options: CredOpOptions) async throws -> [UInt8] {
        let id = device.newRequestID()
        let body = try build(type, utk: utk, fields: fields, id: id, options)
        let r: VaultMessage
        do {
            r = try await device.request(type, body: body, innerID: id, exp: options.exp)
        } catch {
            // From the deposit on, the request may have reached the vault (a deposit that failed may still go out from
            // the outbox).
            guard options.unanswered, !(error is CancellationError) else { throw error }
            throw RequestUnanswered(type: type)
        }
        return try await answered(type, utk: utk, r)
    }

    /// The outer body of a sealed operation: [fields] sealed to [utk] for the inner id [id], the blob when [options] say
    /// so, and their outer members.
    private func build(_ type: String, utk: UtkRecord, fields: [SealedField], id: String, _ options: CredOpOptions) throws -> [UInt8] {
        guard let vaultID = device.vaultID else { throw VaultStateError(message: "no vault id") }
        let withBlob = options.withBlob
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
        for (k, v) in options.outer { outer.string(k, v) }
        return outer.bytes()
    }

    /// The answer of a sealed operation: its blob and UTKs kept, or its refusal as ``VaultOpError`` (a UTK refused
    /// before it was spent goes back to the pool).
    private func answered(_ type: String, utk: UtkRecord?, _ r: VaultMessage) async throws -> [UInt8] {
        guard r.inner.status == Inner.statusOK else {
            if let utk, r.inner.error?.code == Self.codeSignerUnconfirmed { try await device.returnUTK(utk) }
            // The error's body: `weak_password` carries `reason` (§11.14.7), `backoff` its `retry_after` (§10.1).
            throw VaultOpError(
                type: type, code: r.inner.error?.code ?? "error", detail: r.inner.error?.message ?? "",
                body: r.inner.body.isEmpty ? nil : r.inner.body
            )
        }
        try await keep(r.body)
        return r.body
    }

    // MARK: - The changes of PIN and password (§11.14.9 "A lost answer")

    /// `pin.change` or `credential.password.change` as [change] describes it: the inner id and `exp` the caller stored
    /// before this call, and the blob version it expects to send (anything else is refused before a UTK is taken: the
    /// stored version would not be the request's). A `stale_credential` is **not** retried with the same secrets: the
    /// latest blob is fetched and the refusal thrown. No answer (none to the automatic resends of §8.6, or a deposit that
    /// failed and may still go out from the outbox) is ``ChangeUnanswered`` with the request to send again.
    func change(_ type: String, _ fields: [SealedField], _ change: ChangeRequest) async throws -> [UInt8] {
        try await device.credentialLock.withLock {
            guard device.credentialBlob != nil, device.credentialVersion == change.version else {
                throw VaultStateError(message: "credential version moved")
            }
            let utk = try await takeUTK()
            let held = HeldRequest(
                type: type, id: change.id, exp: change.exp,
                body: try build(type, utk: utk, fields: fields, id: change.id, CredOpOptions())
            )
            return try await sendChange(held, utk: utk, first: true)
        }
    }

    /// [held] sent again, as the same request (§11.14.9 step 3): one deposit, one wait.
    func resendChange(_ held: HeldRequest) async throws -> [UInt8] {
        try await device.credentialLock.withLock { try await sendChange(held, utk: nil, first: false) }
    }

    /// Once the request may have been deposited, only the vault's own refusal (``VaultOpError``) or a cancellation
    /// leaves here as itself: every other failure (no answer, the relay, the device state or a key that could not be
    /// saved after the deposit, a blob that could not be kept after the answer) is ``ChangeUnanswered``, so that the
    /// change is decided rather than taken as not sent.
    private func sendChange(_ held: HeldRequest, utk: UtkRecord?, first: Bool) async throws -> [UInt8] {
        do {
            let r = first
                ? try await device.request(held.type, body: held.body, innerID: held.id, exp: held.exp)
                : try await device.resend(held)
            return try await answered(held.type, utk: utk, r)
        } catch let e as VaultOpError {
            // An earlier credential operation applied without its answer: never resent with the typed secrets.
            if e.code == Self.codeStaleCredential { try? await fetch() }
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChangeUnanswered(held: held)
        }
    }
}

/// What a change of PIN or password is sent as (VAULT-MESSAGING §11.14.9 "A lost answer"): its inner id and `exp`,
/// stored by the app before the send, and the blob version the request carries.
public struct ChangeRequest: Equatable, Sendable {
    /// How long after the vault's clock as last seen a change may still be acted on.
    public static let validFor: TimeInterval = 600

    public let id: String
    public let exp: Date
    public let version: Int64

    public init(id: String, exp: Date, version: Int64) {
        self.id = id
        self.exp = exp
        self.version = version
    }
}

/// A change of PIN or password got no answer: the vault may have applied it. [held] is the request, to send again as
/// the same request while its `exp` has not passed.
public struct ChangeUnanswered: Error, Sendable, CustomStringConvertible {
    public let held: HeldRequest

    public var description: String { "\(held.type): no answer" }
}

/// What a credential operation carries besides its sealed members: the blob ([withBlob]; not for `credential.create`),
/// members of the outer body beside it ([outer]: `vault.delete`'s `confirm`, §12.5), whether a failure once the
/// request may have gone out is ``RequestUnanswered`` ([unanswered]) rather than the failure itself, and the request's
/// `exp` (§5.3; a retry after `stale_credential` keeps it).
struct CredOpOptions: Sendable {
    var withBlob = true
    var outer: [(String, String)] = []
    var unanswered = false
    var exp: Date?
}

/// A credential operation whose answer did not arrive once its request may have gone out (no answer to the automatic
/// resends of §8.6, or a deposit that failed and may still go out from the outbox): the vault may have acted on it.
public struct RequestUnanswered: Error, Sendable, CustomStringConvertible {
    public let type: String

    public var description: String { "\(type): no answer" }
}

/// One member of a sealed payload (§3.5.4): a string (a password is normalized for a vault of release R) or a bool.
enum SealedField: Sendable {
    case string(String, String)
    case bool(String, Bool)
}
