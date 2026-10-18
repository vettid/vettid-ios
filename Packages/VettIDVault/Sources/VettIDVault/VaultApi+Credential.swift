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

// The credential calls of enrollment (§3.5.5, §3.5.7, §10.6) and the settings (§10.8).
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
