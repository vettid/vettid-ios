import Foundation

// MARK: - Personal Data Client

/// Wire-layer client for the vault's personal-data verbs — the catalog of
/// optional + custom fields that live outside the registration profile.
///
/// All calls route through `OwnerSpaceClient.sendAndAwaitResponse`, which
/// stamps `timestamp_ms` + a fresh `nonce` on every envelope, so byte-stable
/// reads like `personal-data.get` aren't dropped by the parent's replay
/// cache. Mirrors the Android `PersonalDataStore.hydrate()` call set so the
/// iOS hydrate path in Phase 0.10 can lean on the same surface.
///
/// Vault verbs:
/// - `personal-data.get`                  — full fields object
/// - `personal-data.get-sort-order`       — namespace → sort index
/// - `personal-data.update`               — push field updates
/// - `personal-data.update-sort-order`    — push sort-order map
/// - `personal-data.delete-field`         — remove a single field
final class PersonalDataClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 15

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Reads

    /// Fetch the full `fields` object — each entry keyed by dotted
    /// namespace (`personal.legal.first_name`, `contact.phone.mobile`, …)
    /// with a `{ value, is_public, ... }` shape. Returned as the raw
    /// dictionary so the cache layer can decode without an extra DTO
    /// pass.
    func getPersonalData() async throws -> [String: Any] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.get",
            payload: [:],
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
        return (response.result?["fields"] as? [String: Any]) ?? [:]
    }

    /// Fetch the sort-order map: namespace → integer index. Falls back to
    /// an empty map if the vault has no sort order recorded.
    func getSortOrder() async throws -> [String: Int] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.get-sort-order",
            payload: [:],
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
        let raw = (response.result?["sort_order"] as? [String: Any]) ?? [:]
        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let i = v as? Int { out[k] = i }
            else if let n = v as? NSNumber { out[k] = n.intValue }
        }
        return out
    }

    // MARK: - Writes

    /// Push a field-namespace → value map (`exportFieldsMapForPersonalData`
    /// on Android). Vault overwrites named fields and leaves the rest
    /// alone; pass `nil` values via `deleteField(namespace:)` instead.
    func updatePersonalData(fields: [String: String]) async throws {
        let payload: [String: AnyCodableValue] = [
            "fields": AnyCodableValue(fields.mapValues { $0 as Any })
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.update",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// Push a new sort-order map.
    func updateSortOrder(_ order: [String: Int]) async throws {
        let payload: [String: AnyCodableValue] = [
            "sort_order": AnyCodableValue(order.mapValues { $0 as Any })
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.update-sort-order",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// Delete a single field by dotted namespace.
    func deleteField(namespace: String) async throws {
        let payload: [String: AnyCodableValue] = [
            "namespace": AnyCodableValue(namespace)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.delete-field",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// Set whether a single field appears in the public profile (the
    /// catalog peers see). Vault is authoritative; the cache mirrors the
    /// result via `forApp.profile.public`.
    func setFieldPublicVisibility(namespace: String, isPublic: Bool) async throws {
        let payload: [String: AnyCodableValue] = [
            "namespace": AnyCodableValue(namespace),
            "is_public": AnyCodableValue(isPublic)
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.set-visibility",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// Flip a set of fields' "hide from catalog" (Discoverability=Private)
    /// flag. Vault persists the set; passing an empty set clears it.
    func setHiddenFromCatalog(namespaces: Set<String>) async throws {
        let payload: [String: AnyCodableValue] = [
            "namespaces": AnyCodableValue(Array(namespaces))
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "personal-data.set-hidden-from-catalog",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw PersonalDataClientError.vaultError(response.error ?? "unknown")
        }
    }
}

// MARK: - Errors

enum PersonalDataClientError: LocalizedError {
    case vaultError(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Personal-data vault error: \(msg)"
        }
    }
}
