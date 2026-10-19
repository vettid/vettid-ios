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
    /// The password the credential opens with now.
    public var currentPassword: String? { locked { vaultPassword } }

    /// A clone was presented (§3.5.9): an alarm opens in state `frozen`, the unlock window ends, and the holder gets
    /// `credential.alarm` when the vault is open. Returns the alarm's id.
    @discardableResult
    public func raiseCloneAlarm(presenter: String = "other") -> String {
        locked {
            let a = FakeAlarm(id: Ulid.new(), state: "frozen", at: vaultNow)
            alarmValue = a
            windowUntil = nil
            if vaultOpen {
                try? reply("credential.alarm", #"{"alarm_id":"\#(a.id)","kind":"clone","state":"frozen","at":"\#(Timestamps.formatMillis(a.at))","presenter":"\#(presenter)","version":\#(credentialVersion)}"#)
            }
            return a.id
        }
    }

    // MARK: - The requests

    /// `credential.alarm.confirm`, `credential.rotate` and `credential.reset`; `unsupported_type` for any other. Callers
    /// hold ``cond``.
    func credentialRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "credential.alarm.confirm": try alarmConfirm(m, body)
        case "credential.rotate": try rotate(m, body)
        case "credential.reset": try reset(m, body)
        default: try reply(m.type, "{}", re: m.id, error: "unsupported_type")
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

    /// The blob (`stale_credential`), then the password under its backoff (`bad_password`, not a failed check); a new key,
    /// the CEK rotated, the window ended and an open alarm resolved.
    private func rotate(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let password = (try? p.string("password")) ?? ""
        rotationsValue.append(password)
        guard try body.optString("credential") == Self.blob(credentialVersion) else { return try reply(m.type, "{}", re: m.id, error: "stale_credential") }
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
        credentialVersion = 0
        credentialKeyValue = "\(Self.credentialKeyID)-new-\(resetsValue.count)"
        windowUntil = nil
        startCheckClock()
        try reply(m.type, try rotated() + #","key":"\#(credentialKeyValue)"}"#, re: m.id)
    }
}

// swiftlint:enable line_length
#endif
