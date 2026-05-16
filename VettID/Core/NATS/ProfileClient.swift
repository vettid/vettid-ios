import Foundation

// MARK: - Profile Client

/// Client for profile / categories operations via NATS.
///
/// All calls go through `OwnerSpaceClient.sendAndAwaitResponse`, which uses
/// JetStream request-response with `event_id` correlation and stamps
/// `timestamp_ms` + a fresh `nonce` on every envelope so routine read polls
/// don't trip the parent's replay-detection cache.
///
/// Vault verbs spoken here (parity with Android `ProfileClient` +
/// `PersonalDataStore.hydrate()`):
/// - `profile.get`              — full canonical profile
/// - `profile.get-published`    — what peers can see (the catalog)
/// - `profile.categories.get`   — predefined + custom categories
/// - `profile.update`           — push field updates
/// - `profile.photo.update`     — push profile photo
final class ProfileClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 30

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Reads

    /// Fetch the registration profile (system fields: first_name, last_name,
    /// email). Backed by `profile.get-published`, which returns the system
    /// fields at the top level of the response. Used by the welcome screen
    /// and as a sanity check after warm-up.
    func getRegistrationProfile() async throws -> RegistrationProfile {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.get-published",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }
        guard let result = response.result else {
            throw ProfileClientError.invalidResponse("no result")
        }

        // Accept either snake_case or camelCase, matching Android tolerance.
        let first = (result["first_name"] as? String) ?? (result["firstName"] as? String) ?? ""
        let last = (result["last_name"] as? String) ?? (result["lastName"] as? String) ?? ""
        let email = (result["email"] as? String) ?? ""
        return RegistrationProfile(firstName: first, lastName: last, email: email)
    }

    /// Fetch the full canonical profile from the vault (`profile.get`).
    /// Returns the raw result dictionary so callers can pull whatever
    /// fields they need (`public_fields`, `field_order`, custom categories
    /// metadata, etc.) without us re-typing every shape here.
    func getProfile() async throws -> [String: Any] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.get",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }
        return response.result ?? [:]
    }

    /// Fetch the **published** profile — the catalog peers can see. This is
    /// the spine of `PersonalDataStore.hydrate()`: system fields,
    /// `public_profile_fields`, `public_fields`, `field_order`, inline
    /// `photo`, and the published view of categories.
    func getPublishedProfile() async throws -> [String: Any] {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.get-published",
            payload: [:],
            timeout: defaultTimeout
        )
        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }
        return response.result ?? [:]
    }

    /// Fetch predefined + user-defined custom categories
    /// (`profile.categories.get`). Returned as raw arrays so the cache
    /// layer can decode them into platform types without an extra DTO.
    func getCategories() async throws -> CategoryList {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.categories.get",
            payload: [:],
            timeout: defaultTimeout
        )
        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }

        let predefined = (response.result?["predefined"] as? [[String: Any]]) ?? []
        let custom = (response.result?["custom"] as? [[String: Any]]) ?? []
        return CategoryList(
            predefined: predefined.compactMap(CategoryInfo.from(dict:)),
            custom: custom.compactMap(CategoryInfo.from(dict:))
        )
    }

    // MARK: - Writes

    /// Push profile field updates. `fields` keys are dotted namespaces
    /// (`personal.legal.first_name`, `contact.phone.mobile`, …) matching
    /// `PersonalDataStore.exportFieldsMapForProfileUpdate()`.
    func updateProfile(fields: [String: String]) async throws {
        let payload: [String: AnyCodableValue] = [
            "data": AnyCodableValue(fields.mapValues { $0 as Any })
        ]
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.update",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }
    }

    /// Upload (or clear) the profile photo. Pass `nil` to remove.
    func syncPhoto(base64Data: String?) async throws {
        var payload: [String: AnyCodableValue] = [:]
        if let data = base64Data {
            payload["photo_data"] = AnyCodableValue(data)
        } else {
            payload["clear"] = AnyCodableValue(true)
        }
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            "profile.photo.update",
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success else {
            throw ProfileClientError.vaultError(response.error ?? "unknown")
        }
    }
}

// MARK: - Response Types

struct RegistrationProfile {
    let firstName: String
    let lastName: String
    let email: String
}

struct CategoryInfo: Equatable {
    let id: String
    let name: String
    let icon: String?

    static func from(dict: [String: Any]) -> CategoryInfo? {
        guard let id = dict["id"] as? String else { return nil }
        return CategoryInfo(
            id: id,
            name: dict["name"] as? String ?? "",
            icon: dict["icon"] as? String
        )
    }
}

struct CategoryList {
    let predefined: [CategoryInfo]
    let custom: [CategoryInfo]
    var all: [CategoryInfo] { predefined + custom }
}

// MARK: - Errors

enum ProfileClientError: LocalizedError {
    case vaultError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Profile vault error: \(msg)"
        case .invalidResponse(let detail): return "Invalid profile response: \(detail)"
        }
    }
}
