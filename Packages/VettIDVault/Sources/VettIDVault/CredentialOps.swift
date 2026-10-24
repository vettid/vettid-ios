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
    /// §3.5.3: the blob sent is not the vault's latest (the holder's own retry, after a lost answer).
    static let codeStaleCredential = "stale_credential"
    /// §3.5.9: this device is not the holder (VAULT-MESSAGING 0.51.1).
    static let codeForbidden = "forbidden"

    /// (VAULT-MESSAGING 0.52.0 §3.5.4 "Resync"; IOS-PLAN 0.1.16 §4.5 (2)) The resync answered again with no UTKs. The
    /// failure carries this code (shown as IOS-PLAN 0.1.15 §4.4's "Something went wrong (code: …)").
    static let codeUtkEmpty = "utk_empty"
    /// A resync within 10 minutes (scaled) of the device's last one, with body `{allowed_after}` (VAULT-MESSAGING §10.1).
    static let codeTooSoon = "too_soon"

    let device: VaultDevice
    let normalizePasswords: @Sendable () -> Bool
    /// ``VaultApi/credentialGate``: called with whether the operation's payload carries the PIN.
    var gate: @Sendable (_ carriesPin: Bool) async throws -> Void = { _ in }
    /// The wait of a change for the credential operations before it (``VaultApi/changeWaitSleep``).
    var changeWaitSleep: @Sendable (TimeInterval) async throws -> Void = VaultApi.sleep

    /// Stores the UTKs and the blob a response carries, and confirms the blob (`credential.ack`, §3.5.3). Returns how
    /// many UTKs it carried.
    @discardableResult
    func keep(_ body: [UInt8]) async throws -> Int {
        let o = try StrictJson.parseObject(body.isEmpty ? VaultJSON.empty : body)
        var utks = 0
        if let arr = try o.optArray("utks") {
            let list = try arr.map { v -> UtkRecord in
                let u = try Utk.parse(try v.asObject())
                return UtkRecord(id: u.id, ek: Base64s.encodeStd(u.ek.bytes), expiresAtMs: VaultDevice.ms(u.expiresAt))
            }
            try await device.keepUTKs(list)
            utks = list.count
        }
        guard let blob = VaultJSON.string(o, "credential") else { return utks }
        // Item operations carry the item's version as `version` and the credential's as `credential_version` (§10.6).
        guard let v = VaultJSON.int(o, "credential_version") ?? VaultJSON.int(o, "version"), v >= 0 else {
            throw VaultStateError(message: "credential without version")
        }
        try await device.keepCredential(blob: blob, version: v)
        _ = try await device.op("credential.ack", body: JsonBuilder().uint("version", UInt64(v)).bytes())
        return utks
    }

    /// An unexpired UTK, fetching a pool (`credential.utk.get`) when the device holds none. A UTK is spent once the
    /// request that presents it is sent, whatever the answer, and never goes back to the pool (VAULT-MESSAGING 0.52.0
    /// §3.5.4 "Using a UTK"; IOS-PLAN 0.1.16 §4.5 (1)). When the top-up carries no UTKs while this device holds none, the
    /// vault's pool for it is full of UTKs it no longer holds: one resync for this request (``resync()``), and
    /// `utk_empty` when that too carries none.
    func takeUTK() async throws -> UtkRecord {
        if let u = try await device.takeUTK() { return u }
        let topped = try await keep(try await device.op("credential.utk.get"))
        if let u = try await device.takeUTK() { return u }
        guard topped == 0 else { throw VaultStateError(message: "no UTK") }
        try await resync()
        if let u = try await device.takeUTK() { return u }
        throw VaultOpError(type: Self.typeUtkGet, code: Self.codeUtkEmpty, detail: "", body: nil)
    }

    static let typeUtkGet = "credential.utk.get"

    /// `credential.utk.get{"resync": true}` (VAULT-MESSAGING 0.52.0 §3.5.4 "Resync"): the vault drops this device's pool
    /// and issues a full one, kept here. Allowed once per 10 minutes (scaled); a `too_soon` is thrown as it is, and until
    /// its `allowed_after` (on the vault's clock) no resync is sent: the same refusal is thrown with nothing sent.
    private func resync() async throws {
        if let after = device.utkResyncAllowedAfter, device.vaultNow() < after {
            let body = JsonBuilder().string("allowed_after", Timestamps.formatMillis(after)).bytes()
            throw VaultOpError(type: Self.typeUtkGet, code: Self.codeTooSoon, detail: "", body: body)
        }
        do {
            try await keep(try await device.op(Self.typeUtkGet, body: JsonBuilder().bool("resync", true).bytes()))
        } catch let e as VaultOpError where e.code == Self.codeTooSoon {
            let after = e.body.flatMap { VaultJSON.string(VaultJSON.object($0), "allowed_after") }
            device.utkResyncAllowedAfter = after.flatMap { (try? Timestamps.parseMillis($0)) ?? (try? Timestamps.parseSeconds($0)) }
            throw e
        }
    }

    /// A sealed operation without the blob (create): [fields] sealed to a fresh UTK, in this order, each a string; the
    /// passwords among them normalized to NFC for a vault of release R. Returns the response body once its blob and UTKs
    /// are kept.
    func sealedOp(_ type: String, _ fields: [(String, String)]) async throws -> [UInt8] {
        let since = device.secretsSent
        return try await device.credentialLock.withLock {
            try noSecretSent(since, type)
            let utk = try await takeUTK()
            return try await sealed(type, utk: utk, fields: fields.map { .string($0.0, $0.1) }, CredOpOptions(withBlob: false))
        }
    }

    /// A sealed operation without the blob that carries the PIN (`audit.export`, VAULT-MESSAGING §10.9 History export):
    /// [fields] sealed to a fresh UTK, [outer] (members as encoded JSON) beside them, after the gate with the PIN.
    /// Returns the response body and the `ts` of the vault's answer.
    func sealedOpAt(_ type: String, _ fields: [SealedField], outer: [(String, String)]) async throws -> (body: [UInt8], ts: Date) {
        let since = device.secretsSent
        return try await device.credentialLock.withLock {
            try await gate(Self.carriesPin(fields))
            try noSecretSent(since, type)
            let utk = try await takeUTK()
            let a = try await sealedAt(type, utk: utk, fields: fields, CredOpOptions(withBlob: false, outerRaw: outer))
            return (a.body, a.ts)
        }
    }

    /// A credential operation with the blob (§3.5.3): [fields] sealed to a fresh UTK, the blob this device holds beside
    /// them (and [options]' outer members); on `stale_credential` the latest blob is fetched once and the operation sent
    /// again with a fresh UTK.
    func credOp(_ type: String, _ fields: [SealedField], _ options: CredOpOptions = CredOpOptions()) async throws -> [UInt8] {
        try await credOpAnswer(type, fields, options).body
    }

    /// ``credOp(_:_:_:)`` whose answer carries a value sealed to a one-time reply key (§3.5.4): a fresh key per attempt,
    /// its public key sent as the payload's `reply_key`, and the answer's [member] (standard base64) opened with it for
    /// the request's inner id. Returns the body and the opened plaintext, which the caller wipes. Mirrors vettid-android
    /// `CredentialOps.credOp` with `reply = true` and `open`.
    func credOpOpening(
        _ type: String, _ fields: [SealedField], member: String, _ options: CredOpOptions = CredOpOptions()
    ) async throws -> (body: [UInt8], opened: [UInt8]) {
        var o = options
        o.replyMember = member
        let a = try await credOpAnswer(type, fields, o)
        guard let opened = a.opened else { throw VaultStateError(message: "\(type) without \(member)") }
        return (a.body, opened)
    }

    private func credOpAnswer(_ type: String, _ fields: [SealedField], _ options: CredOpOptions) async throws -> Answered {
        let since = device.secretsSent
        return try await device.credentialLock.withLock {
            // Nothing is taken from the pool for an operation that cannot be sent.
            if device.credentialBlob == nil { throw VaultStateError(message: "no credential on this device") }
            // Under the lock: a change that started after the caller's own check is seen here, and one that went out
            // (and was even decided) while this waited for the lock.
            try await gate(Self.carriesPin(fields))
            try noSecretSent(since, type)
            do {
                await options.beforeSend?()
                return try await sealedAt(type, utk: try await takeUTK(), fields: fields, options)
            } catch let e as VaultOpError where e.code == Self.codeStaleCredential {
                try await fetch()
                // Never resent with the typed secrets while a change may have moved them (§11.14.9 step 4).
                try await gate(Self.carriesPin(fields))
                try noSecretSent(since, type)
                await options.beforeSend?()
                return try await sealedAt(type, utk: try await takeUTK(), fields: fields, options)
            }
        }
    }

    /// (VAULT-MESSAGING 0.47.0 §11.14.9 step 2) Refused with nothing sent when a change or a renew went out since
    /// [since] (``VaultDevice/secretsSent`` read when the operation began, before it waited for the lock): it would carry
    /// the PIN or password typed before that change, or the secret before that renew, and a wrong one counts as a failed
    /// owner check. The gate alone does not see a change answered and decided before this got the lock. The refusal is
    /// the "earlier request" text. Callers hold the credential lock. Mirrors vettid-android `secretGeneration`.
    private func noSecretSent(_ since: Int, _ type: String) throws {
        guard device.secretsSent == since else { throw CredentialUnsettled(type: type, reason: .inFlight) }
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
        try await sealedAt(type, utk: utk, fields: fields, options, id: id, onOK: onOK).body
    }

    /// A sealed operation's answer: its body, the `ts` of the vault's answer, and the value it carries sealed to the
    /// request's reply key, opened (``CredOpOptions/replyMember``).
    struct Answered {
        let body: [UInt8]
        let ts: Date
        var opened: [UInt8]?
    }

    /// ``sealed(_:utk:fields:_:id:onOK:)`` with the `ts` of the vault's answer, and with [options]' reply key the value
    /// sealed to it, opened.
    private func sealedAt(
        _ type: String, utk: UtkRecord, fields: [SealedField], _ options: CredOpOptions, id: String? = nil,
        onOK: (@Sendable () async -> Void)? = nil
    ) async throws -> Answered {
        let id = id ?? device.newRequestID()
        // A fresh one-time reply key for this attempt (§3.5.4), destroyed once its value is opened or the request ended.
        let reply = options.replyMember == nil ? nil : try KemPrivateKey.generate()
        defer { reply?.destroy() }
        var fields = fields
        if let reply { fields.append(.string("reply_key", Base64s.encodeStd(reply.publicKey.bytes))) }
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
        var a = Answered(body: try await answered(type, r), ts: r.ts)
        if let reply, let member = options.replyMember {
            guard let vaultID = device.vaultID, let sealed = VaultJSON.string(VaultJSON.object(a.body), member) else {
                throw VaultStateError(message: "\(type) without \(member)")
            }
            a.opened = try CredentialSeal.openValue(reply: reply, vaultID: vaultID, innerID: id, sealed: try Base64s.decodeStd(sealed))
        }
        return a
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
            case .raw(let k, let json): b.raw(k, json)
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
        for (k, v) in options.outerRaw { outer.raw(k, v) }
        return outer.bytes()
    }

    /// The answer of a sealed operation: its blob and UTKs kept, or its refusal as ``VaultOpError``. Its UTK stays spent
    /// either way (VAULT-MESSAGING 0.52.0 §3.5.4 "Using a UTK"; `signer_unconfirmed` too: a new attempt takes a fresh one).
    private func answered(_ type: String, _ r: VaultMessage) async throws -> [UInt8] {
        guard r.inner.status == Inner.statusOK else {
            // The error's body: `weak_password` carries `reason` (§11.14.7), `backoff` its `retry_after` (§10.1).
            throw VaultOpError(
                type: type, code: r.inner.error?.code ?? "", detail: r.inner.error?.message ?? "",
                body: r.inner.body.isEmpty ? nil : r.inner.body
            )
        }
        try await keep(r.body)
        return r.body
    }

    // MARK: - The changes of PIN and password, and the renew (§11.14.9 "A lost answer")

    /// `pin.change` or `credential.password.change`. Step 1 (VAULT-MESSAGING 0.47.0 §11.14.9, "Nothing else in flight",
    /// "Settled on answers only", "Sent with the vault's current blob"; ``settledAndChecked``): every earlier credential
    /// request of this device settled and the blob's version confirmed by the vault (or the vault's blob fetched), under
    /// the credential lock; only then is the request fixed (a new inner id, an `exp` 10 minutes after the vault's clock as
    /// last seen, the confirmed version) and handed to [onMarker], which stores the unresolved change (and a PIN change's
    /// candidate) and returns the payload members that go with it (a PIN change's next secret). Nothing is stored for a
    /// change refused before that. A `stale_credential` is **not** retried with the same secrets: the latest blob is
    /// fetched and the refusal thrown. No answer (none to the automatic resends of §8.6, every deposit straight to the
    /// relay) is ``ChangeUnanswered`` with the request to send again.
    func change(_ type: String, _ fields: [SealedField], since: Int? = nil, onMarker: OnMarker) async throws -> [UInt8] {
        try await settledAndChecked(type, Checks(gate: false), since: since) { change, utk in
            let more = try await marked(change, utk, onMarker)
            try sameVersion(change, type)
            device.secretSent()
            let held = HeldRequest(
                type: type, id: change.id, exp: change.exp,
                body: try build(type, utk: utk, fields: fields + more, id: change.id, CredOpOptions())
            )
            try await device.trackCredential(change.id, exp: change.exp)
            return try await sendChange(held, first: true)
        }
    }

    /// `credential.reset` by the holder, sent and decided as a change is (VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to
    /// `credential.reset`" step 1): every earlier request settled, the `credential.version` pre-check, whose `key` goes
    /// into the request as the held key (an answer without one refuses the reset with nothing sent, the "earlier request"
    /// text), [onMarker] storing the unresolved change, an `exp`, and no answer as ``ChangeUnanswered`` with the request
    /// to send again. A `stale_credential` is not retried: the latest blob is fetched and the refusal thrown. The reset
    /// replaces the password and the credential key, so it counts as a secret sent (``VaultDevice/secretsSent``) as it
    /// goes out and again once it ended, both under the credential lock, as vettid-android counts it.
    func reset(_ type: String, _ fields: [SealedField], since: Int? = nil, onMarker: OnMarker) async throws -> [UInt8] {
        try await settledAndChecked(type, Checks(gate: false, needsKey: true), since: since) { change, utk in
            let more = try await marked(change, utk, onMarker)
            try sameVersion(change, type)
            device.secretSent()
            defer { device.secretSent() }
            let held = HeldRequest(
                type: type, id: change.id, exp: change.exp,
                body: try build(type, utk: utk, fields: fields + more, id: change.id, CredOpOptions())
            )
            try await device.trackCredential(change.id, exp: change.exp)
            return try await sendChange(held, first: true)
        }
    }

    /// `vault.secret.renew` after the same steps as a change, the credential gate included (VAULT-MESSAGING 0.47.0
    /// §11.14.9 step 1: every earlier request settled and the vault's current blob; IOS-PLAN 0.1.6 §6.3), [onMarker]
    /// storing the renew's record and request. [onAnswered] runs on its own `ok` answer, before its blob is kept. Any
    /// refusal of its own request, `stale_credential` included, means it did not apply: `stale_credential` is not
    /// retried, the latest blob is fetched and the refusal thrown (VAULT-MESSAGING 0.47.0 §11.14.9 step 1, "A renew is
    /// settled before a PIN change"). A failure once it may have gone out is ``RequestUnanswered``.
    func renew(
        _ type: String, _ fields: [SealedField], since: Int? = nil, onMarker: OnMarker,
        onAnswered: @escaping @Sendable () async -> Void
    ) async throws -> [UInt8] {
        try await settledAndChecked(type, Checks(gate: true), since: since) { change, utk in
            let more = try await marked(change, utk, onMarker)
            try sameVersion(change, type)
            device.secretSent()
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

    /// The blob this device holds is still the one [change] was fixed on, right before the request is built: a blob kept
    /// outside the credential lock (a fetch or a UTK top-up of a decision) never goes with a request fixed on another
    /// version. Else refused with nothing sent; the caller clears the marker it stored (``VaultManager`` `changing`).
    private func sameVersion(_ change: ChangeRequest, _ type: String) throws {
        guard device.credentialVersion == change.version else { throw CredentialUnsettled(type: type, reason: .inFlight) }
    }

    /// [onMarker] for [change]; [utk] goes back to the pool when it fails: it never left the phone (IOS-PLAN 0.1.16 §4.5
    /// (1)).
    private func marked(_ change: ChangeRequest, _ utk: UtkRecord, _ onMarker: OnMarker) async throws -> [SealedField] {
        do {
            return try await onMarker(change)
        } catch {
            try? await device.returnUTK(utk)
            throw error
        }
    }

    /// Step 1 before a change or a renew (VAULT-MESSAGING 0.47.0 §11.14.9 "Sent with the vault's current blob"): every
    /// earlier credential request of this device settled (the outbox flushed, waited for at most ``inFlightWait``), then
    /// under the credential lock (at most as long): the credential gate for a renew ([gate]), no change or renew gone out
    /// since this began, the settling checked again, `credential.version` confirming the blob this device holds or the
    /// vault's fetched (``checkVersion``), a UTK taken, and [body] with the request fixed on the confirmed version. Else
    /// refused with nothing sent or stored.
    /// [since]: ``VaultDevice/secretsSent`` as the caller read it before its own checks (a renew's decision before a PIN
    /// change may wait on the network); nil: read now.
    private func settledAndChecked(
        _ type: String, _ checks: Checks, since given: Int?, _ body: (ChangeRequest, UtkRecord) async throws -> [UInt8]
    ) async throws -> [UInt8] {
        let since = given ?? device.secretsSent
        guard await device.awaitCredentialSettled(within: Self.inFlightWait, sleep: changeWaitSleep) else {
            throw CredentialUnsettled(type: type, reason: .inFlight)
        }
        let sent = try await device.credentialLock.withLock(within: Self.inFlightWait, sleep: changeWaitSleep) {
            guard device.credentialBlob != nil, let version = device.credentialVersion else {
                throw VaultStateError(message: "no credential on this device")
            }
            if checks.gate { try await gate(true) }
            try noSecretSent(since, type)
            // One that started meanwhile, before this took the lock.
            guard await device.credentialSettled() else { throw CredentialUnsettled(type: type, reason: .inFlight) }
            let confirmed = try await checkVersion(version, before: type)
            if checks.needsKey, confirmed.key == nil { throw CredentialUnsettled(type: type, reason: .inFlight) }
            let utk = try await takeUTK()
            let change = ChangeRequest(
                id: device.newRequestID(), exp: try await requestExp(), version: confirmed.version, key: confirmed.key
            )
            return try await body(change, utk)
        }
        guard let sent else { throw CredentialUnsettled(type: type, reason: .inFlight) }
        return sent
    }

    /// What ``settledAndChecked`` checks besides: the credential gate (a renew), and a `key` in the pre-check's answer (a
    /// reset, whose decision compares it).
    struct Checks {
        var gate: Bool
        var needsKey = false
    }

    /// How long a change waits for the credential operations before it (§11.14.9 step 1: at most 30 s).
    static let inFlightWait: TimeInterval = 30

    /// The `exp` of a credential request sent now: 10 minutes after the vault's clock as last seen; in a process that has
    /// not heard from the vault yet, `credential.version` is asked first (as ``VaultApi/requestExp()``).
    func requestExp() async throws -> Date {
        if !device.knowsVaultTime { _ = try await device.request("credential.version") }
        return device.vaultNow().addingTimeInterval(ChangeRequest.validFor)
    }

    /// `credential.version` before a change or a renew (VAULT-MESSAGING 0.47.0 §11.14.9 step 1, "Sent with the vault's
    /// current blob"; a request as any other, §8.6's resends of the same id included), returning the version the request
    /// goes with: [version] when the vault's is the same; otherwise an earlier operation applied without its answer, and
    /// the latest blob is fetched and kept, and the request goes with it when the fetched version is the vault's. An
    /// answer that is an error, has no version or says no credential counts as different (as vettid-android does): the
    /// fetch runs, and the request cannot go since the vault's version is not known. A fetch that fails or gives another
    /// version is ``CredentialUnsettled/Reason/inFlight`` (the "earlier request" refusal), never the answer's own code; no
    /// answer to the question is its own failure; nothing is sent either way. Callers hold the credential lock.
    private func checkVersion(_ version: Int64, before type: String) async throws -> (version: Int64, key: String?) {
        let answer = try await device.request("credential.version")
        let info: CredentialInfo? = answer.inner.status == Inner.statusOK
            ? try? VaultJSON.decode(CredentialInfo.self, answer.body) : nil
        let vaults = info.flatMap { $0.exists ? $0.version : nil }
        let key = info?.key.flatMap { $0.isEmpty ? nil : $0 }
        if let v = vaults, v == version { return (v, key) }
        do {
            try await fetch()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CredentialUnsettled(type: type, reason: .inFlight)
        }
        guard let v = vaults, device.credentialBlob != nil, device.credentialVersion == v else {
            throw CredentialUnsettled(type: type, reason: .inFlight)
        }
        return (v, key)
    }

    /// [held] sent again, as the same request (§11.14.9 step 3): one deposit, one wait.
    func resendChange(_ held: HeldRequest) async throws -> [UInt8] {
        try await device.credentialLock.withLock { try await sendChange(held, first: false) }
    }

    /// Once the request may have been deposited, only the vault's own refusal of this request (a ``VaultOpError`` of its
    /// type), and the vault's `forbidden` to any request of it (VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13: another phone is
    /// the holder), leave here as themselves: every other failure (no answer, a cancellation, the relay, the device state or a key
    /// that could not be saved after the deposit, a blob that could not be kept after the answer, and a refusal of a
    /// follow-up after its `ok`, such as `credential.ack` or `credential.utk.get`) is ``ChangeUnanswered`` with the
    /// request, so that the change is decided (and can be sent again) rather than taken as not sent or refused.
    private func sendChange(_ held: HeldRequest, first: Bool) async throws -> [UInt8] {
        do {
            let r = first
                ? try await device.requestKept(held, sends: VaultDevice.appRetries + 1)
                : try await device.resend(held)
            return try await answered(held.type, r)
        } catch let e as VaultOpError where e.type == held.type || e.code == Self.codeForbidden {
            // An earlier credential operation applied without its answer: never resent with the typed secrets.
            if e.code == Self.codeStaleCredential { try? await fetch() }
            throw e
        } catch {
            // A cancellation too: a copy may have gone out, and the request is kept to be sent again.
            throw ChangeUnanswered(held: held)
        }
    }
}

/// What a change of PIN or password (or a renew, or a reset) is sent as (VAULT-MESSAGING §11.14.9 "A lost answer"): its
/// inner id and `exp`, stored by the app before the send, the blob version the request carries, confirmed by the vault,
/// and the credential key the vault's pre-check answer gave ([key]; nil when it gave none).
public struct ChangeRequest: Equatable, Sendable {
    /// How long after the vault's clock as last seen a change may still be acted on.
    public static let validFor: TimeInterval = 600

    public let id: String
    public let exp: Date
    public let version: Int64
    public let key: String?

    public init(id: String, exp: Date, version: Int64, key: String? = nil) {
        self.id = id
        self.exp = exp
        self.version = version
        self.key = key
    }
}

/// A change of PIN or password got no answer: the vault may have applied it. [held] is the request, to send again as
/// the same request while its `exp` has not passed.
public struct ChangeUnanswered: Error, Sendable, CustomStringConvertible {
    public let held: HeldRequest

    public var description: String { "\(held.type): no answer" }
}

/// A credential operation refused with nothing sent, because an earlier one is not settled (VAULT-MESSAGING 0.47.0
/// §11.14.9 "A lost answer" steps 1 and 2): one still held the credential lock after the wait, the vault's blob could not
/// be made this phone's, or a change or a renew went out while this waited ([reason] ``Reason/inFlight``, the "earlier
/// request" text).
public struct CredentialUnsettled: Error, Sendable, CustomStringConvertible {
    public enum Reason: Sendable {
        case inFlight
    }

    public let type: String
    public let reason: Reason

    public var description: String { "\(type): an earlier operation in flight" }
}

/// What a credential operation carries besides its sealed members: the blob ([withBlob]; not for `credential.create`),
/// members of the outer body beside it ([outer]: `vault.delete`'s `confirm`, §12.5), whether a failure once the
/// request may have gone out is ``RequestUnanswered`` ([unanswered]) rather than the failure itself, and the request's
/// `exp` (§5.3; a retry after `stale_credential` keeps it).
struct CredOpOptions: Sendable {
    var withBlob = true
    var outer: [(String, String)] = []
    /// Outer members whose values are encoded JSON (`audit.export`'s filters, `format` and `upto_seq`).
    var outerRaw: [(String, String)] = []
    var unanswered = false
    var exp: Date?
    /// The member of the answer sealed to a one-time reply key (§3.5.4: a critical item's `values_sealed`), which the
    /// request then carries as `reply_key`.
    var replyMember: String?
    /// Runs before each send of the operation (the first, and the one after `stale_credential`), outside the request: a
    /// transfer's approval renews the standing token it issued to the vault there (VAULT-MESSAGING §11.14.10).
    var beforeSend: (@Sendable () async -> Void)?
}

/// A credential operation whose answer did not arrive once its request may have gone out (no answer to the automatic
/// resends of §8.6, or a deposit that failed and may still go out from the outbox): the vault may have acted on it.
public struct RequestUnanswered: Error, Sendable, CustomStringConvertible {
    public let type: String

    public var description: String { "\(type): no answer" }
}

/// One member of a sealed payload (§3.5.4): a string (a password is normalized for a vault of release R), a bool, or
/// encoded JSON.
enum SealedField: Sendable {
    case string(String, String)
    case bool(String, Bool)
    /// A member whose value is encoded JSON (a critical item's `item`, §10.7).
    case raw(String, String)
}
