#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. The rotation, a new credential and the clone alarm as vettid-vault answers them
// (`features/credential/credential.go`): `credential.rotate` (the blob, then the password under its backoff; a new key, the
// CEK rotated, the window ended and an open alarm resolved), the holder's `credential.reset` (checked as an owner check,
// its `bad_pin` and `bad_password` failed checks; then the new password's rules; version 1 of a new credential under a
// new key, the owner-check clock started afresh), and `credential.alarm.confirm` (`frozen` to `rotation_required`, with
// `sync.event`). While an alarm is open the credential operations are refused before the UTK is spent (`gate`).
extension FakeVaultService {
    /// An open clone alarm (§3.5.9).
    struct FakeAlarm {
        let id: String
        var state: String
        let at: Date
    }

    /// What the vault received in one `credential.reset`.
    public struct ResetSeen: Sendable {
        public let pin: String
        public let password: String
        public let newPassword: String
    }

    /// The types a frozen credential still accepts; in state `rotation_required` also ``allowedRotation``.
    static let allowedFrozen: Set = ["credential.utk.get", "credential.version", "credential.lock", "credential.alarm.confirm"]
    static let allowedRotation: Set = ["credential.get", "credential.ack", "credential.rotate"]
    /// The credential feature's types the fake handles (the alarm's gate applies to them).
    static let credentialTypes: Set = [
        "credential.get", "credential.ack", "credential.unlock", "credential.rotate", "credential.password.change", "credential.reset",
        "pin.change", "vault.secret.renew", "vault.delete", typeOwnerCheck, "account.name.set",
    ]

    // MARK: - Switches and what was seen

    /// The passwords of each `credential.rotate` the vault received.
    public var rotations: [String] { locked { rotationsValue } }
    public var resets: [ResetSeen] { locked { resetsValue } }
    /// The `mine` of each `credential.alarm.confirm` the vault received.
    public var alarmConfirms: [Bool] { locked { alarmConfirmsValue } }
    /// The open alarm's state, nil without one.
    public var alarmState: String? { locked { alarmValue?.state } }
    /// The credential key `credential.version` shows.
    public var credentialKey: String { locked { credentialKeyValue } }
    /// The next [times] requests of [type] that reach the open vault are refused with [code] before anything is done (a
    /// `forbidden` to a phone that is no longer the holder; a `credential.ack` refused after the operation's own `ok`).
    public func refuse(_ type: String, with code: String, times: Int = Int.max) {
        locked { refusedTypesValue[type] = (code, times) }
    }

    /// `credential.version` answers without its `key`.
    public var versionWithoutKey: Bool {
        get { locked { versionWithoutKeyValue } }
        set { locked { versionWithoutKeyValue = newValue } }
    }
    /// The password the credential opens with now.
    public var currentPassword: String? { locked { vaultPassword } }

    /// A clone was presented (§3.5.9): an alarm opens in state `frozen`, the unlock window ends, and the holder gets
    /// `credential.alarm` when the vault is open. Returns the alarm's id.
    /// [told] false: the alert and the sync event are lost on their way (the phone learns of the alarm only by asking).
    @discardableResult
    public func raiseCloneAlarm(presenter: String = "other", told: Bool = true) -> String {
        locked { openAlarm(presenter: presenter, version: credentialVersion, told: told).id }
    }

    /// The open alarm moves to `rotation_required` as another of the owner's apps answered it, without telling this one.
    public func requireRotation() { locked { alarmValue?.state = "rotation_required" } }

    /// How many times the vault rotated its `ik` and `kem` (§3.4).
    public var identityRotations: Int { locked { identityRotationsValue } }

    /// Whether the vault-initiated rekey after the last identity rotation is still waiting for the device's hs.resp.
    public var rekeyPending: Bool { locked { rekeying != nil } }

    /// The blob the vault holds now.
    var currentBlob: String { Self.blob(credentialVersion, generation: credentialGeneration) }

    /// Opens an alarm in state `frozen`: the window ends, and the holder gets `credential.alarm` and the sync event when
    /// the vault is open. Callers hold ``cond``.
    @discardableResult
    func openAlarm(presenter: String, version: Int64, told: Bool = true) -> FakeAlarm {
        let a = FakeAlarm(id: Ulid.new(), state: "frozen", at: vaultNow)
        alarmValue = a
        windowUntil = nil
        if vaultOpen, told {
            try? reply("credential.alarm", #"{"alarm_id":"\#(a.id)","kind":"clone","state":"frozen","at":"\#(Timestamps.formatMillis(a.at))","presenter":"\#(presenter)","version":\#(version)}"#)
            try? reply("sync.event", #"{"kind":"credential.alarm","alarm_id":"\#(a.id)","state":"frozen"}"#)
        }
        return a
    }

    /// vettid-vault's `checkBlob` for the holder (this phone): the current blob passes (and confirms its version); the
    /// previous version while the current one is not confirmed is the holder's own retry (`stale_credential`); anything
    /// else is a clone (`clone`): the freeze code while an alarm is open, otherwise a new alarm and `credential_frozen`.
    /// False when refused (the refusal is answered). Callers hold ``cond``.
    func checkBlob(_ m: Inner, _ blob: String?) throws -> Bool {
        if blob == currentBlob {
            credentialAcked = true
            return true
        }
        let presented = blob.flatMap(Self.blobVersion)
        if let p = presented, p.generation == credentialGeneration, p.version + 1 == credentialVersion, !credentialAcked {
            try reply(m.type, "{}", re: m.id, error: "stale_credential")
            return false
        }
        if let a = alarmValue {
            try reply(m.type, "{}", re: m.id, error: a.state == "rotation_required" ? "rotation_required" : "credential_frozen")
            return false
        }
        try reply(m.type, "{}", re: m.id, error: "credential_frozen")
        openAlarm(presenter: "holder", version: presented?.version ?? 0)
        return false
    }

    /// The version and generation of a blob of ``blob(_:generation:)``; nil for any other.
    static func blobVersion(_ blob: String) -> (version: Int64, generation: Int)? {
        if blob == "AQID" { return (1, 0) }
        guard let raw = try? Base64s.decodeStd(blob), let text = String(bytes: raw, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "-")
        if parts.count == 2, parts[0] == "blob", let v = Int64(parts[1]) { return (v, 0) }
        if parts.count == 3, parts[0] == "blob", parts[1].hasPrefix("g"), let g = Int(parts[1].dropFirst()), let v = Int64(parts[2]) {
            return (v, g)
        }
        return nil
    }

    /// `credential.ack{version}`: the current version confirmed (`stale_credential` for any other). Callers hold ``cond``.
    func credentialAck(_ m: Inner, _ body: JsonObject) throws {
        guard let v = try? body.uint("version", min: 1, max: StrictJson.maxSafeInteger), Int64(v) == credentialVersion else {
            return try reply(m.type, "{}", re: m.id, error: "stale_credential")
        }
        credentialAcked = true
        try reply(m.type, "{}", re: m.id)
    }

    /// vettid-vault's `rotateIdentity` (§3.4): a new `ik` and `kem`, `identity.rotate{rotation}` to the device, then a
    /// vault-initiated rekey (§6.5) whose hs.resp ``rekeyResponse(_:)`` completes. Callers hold ``cond``.
    func rotateIdentity() throws {
        let newIk = Ed25519PrivateKey.generate()
        let newKem = try KemPrivateKey.generate()
        let rotation = try Rotation.create(old: ik, new: newIk, newKem: newKem.publicKey)
        ik = newIk
        kem = newKem
        identityRotationsValue += 1
        try reply("identity.rotate", #"{"rotation":\#(rotation.marshal())}"#)
        guard let device, let deviceIk, let current = keyring.current() else { return }
        let relay = RelayAddr(url: vaultRelay.baseURL, mailbox: vaultMailbox, pk: relayKey.publicKey)
        let ini = try Initiator.create(InitiatorConfig(
            purpose: .rekey, ctx: "", identity: ik, staticKem: kem.publicKey, relay: relay, responderIk: deviceIk, responderEk: nil,
            responderRelayKey: device.relay.pk, current: current, policy: .vaultToDevice
        ))
        rekeying?.abort()
        rekeying = ini
        queue(ini.envelope)
    }

    /// The device's hs.resp to the rekey: the new epoch active and hs.fin sent. False when [raw] is not one (a sealed-mode
    /// deposit only answers a handshake). Callers hold ``cond``.
    func rekeyResponse(_ raw: [UInt8]) throws -> Bool {
        guard let ini = rekeying, let device, (try? Envelope.parse(raw))?.mode == .sealed else { return false }
        rekeying = nil
        let res = try ini.handleResp(raw, collectSender: device.relay.pk, now: Date())
        keyring.activate(res.epoch, now: Date())
        queue(res.fin)
        return true
    }

    // MARK: - The requests

    /// `credential.alarm.confirm`, `credential.rotate` and `credential.reset`; then the connections
    /// (``connectionsRequest(_:_:)``). Callers hold ``cond``.
    func credentialRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "credential.alarm.confirm": try alarmConfirm(m, body)
        case "credential.rotate": try rotate(m, body)
        case "credential.reset": try reset(m, body)
        default: try connectionsRequest(m, body)
        }
    }

    /// The freeze of an open alarm for [type]: `credential_frozen` or `rotation_required`; nil when it may run. Callers
    /// hold ``cond``.
    func alarmRefusal(_ type: String) -> String? {
        guard let a = alarmValue, Self.credentialTypes.contains(type), !Self.allowedFrozen.contains(type) else { return nil }
        if a.state == "rotation_required" { return Self.allowedRotation.contains(type) ? nil : "rotation_required" }
        return "credential_frozen"
    }

    /// `credential.version`'s `alarm` member, with its leading comma; empty without an alarm. Callers hold ``cond``.
    var alarmMember: String {
        guard let a = alarmValue else { return "" }
        return #","alarm":{"alarm_id":"\#(a.id)","state":"\#(a.state)","at":"\#(Timestamps.formatMillis(a.at))"}"#
    }

    private func alarmConfirm(_ m: Inner, _ body: JsonObject) throws {
        let id = try body.string("alarm_id")
        let mine = try body.bool("mine")
        alarmConfirmsValue.append(mine)
        guard var a = alarmValue, a.id == id else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        if a.state == "frozen" {
            a.state = "rotation_required"
            alarmValue = a
            try reply("sync.event", #"{"kind":"credential.alarm","alarm_id":"\#(a.id)","state":"rotation_required"}"#)
        }
        try reply(m.type, #"{"state":"\#(a.state)"}"#, re: m.id)
    }

    /// The blob (``checkBlob(_:_:)``), then the password under its backoff (`bad_password`, not a failed check); a new
    /// key, the CEK rotated, the window ended, an open alarm resolved, and the vault's identity rotated.
    private func rotate(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let password = (try? p.string("password")) ?? ""
        rotationsValue.append(password)
        guard try checkBlob(m, try body.optString("credential")) else { return }
        if let b = passwordNotBefore, vaultNow < b {
            return try reply(m.type, #"{"retry_after":\#(max(Int(b.timeIntervalSince(vaultNow).rounded(.up)), 1))}"#, re: m.id, error: "backoff")
        }
        guard password == vaultPassword else {
            passwordFailures += 1
            return try reply(m.type, "{}", re: m.id, error: "bad_password")
        }
        passwordFailures = 0
        credentialKeyValue = "\(Self.credentialKeyID)-\(rotationsValue.count)"
        windowUntil = nil
        try reply(m.type, try rotated() + #","key":"\#(credentialKeyValue)"}"#, re: m.id)
        if let a = alarmValue {
            alarmValue = nil
            try reply("sync.event", #"{"kind":"credential.alarm","alarm_id":"\#(a.id)","state":"resolved"}"#)
        }
        try rotateIdentity()
    }

    /// Checked as an owner check (a wrong PIN or password is a failed check), then the new password's rules; version 1 of
    /// a new credential under a new key, the window ended and the owner-check clock started afresh.
    private func reset(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = ResetSeen(pin: (try? p.string("pin")) ?? "", password: (try? p.string("password")) ?? "", newPassword: (try? p.string("new_password")) ?? "")
        resetsValue.append(seen)
        guard try checkSecrets(m, pin: seen.pin, password: seen.password, blob: try body.optString("credential")) else { return }
        if let reason = weakPasswordReason {
            weakPasswordReason = nil
            return try reply(m.type, #"{"reason":"\#(reason)"}"#, re: m.id, error: "weak_password")
        }
        vaultPassword = seen.newPassword
        // A new credential: no blob of the old one is accepted again.
        credentialGeneration += 1
        credentialVersion = 0
        credentialKeyValue = "\(Self.credentialKeyID)-new-\(resetsValue.count)"
        windowUntil = nil
        startCheckClock()
        try reply(m.type, try rotated() + #","key":"\#(credentialKeyValue)"}"#, re: m.id)
    }
}

// swiftlint:enable line_length
#endif
