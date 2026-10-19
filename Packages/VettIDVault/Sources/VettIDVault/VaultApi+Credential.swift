import Foundation
import VettIDCrypto

/// `settings.get` (VAULT-MESSAGING §10.8): the settings' version and every known key with its current or default value,
/// each as its exact JSON text (`true`, `300`, `"x"`).
public struct VaultSettings: Sendable {
    public let version: UInt64
    public let values: [String: String]

    public init(version: UInt64, values: [String: String]) {
        self.version = version
        self.values = values
    }
}

// The credential calls (§3.5.5, §3.5.7, §10.6), the settings (§10.8) and the count of critical items (§10.7).
extension VaultApi {
    /// `credential.create`: creates the Protean Credential under [password] and keeps the blob (enrollment, §3.5.7).
    /// (Release R, §11.14.9) With [pin] the vault verifies it against its unlock key and arms recovery; a weak password
    /// is `weak_password` with its `reason` (§11.14.7), and a vault that already holds a credential answers `exists`.
    public func credentialCreate(password: String, pin: String? = nil) async throws {
        var fields: [(String, String)] = []
        if let pin { fields.append(("pin", pin)) }
        fields.append(("password", password))
        _ = try await credential.sealedOp("credential.create", fields)
    }

    /// The daily owner check (§3.6.1): the PIN and the credential password sealed together to one UTK, with the blob (a
    /// credential operation: the CEK rotates and the new blob is kept and acknowledged). [hold] `false` with an optional
    /// [holdOffUntil] (RFC 3339, at most 30 days ahead) turns the hold off (§3.6.7); `true` turns it on. Mirrors
    /// vettid-android `VaultApi.ownerCheck`.
    public func ownerCheck(pin: String, password: String, hold: Bool? = nil, holdOffUntil: String? = nil) async throws -> OwnerCheckPassed {
        var fields: [SealedField] = [.string("pin", pin), .string("password", password)]
        if let hold { fields.append(.bool("hold", hold)) }
        if let holdOffUntil { fields.append(.string("hold_off_until", holdOffUntil)) }
        return try VaultJSON.decode(OwnerCheckPassed.self, try await credential.credOp(Self.typeOwnerCheck, fields))
    }

    /// The owner check's message type (§3.6.1, §10.2; `vault.owner_check` before VAULT-MESSAGING 0.15.2). Settings keys,
    /// error codes, feed kinds and `owner_check` members keep their underscores.
    public static let typeOwnerCheck = "vault.owner-check"

    /// `credential.get`: the latest blob the vault holds, kept and acknowledged (the holder only).
    public func credentialFetch() async throws { try await credential.fetch() }

    /// `credential.version` (§10.6): whether the vault holds a credential, its version and key, and an open clone alarm.
    public func credentialVersion() async throws -> CredentialInfo {
        try VaultJSON.decode(CredentialInfo.self, try await device.op("credential.version"))
    }

    /// `credential.unlock`: opens the unlock window (§3.5.3) with the password (a credential operation); returns its
    /// `expires_at` ("" when the vault did not say).
    public func credentialUnlock(password: String) async throws -> String {
        let body = try await credential.credOp("credential.unlock", [.string("password", password)])
        return VaultJSON.string(VaultJSON.object(body), "expires_at") ?? ""
    }

    /// `vault.delete` (VAULT-MESSAGING §12.5) by the holder: the phrase `delete my vault` beside the blob, the PIN and the
    /// credential password sealed to one UTK, valid until [exp] (``requestExp()``; chosen, not in the spec: after it a
    /// copy waiting in a locked vault's mailbox never applies). The vault answers `{}` and then erases itself; nothing of
    /// the device is forgotten here (the caller erases VettID's data on the phone). A failure once the request may have
    /// gone out is ``RequestUnanswered``: the vault may be gone. Mirrors vettid-android `VaultApi.deleteVault` for a phone
    /// that holds the credential.
    public func deleteVault(pin: String, password: String, exp: Date) async throws {
        let options = CredOpOptions(outer: [("confirm", Self.deleteConfirmation)], unanswered: true, exp: exp)
        _ = try await credential.credOp(Self.typeVaultDelete, [.string("pin", pin), .string("password", password)], options)
    }

    public static let typeVaultDelete = "vault.delete"
    /// The phrase `vault.delete` carries (§12.5).
    public static let deleteConfirmation = "delete my vault"

    /// `credential.lock`: closes the unlock window.
    public func credentialLock() async throws { _ = try await device.op("credential.lock") }

    /// `credential.password.change` (§10.6): the current password and the new one, sealed with the blob. (Release R,
    /// §11.14.9) With [pin], which the vault verifies; the change closes the recovery generation and arms the next. Sent
    /// as [change] (its inner id and `exp`, stored before this call); no answer is ``ChangeUnanswered``, and
    /// `stale_credential` is not retried ("A lost answer").
    public func credentialChangePassword(
        password: String, newPassword: String, pin: String? = nil, change: ChangeRequest
    ) async throws {
        var fields: [SealedField] = []
        if let pin { fields.append(.string("pin", pin)) }
        fields.append(.string("password", password))
        fields.append(.string("new_password", newPassword))
        _ = try await credential.change(Self.typePasswordChange, fields, change)
    }

    /// One page of `item.list` (§10.7) filtered by [sensitivity], counted (the credential screen's critical items).
    public func itemCount(sensitivity: String, after: String? = nil, limit: Int? = nil) async throws -> ItemCountPage {
        let b = JsonBuilder().string("sensitivity", sensitivity)
        if let after { b.string("after", after) }
        if let limit { b.uint("limit", UInt64(limit)) }
        let o = try StrictJson.parseObject(try await device.op("item.list", body: b.bytes()))
        // The last page has no `next`, or `null`.
        let next: String? = if case .string(_, let n)? = o["next"] { n } else { nil }
        return ItemCountPage(count: try o.optArray("items")?.count ?? 0, next: next)
    }

    public func settingsGet() async throws -> VaultSettings {
        let o = try StrictJson.parseObject(try await device.op("settings.get"))
        let version = try o.optUint("version", min: 0, max: StrictJson.maxSafeInteger) ?? 0
        var values: [String: String] = [:]
        if let s = try o.optObj("settings") {
            for m in s.members { values[m.name] = m.value.raw }
        }
        return VaultSettings(version: version, values: values)
    }

    /// `settings.set` of [set] (key → exact JSON text) against [version]; returns the new version (`conflict` when the
    /// settings changed meanwhile).
    public func settingsSet(version: UInt64, set: [(key: String, json: String)]) async throws -> UInt64 {
        let values = JsonBuilder()
        for (k, v) in set { values.raw(k, v) }
        let body = JsonBuilder().uint("version", version).raw("set", values.build()).bytes()
        let o = try StrictJson.parseObject(try await device.op("settings.set", body: body))
        return try o.optUint("version", min: 0, max: StrictJson.maxSafeInteger) ?? 0
    }
}
