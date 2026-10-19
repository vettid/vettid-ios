#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. What Settings sends, as vettid-vault answers it: the account snapshot and the name change (VAULT-MESSAGING
// §10.2 `account.get`, §10.8 `account.name.set`, §11.13), the credential screen (§10.6 `credential.version`,
// `credential.unlock`, `credential.lock`, `credential.password.change`; §10.7 `item.list` of the critical items) and the
// PIN change of release R (§11.14.9 `pin.change`). The holder operations check the blob, the PIN and the password as an
// owner check does (``checkSecrets(_:pin:password:blob:)``) and rotate the CEK.
extension FakeVaultService {
    /// The credential's key id in `credential.version` (a placeholder; the app only shows it).
    public static let credentialKeyID = "test-credential-key"

    /// What the vault received in one `account.name.set`.
    public struct NameSetSeen: Sendable {
        public let pin: String
        public let password: String
        public let firstName: String
        public let lastName: String
    }

    /// What the vault received in one `pin.change`.
    public struct PinChangeSeen: Sendable {
        public let pin: String
        public let newPin: String
        public let password: String
        public let newUnlockSecret: [UInt8]
    }

    /// What the vault received in one `credential.password.change`.
    public struct PasswordChangeSeen: Sendable {
        public let pin: String?
        public let password: String
        public let newPassword: String
    }

    // MARK: - Switches and what was seen

    public var nameSets: [NameSetSeen] { locked { nameSetsValue } }
    public var pinChanges: [PinChangeSeen] { locked { pinChangesValue } }
    public var passwordChanges: [PasswordChangeSeen] { locked { passwordChangesValue } }
    /// The PIN the vault's unlock key is derived from now.
    public var currentPin: String? { locked { vaultPin } }
    /// The phone secret the vault holds now.
    public var currentSecret: [UInt8]? { locked { vaultSecret } }
    public var unlockTtlSetting: Int { locked { unlockTtl } }

    /// The account snapshot `account.get` returns (the body of §11.13, or nil before one arrived), as a new version, with
    /// `sync.event{account.changed}` when the vault is open.
    public func accountSnapshot(_ json: String?) {
        locked {
            snapshotJSON = json
            snapshotVersion += 1
            if vaultOpen { try? reply("sync.event", #"{"kind":"account.changed","version":\#(snapshotVersion)}"#) }
        }
    }

    /// The next `account.name.set` is answered `too_soon` until [date] (the stored snapshot's `allowed_after`).
    public func nameChangeAllowedAfter(_ date: Date?) { locked { nameAllowedAfter = date } }

    /// The member API processed the pending name request: its new [state] (and [reason]), with `account.changed`
    /// repeating the snapshot's version (0.19.0).
    public func settleNameRequest(_ state: String, reason: String? = nil) {
        locked {
            guard let last = nameSetsValue.last else { return }
            nameRequestJSON = Self.nameRequest(nameSeq, last.firstName, last.lastName, state, reason)
            if vaultOpen { try? reply("sync.event", #"{"kind":"account.changed","version":\#(snapshotVersion)}"#) }
        }
    }

    /// How many critical items `item.list` counts.
    public var criticalItems: Int {
        get { locked { criticalItemsValue } }
        set { locked { criticalItemsValue = newValue } }
    }

    /// Whether `pin.change`'s answer says `epoch_advanced: true` (it is stored either way).
    public var epochAdvanced: Bool {
        get { locked { epochAdvancedValue } }
        set { locked { epochAdvancedValue = newValue } }
    }

    /// Whether `pin.change` is answered: false stores the change and loses its answer (the app gets none; it stays in
    /// the response cache, which a resend of the same request reaches).
    public var answerPinChange: Bool {
        get { locked { !lostAnswerTypes.contains("pin.change") } }
        set { locked { if newValue { lostAnswerTypes.remove("pin.change") } else { lostAnswerTypes.insert("pin.change") } } }
    }

    /// Whether `credential.password.change` is answered: false makes the change and loses its answer.
    public var answerPasswordChange: Bool {
        get { locked { !lostAnswerTypes.contains("credential.password.change") } }
        set {
            locked {
                if newValue { lostAnswerTypes.remove("credential.password.change") } else { lostAnswerTypes.insert("credential.password.change") }
            }
        }
    }

    // MARK: - The requests

    /// The requests of Settings; `unsupported_type` for any other. Callers hold ``cond``.
    func settingsRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "account.get": try accountGet(m)
        case "account.name.set": try nameSet(m, body)
        case "credential.version": try reply(m.type, #"{"exists":\#(hasCredential),"version":\#(credentialVersion),"key":"\#(credentialKeyValue)","updated_at":"2026-10-04T12:00:00Z"\#(alarmMember)}"#, re: m.id)
        case "credential.unlock": try credentialUnlock(m, body)
        case "credential.lock":
            windowUntil = nil
            try reply(m.type, "{}", re: m.id)
        case "credential.password.change": try passwordChange(m, body)
        case "pin.change": try pinChange(m, body)
        case "item.list":
            let items = (0..<criticalItemsValue).map { #"{"item_id":"item-\#($0)","sensitivity":"critical"}"# }
            try reply(m.type, #"{"items":[\#(items.joined(separator: ","))],"next":null}"#, re: m.id)
        default: try secretsRequest(m, body)
        }
    }

    private func accountGet(_ m: Inner) throws {
        var answer = #"{"account":\#(snapshotJSON ?? "null"),"version":\#(snapshotVersion),"received_at":"2026-10-18T12:00:00Z""#
        if let r = nameRequestJSON { answer += #","name_request":\#(r)"# }
        try reply(m.type, answer + "}", re: m.id)
    }

    /// The sealed payload of a holder operation, its UTK spent (`utk_invalid` answered, and nil, when it is not one).
    func opened(_ m: Inner, _ body: JsonObject) throws -> JsonObject? {
        let utk = try body.string("utk_id")
        guard let ltk = utks.removeValue(forKey: utk) else {
            try reply(m.type, "{}", re: m.id, error: "utk_invalid")
            return nil
        }
        return try StrictJson.parseObject(try CredentialSeal.openPayload(ltk: ltk, vaultID: vaultID, utkID: utk, type: m.type, innerID: m.id, sealed: try body.base64("sealed")))
    }

    /// The rotated CEK's answer members (`credential`, `version`, `utks`), without the closing brace.
    func rotated() throws -> String {
        credentialVersion += 1
        return #"{"credential":"\#(Self.blob(credentialVersion))","version":\#(credentialVersion),"utks":\#(try issueUTKs(2))"#
    }

    /// `account.name.set` in vettid-vault's order (§10.8): the UTK, `too_soon`, the names (`bad_request`, nothing
    /// counted), then the owner check's steps, the CEK rotated and the request stored as `pending`.
    private func nameSet(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = NameSetSeen(pin: (try? p.string("pin")) ?? "", password: (try? p.string("password")) ?? "", firstName: (try? p.string("first_name")) ?? "", lastName: (try? p.string("last_name")) ?? "")
        nameSetsValue.append(seen)
        if let after = nameAllowedAfter, vaultNow < after {
            return try reply(m.type, #"{"allowed_after":"\#(Timestamps.formatMillis(after))"}"#, re: m.id, error: "too_soon")
        }
        guard !seen.firstName.isEmpty, !seen.lastName.isEmpty, !seen.firstName.contains(where: \.isNumber) else {
            return try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
        guard try checkSecrets(m, pin: seen.pin, password: seen.password, blob: try body.optString("credential")) else { return }
        nameSeq += 1
        let request = Self.nameRequest(nameSeq, seen.firstName, seen.lastName, "pending", nil)
        nameRequestJSON = request
        try reply(m.type, try rotated() + #","request":\#(request)}"#, re: m.id)
    }

    static func nameRequest(_ seq: Int64, _ first: String, _ last: String, _ state: String, _ reason: String?) -> String {
        var r = JsonBuilder().uint("seq", UInt64(seq)).string("first_name", first).string("last_name", last).string("requested_at", "2026-10-18T12:00:00Z").string("state", state)
        if let reason { r = r.string("reason", reason) }
        return r.build()
    }

    /// `credential.unlock`: the blob and the password; the window open for the setting's length and the CEK rotated.
    private func credentialUnlock(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        guard try body.optString("credential") == Self.blob(credentialVersion) else { return try reply(m.type, "{}", re: m.id, error: "stale_credential") }
        guard (try? p.string("password")) == vaultPassword else { return try reply(m.type, "{}", re: m.id, error: "bad_password") }
        let until = vaultNow.addingTimeInterval(TimeInterval(unlockTtl))
        windowUntil = until
        // As vettid-vault's `credential.unlock` (`respond`): the CEK rotates, the new blob and UTKs beside the expiry.
        try reply(m.type, try rotated() + #","expires_at":"\#(Timestamps.formatMillis(until))"}"#, re: m.id)
    }

    /// `credential.password.change` (release R: the PIN verified, §11.14.9): the new password kept, the CEK rotated.
    private func passwordChange(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = PasswordChangeSeen(pin: try p.optString("pin"), password: (try? p.string("password")) ?? "", newPassword: (try? p.string("new_password")) ?? "")
        passwordChangesValue.append(seen)
        // Release R: the PIN is required (vettid-vault answers bad_request without it).
        guard let pin = seen.pin else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard try checkSecrets(m, pin: pin, password: seen.password, blob: try body.optString("credential")) else { return }
        if let reason = weakPasswordReason {
            weakPasswordReason = nil
            return try reply(m.type, #"{"reason":"\#(reason)"}"#, re: m.id, error: "weak_password")
        }
        vaultPassword = seen.newPassword
        try reply(m.type, try rotated() + "}", re: m.id)
    }

    /// Release R `pin.change` (§11.14.9): checked as an owner check; the new PIN and the next epoch's secret stored, the
    /// CEK rotated, `epoch_advanced` answered (or the answer lost).
    private func pinChange(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try opened(m, body) else { return }
        let seen = PinChangeSeen(pin: (try? p.string("pin")) ?? "", newPin: (try? p.string("new_pin")) ?? "", password: (try? p.string("password")) ?? "", newUnlockSecret: (try? p.base64("new_unlock_secret")) ?? [])
        pinChangesValue.append(seen)
        // vettid-vault's order: the PIN and the password as an owner check, then the new PIN and the secret.
        guard try checkSecrets(m, pin: seen.pin, password: seen.password, blob: try body.optString("credential")) else { return }
        guard seen.newUnlockSecret.count == 32, seen.newPin.count >= 6 else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        vaultPin = seen.newPin
        vaultSecret = seen.newUnlockSecret
        try reply(m.type, try rotated() + (epochAdvancedValue ? #","epoch_advanced":true}"# : "}"), re: m.id)
    }
}

// swiftlint:enable line_length
#endif
