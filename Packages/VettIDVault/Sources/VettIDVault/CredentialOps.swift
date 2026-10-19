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
    /// ``VaultApi/credentialGate``: called with whether the operation's payload carries the PIN.
    var gate: @Sendable (_ carriesPin: Bool) async throws -> Void = { _ in }
    /// The wait of a change for the credential operations before it (``VaultApi/changeWaitSleep``).
    var changeWaitSleep: @Sendable (TimeInterval) async throws -> Void = VaultApi.sleep

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
            try await gate(Self.carriesPin(fields))
            do {
                return try await sealed(type, utk: try await takeUTK(), fields: fields, options)
            } catch let e as VaultOpError where e.code == Self.codeStaleCredential {
                try await fetch()
                // Never resent with the typed secrets while a change may have moved them (§11.14.9 step 4).
                try await gate(Self.carriesPin(fields))
                return try await sealed(type, utk: try await takeUTK(), fields: fields, options)
            }
        }
    }

    /// Whether [fields] carry the PIN (refused while the PIN is uncertain, §11.14.9 step 3).
    static func carriesPin(_ fields: [SealedField]) -> Bool {
        fields.contains { if case .string("pin", _) = $0 { true } else { false } }
    }

    /// Fetches the latest blob the vault holds (the holder only).
    func fetch() async throws { try await keep(try await device.op("credential.get")) }

    private func sealed(
        _ type: String, utk: UtkRecord, fields: [SealedField], _ options: CredOpOptions, id: String? = nil,
        onOK: (@Sendable () async -> Void)? = nil
    ) async throws -> [UInt8] {
        let id = id ?? device.newRequestID()
        let body = try build(type, utk: utk, fields: fields, id: id, options)
        // Every credential request carries an `exp` and stays unsettled until its answer or its `exp` has passed by more
        // than a minute (VAULT-MESSAGING 0.46.0 §11.14.9 step 1).
        let exp: Date
        if let given = options.exp { exp = given } else { exp = try await requestExp() }
        try await device.trackCredential(id, exp: exp)
        let r: VaultMessage
        do {
            r = try await device.request(type, body: body, innerID: id, exp: exp)
        } catch {
            // From the deposit on, the request may have reached the vault (a deposit that failed may still go out from
            // the outbox).
            guard options.unanswered, !(error is CancellationError) else { throw error }
            throw RequestUnanswered(type: type)
        }
        // Its own `ok` decides before anything else is done with the answer (a blob that cannot be kept after it, or an
        // acknowledgement refused, does not undo it).
        if r.inner.status == Inner.statusOK, let onOK { await onOK() }
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

    // MARK: - The changes of PIN and password, and the renew (§11.14.9 "A lost answer")

    /// `pin.change` or `credential.password.change`. Step 1 (VAULT-MESSAGING 0.46.0 §11.14.9, "Nothing else in flight",
    /// "Settled on answers only"; ``settledAndChecked``): every earlier credential request of this device settled and
    /// the blob's version confirmed by the vault, under the credential lock; only then is the request fixed (a new inner
    /// id, an `exp` 10 minutes after the vault's clock as last seen, the confirmed version) and handed to [onMarker],
    /// which stores the unresolved change (and a PIN change's candidate) and returns the payload members that go with it
    /// (a PIN change's next secret). Nothing is stored for a change refused before that (the pre-check before the marker:
    /// chosen; not in the spec). A `stale_credential` is **not** retried with the same secrets: the latest blob is
    /// fetched and the refusal thrown. No answer (none to the automatic resends of §8.6, every deposit straight to the
    /// relay) is ``ChangeUnanswered`` with the request to send again.
    func change(_ type: String, _ fields: [SealedField], onMarker: OnMarker) async throws -> [UInt8] {
        try await settledAndChecked(type, gate: false) { change, utk in
            let more = try await marked(change, utk, onMarker)
            let held = HeldRequest(
                type: type, id: change.id, exp: change.exp,
                body: try build(type, utk: utk, fields: fields + more, id: change.id, CredOpOptions())
            )
            try await device.trackCredential(change.id, exp: change.exp)
            return try await sendChange(held, utk: utk, first: true)
        }
    }

    /// `vault.secret.renew` after the same steps as a change, the credential gate included (VAULT-MESSAGING: pending spec
    /// PR for vettid/vettid.org#347; renews settle too: chosen, not in the spec), [onMarker] storing the renew's record
    /// and request. [onAnswered] runs on its own `ok` answer, before its blob is kept. Any refusal of its own request,
    /// `stale_credential` included, means it did not apply: `stale_credential` is not retried, the latest blob is fetched
    /// and the refusal thrown (VAULT-MESSAGING: pending spec PR for vettid/vettid.org#347). A failure once it may have
    /// gone out is ``RequestUnanswered``.
    func renew(
        _ type: String, _ fields: [SealedField], onMarker: OnMarker, onAnswered: @escaping @Sendable () async -> Void
    ) async throws -> [UInt8] {
        try await settledAndChecked(type, gate: true) { change, utk in
            let more = try await marked(change, utk, onMarker)
            do {
                let options = CredOpOptions(unanswered: true, exp: change.exp)
                return try await sealed(type, utk: utk, fields: fields + more, options, id: change.id, onOK: onAnswered)
            } catch let e as VaultOpError where e.code == Self.codeStaleCredential {
                try? await fetch()
                throw e
            }
        }
    }

    /// What the caller stores once the request is fixed, returning the payload members that go with it.
    typealias OnMarker = @Sendable (ChangeRequest) async throws -> [SealedField]

    /// [onMarker] for [change]; [utk] goes back to the pool when it fails (nothing was sent).
    private func marked(_ change: ChangeRequest, _ utk: UtkRecord, _ onMarker: OnMarker) async throws -> [SealedField] {
        do {
            return try await onMarker(change)
        } catch {
            try? await device.returnUTK(utk)
            throw error
        }
    }

    /// Step 1 before a change or a renew: every earlier credential request of this device settled (the outbox flushed,
    /// waited for at most ``inFlightWait``), then under the credential lock (at most as long): the credential gate for a
    /// renew ([gate]), the settling checked again, `credential.version` confirming the blob this device holds
    /// (``checkVersion``), a UTK taken, and [body] with the request fixed on the confirmed version. Else refused with
    /// nothing sent or stored.
    private func settledAndChecked(
        _ type: String, gate checksGate: Bool, _ body: (ChangeRequest, UtkRecord) async throws -> [UInt8]
    ) async throws -> [UInt8] {
        guard await device.awaitCredentialSettled(within: Self.inFlightWait, sleep: changeWaitSleep) else {
            throw CredentialUnsettled(type: type, reason: .inFlight)
        }
        let sent = try await device.credentialLock.withLock(within: Self.inFlightWait, sleep: changeWaitSleep) {
            guard device.credentialBlob != nil, let version = device.credentialVersion else {
                throw VaultStateError(message: "no credential on this device")
            }
            if checksGate { try await gate(true) }
            // One that started meanwhile, before this took the lock.
            guard await device.credentialSettled() else { throw CredentialUnsettled(type: type, reason: .inFlight) }
            try await checkVersion(version, before: type)
            let utk = try await takeUTK()
            let change = ChangeRequest(id: device.newRequestID(), exp: try await requestExp(), version: version)
            return try await body(change, utk)
        }
        guard let sent else { throw CredentialUnsettled(type: type, reason: .inFlight) }
        return sent
    }

    /// How long a change waits for the credential operations before it (§11.14.9 step 1: at most 30 s).
    static let inFlightWait: TimeInterval = 30

    /// The `exp` of a credential request sent now: 10 minutes after the vault's clock as last seen; in a process that has
    /// not heard from the vault yet, `credential.version` is asked first (as ``VaultApi/requestExp()``).
    func requestExp() async throws -> Date {
        if !device.knowsVaultTime { _ = try await device.request("credential.version") }
        return device.vaultNow().addingTimeInterval(ChangeRequest.validFor)
    }

    /// `credential.version` before a change or a renew (a request as any other, §8.6's resends of the same id included):
    /// [version], or the latest blob fetched and ``CredentialUnsettled/Reason/versionMoved`` thrown (a fetch that fails:
    /// ``CredentialUnsettled/Reason/inFlight``, the "earlier request" refusal). Callers hold the credential lock.
    /// (VAULT-MESSAGING: pending spec PR for vettid/vettid.org#347.)
    private func checkVersion(_ version: Int64, before type: String) async throws {
        let info = try VaultJSON.decode(CredentialInfo.self, try await device.op("credential.version"))
        guard info.exists, let v = info.version else { throw VaultStateError(message: "no credential in the vault") }
        guard v != version else { return }
        do {
            try await fetch()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CredentialUnsettled(type: type, reason: .inFlight)
        }
        throw CredentialUnsettled(type: type, reason: .versionMoved)
    }

    /// [held] sent again, as the same request (§11.14.9 step 3): one deposit, one wait.
    func resendChange(_ held: HeldRequest) async throws -> [UInt8] {
        try await device.credentialLock.withLock { try await sendChange(held, utk: nil, first: false) }
    }

    /// Once the request may have been deposited, only the vault's own refusal (``VaultOpError``) leaves here as itself:
    /// every other failure (no answer, a cancellation, the relay, the device state or a key that could not be saved after
    /// the deposit, a blob that could not be kept after the answer) is ``ChangeUnanswered`` with the request, so that the
    /// change is decided (and can be sent again) rather than taken as not sent.
    private func sendChange(_ held: HeldRequest, utk: UtkRecord?, first: Bool) async throws -> [UInt8] {
        do {
            let r = first
                ? try await device.requestKept(held, sends: VaultDevice.appRetries + 1)
                : try await device.resend(held)
            return try await answered(held.type, utk: utk, r)
        } catch let e as VaultOpError {
            // An earlier credential operation applied without its answer: never resent with the typed secrets.
            if e.code == Self.codeStaleCredential { try? await fetch() }
            throw e
        } catch {
            // A cancellation too: a copy may have gone out, and the request is kept to be sent again.
            throw ChangeUnanswered(held: held)
        }
    }
}

/// What a change of PIN or password (or a renew) is sent as (VAULT-MESSAGING §11.14.9 "A lost answer"): its inner id and
/// `exp`, stored by the app before the send, and the blob version the request carries, confirmed by the vault.
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

/// A change of PIN or password refused with nothing sent, because an earlier credential operation is not settled
/// (VAULT-MESSAGING §11.14.9 "A lost answer" step 1): one still held the credential lock after the wait
/// ([reason] ``Reason/inFlight``), or the vault's blob had moved past this phone's (``Reason/versionMoved``; the latest
/// blob was fetched, so a change built again now goes with it).
public struct CredentialUnsettled: Error, Sendable, CustomStringConvertible {
    public enum Reason: Sendable {
        case inFlight
        case versionMoved
    }

    public let type: String
    public let reason: Reason

    public var description: String { "\(type): \(reason == .inFlight ? "an earlier operation in flight" : "the version moved")" }
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
