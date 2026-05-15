import Foundation

// MARK: - Secrets Client

/// Wire-layer client for the vault's two-tier secrets API.
///
/// **Minor secrets** (the catalog-visible tier) use the `secret.*` verb
/// family — values are cataloged metadata + cleartext payloads that the
/// vault stores under the user's DEK. **Critical secrets** (e.g. wallet
/// seeds, identity keys) use the `credential.secret.*` family — the value
/// is held in the credential blob itself, and reveal requires a password-
/// gated round-trip.
///
/// All calls route through `OwnerSpaceClient.sendAndAwaitResponse` to pick
/// up the `timestamp_ms` + `nonce` replay headers; the `credential.secret.*`
/// writes additionally include the `encrypted_credential` blob (Phase D)
/// so the vault decrypts in-flight rather than reading vaultState.
///
/// Vault verbs:
/// - Minor:    `secret.list`, `secret.get`, `secret.add`, `secret.update`,
///             `secret.delete`, `secret.set-visibility`
/// - Critical: `credential.secret.list`, `credential.secret.get`,
///             `credential.secret.add`, `credential.secret.delete`,
///             `credential.secret.set-discoverability`
///
/// Mirrors Android `MinorSecretsStore` + `CriticalSecretMetadataStore` +
/// the per-screen `credential.secret.*` calls in `CriticalSecretsViewModel`
/// and `TwoTierSecretsViewModel`.
final class SecretsClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let credentialStore: ProteanCredentialStore
    private let defaultTimeout: TimeInterval = 10

    init(ownerSpaceClient: OwnerSpaceClient,
         credentialStore: ProteanCredentialStore = ProteanCredentialStore()) {
        self.ownerSpaceClient = ownerSpaceClient
        self.credentialStore = credentialStore
    }

    // MARK: - Minor secrets (catalog-visible tier)

    /// `secret.list` — metadata only; values come on demand via `getMinor`.
    func listMinor() async throws -> [[String: Any]] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.list",
            payload: [:],
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        return (response.result?["secrets"] as? [[String: Any]]) ?? []
    }

    /// `secret.get` — fetch a minor secret's value by id.
    func getMinor(id: String) async throws -> String? {
        let payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.get",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        return response.result?["value"] as? String
    }

    /// `secret.add` — create a minor secret. `fields` carries template
    /// values for multi-field templates (credit card etc.); pass nil for
    /// single-value secrets and set `value` instead.
    func addMinor(
        category: String,
        label: String,
        alias: String?,
        value: String?,
        fields: [String: String]?,
        visibility: SecretVisibility
    ) async throws -> String {
        var payload: [String: AnyCodableValue] = [
            "category": AnyCodableValue(category),
            "label": AnyCodableValue(label),
            "visibility": AnyCodableValue(visibility.wireValue)
        ]
        if let alias = alias { payload["alias"] = AnyCodableValue(alias) }
        if let value = value { payload["value"] = AnyCodableValue(value) }
        if let fields = fields {
            payload["fields"] = AnyCodableValue(fields.mapValues { $0 as Any })
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.add",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        guard let id = response.result?["id"] as? String else {
            throw SecretsClientError.invalidResponse("secret.add returned no id")
        }
        return id
    }

    /// `secret.update` — per-record overwrite. Pass only fields that
    /// changed; vault leaves omitted fields alone.
    func updateMinor(
        id: String,
        label: String? = nil,
        alias: String? = nil,
        value: String? = nil,
        fields: [String: String]? = nil
    ) async throws {
        var payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id)
        ]
        if let label = label { payload["label"] = AnyCodableValue(label) }
        if let alias = alias { payload["alias"] = AnyCodableValue(alias) }
        if let value = value { payload["value"] = AnyCodableValue(value) }
        if let fields = fields {
            payload["fields"] = AnyCodableValue(fields.mapValues { $0 as Any })
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.update",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// `secret.delete`.
    func deleteMinor(id: String) async throws {
        let payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.delete",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// `secret.set-visibility` — flip a minor secret between PROFILE /
    /// CATALOG / USE_ONLY / PRIVATE.
    func setMinorVisibility(id: String, visibility: SecretVisibility) async throws {
        let payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id),
            "visibility": AnyCodableValue(visibility.wireValue)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "secret.set-visibility",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
    }

    // MARK: - Critical secrets (credential-blob tier)

    /// `credential.secret.list` — metadata for the secrets stored inside
    /// the credential blob (e.g. wallet seeds). No values returned.
    /// Includes `encrypted_credential` (Phase D) so the vault can decrypt
    /// in-flight.
    func listCritical() async throws -> [[String: Any]] {
        var payload: [String: AnyCodableValue] = [:]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "credential.secret.list",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        return (response.result?["secrets"] as? [[String: Any]]) ?? []
    }

    /// `credential.secret.get` — password-gated reveal. Caller supplies
    /// an `EncryptedPasswordPayload` produced by the password-encryption
    /// helper; the vault verifies the password by decrypting in-flight
    /// rather than reading vaultState (Phase D).
    func getCritical(
        id: String,
        encryptedPasswordHash: String,
        ephemeralPublicKey: String,
        nonce: String,
        salt: String
    ) async throws -> String {
        var payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id),
            "encrypted_password_hash": AnyCodableValue(encryptedPasswordHash),
            "ephemeral_public_key": AnyCodableValue(ephemeralPublicKey),
            "nonce": AnyCodableValue(nonce),
            "salt": AnyCodableValue(salt)
        ]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "credential.secret.get",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        guard let value = response.result?["value"] as? String else {
            throw SecretsClientError.invalidResponse("credential.secret.get returned no value")
        }
        return value
    }

    /// `credential.secret.add` — create a critical secret. The value is
    /// encrypted under a UTK before transit. Includes the encrypted
    /// credential blob for Phase-D in-flight decryption.
    func addCritical(
        category: String,
        label: String,
        encryptedValue: String,
        utkId: String,
        ephemeralPublicKey: String,
        nonce: String
    ) async throws -> String {
        var payload: [String: AnyCodableValue] = [
            "category": AnyCodableValue(category),
            "label": AnyCodableValue(label),
            "encrypted_value": AnyCodableValue(encryptedValue),
            "utk_id": AnyCodableValue(utkId),
            "ephemeral_public_key": AnyCodableValue(ephemeralPublicKey),
            "nonce": AnyCodableValue(nonce)
        ]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "credential.secret.add",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        guard let id = response.result?["id"] as? String else {
            throw SecretsClientError.invalidResponse("credential.secret.add returned no id")
        }
        return id
    }

    /// `credential.secret.delete` — remove a critical secret. The vault
    /// returns a fresh credential blob; caller must store it.
    func deleteCritical(id: String) async throws -> String? {
        var payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id)
        ]
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "credential.secret.delete",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
        return response.result?["encrypted_credential"] as? String
    }

    /// `credential.secret.set-discoverability` — visibility flag on a
    /// critical secret. Vault clamps the legal values per security policy.
    func setCriticalDiscoverability(id: String, visibility: SecretVisibility) async throws {
        let payload: [String: AnyCodableValue] = [
            "id": AnyCodableValue(id),
            "discoverability": AnyCodableValue(visibility.wireValue)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "credential.secret.set-discoverability",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw SecretsClientError.vaultError(response.error ?? "unknown")
        }
    }
}

// MARK: - Supporting Types

/// Visibility tier for secrets. Matches Android `FieldVisibility` and the
/// vault's `discoverability` field on critical secrets.
enum SecretVisibility: String {
    /// Visible in the user's published profile (peers see the value).
    case profile
    /// Listed in the data catalog so peers know it exists (no value).
    case catalog
    /// Cataloged-for-use: peers can request an *operation* (sign / decrypt /
    /// auth) but never receive the value itself. Maps to the vault's
    /// `cataloged-for-use` discoverability.
    case useOnly
    /// Hidden — neither value nor existence is exposed to peers.
    case `private`

    /// On-wire form expected by the vault.
    var wireValue: String {
        switch self {
        case .profile:   return "PROFILE"
        case .catalog:   return "CATALOG"
        case .useOnly:   return "USE_ONLY"
        case .`private`: return "PRIVATE"
        }
    }
}

// MARK: - Errors

enum SecretsClientError: LocalizedError {
    case vaultError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Secrets vault error: \(msg)"
        case .invalidResponse(let detail): return "Invalid secrets response: \(detail)"
        }
    }
}
