import Foundation

/// Handler for vault profile operations via NATS
///
/// Manages the user's profile data stored in the vault and
/// broadcasts profile updates to connections.
///
/// NATS Topics:
/// - `profile.get` - Retrieve current profile
/// - `profile.update` - Update profile fields
/// - `profile.delete` - Delete specific fields
/// - `profile.broadcast` - Broadcast profile to connections
actor ProfileHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Profile Operations

    /// Get the current profile from vault
    /// - Returns: Dictionary of profile fields
    func getProfile() async throws -> [String: String] {
        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "profile.get",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ProfileHandlerError.getFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            return [:]
        }

        // Convert result to [String: String]
        var profile: [String: String] = [:]
        for (key, value) in result {
            if let stringValue = value.value as? String {
                profile[key] = stringValue
            }
        }

        return profile
    }

    /// Update profile fields
    /// - Parameter fields: Fields to update
    /// - Returns: Response indicating success/failure
    func updateProfile(fields: [String: String]) async throws -> VaultEventResponse {
        let payload = fields.mapValues { AnyCodableValue($0) }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "profile.update",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Delete specific profile fields
    /// - Parameter keys: Field keys to delete
    /// - Returns: Response indicating success/failure
    func deleteFields(keys: [String]) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "keys": AnyCodableValue(keys)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "profile.delete",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Broadcast profile to all connections
    /// - Parameter fields: Optional specific fields to broadcast (nil = all)
    /// - Returns: Response indicating success/failure
    func broadcastProfile(fields: [String]? = nil) async throws -> VaultEventResponse {
        var payload: [String: AnyCodableValue] = [:]

        if let fields = fields {
            payload["fields"] = AnyCodableValue(fields)
        }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "profile.broadcast",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Update a single profile field
    /// - Parameters:
    ///   - key: Field name
    ///   - value: Field value
    /// - Returns: Response indicating success/failure
    func updateField(key: String, value: String) async throws -> VaultEventResponse {
        return try await updateProfile(fields: [key: value])
    }

    /// Get a specific profile field
    /// - Parameter key: Field name
    /// - Returns: Field value or nil if not found
    func getField(key: String) async throws -> String? {
        let profile = try await getProfile()
        return profile[key]
    }
}

// MARK: - Profile Field Constants

/// Standard profile field keys
enum ProfileField: String, CaseIterable {
    case displayName = "display_name"
    case bio = "bio"
    case location = "location"
    case email = "email"
    case phone = "phone"
    case website = "website"
    case avatarUrl = "avatar_url"
    case publicKey = "public_key"

    var displayLabel: String {
        switch self {
        case .displayName: return "Display Name"
        case .bio: return "Bio"
        case .location: return "Location"
        case .email: return "Email"
        case .phone: return "Phone"
        case .website: return "Website"
        case .avatarUrl: return "Avatar"
        case .publicKey: return "Public Key"
        }
    }

    /// Fields that are safe to share publicly
    static var publicFields: [ProfileField] {
        [.displayName, .bio, .location, .avatarUrl]
    }

    /// Fields that require explicit consent to share
    static var privateFields: [ProfileField] {
        [.email, .phone, .website]
    }
}

// MARK: - Errors

enum ProfileHandlerError: LocalizedError {
    case getFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    case broadcastFailed(String)

    var errorDescription: String? {
        switch self {
        case .getFailed(let reason):
            return "Failed to get profile: \(reason)"
        case .updateFailed(let reason):
            return "Failed to update profile: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete profile fields: \(reason)"
        case .broadcastFailed(let reason):
            return "Failed to broadcast profile: \(reason)"
        }
    }
}
