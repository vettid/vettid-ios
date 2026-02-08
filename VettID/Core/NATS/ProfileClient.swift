import Foundation

// MARK: - Profile Client

/// Client for managing profile data via NATS vault communication
/// Uses OwnerSpaceClient request/response pattern for reliable delivery
final class ProfileClient {

    private let ownerSpaceClient: OwnerSpaceClient

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Get Registration Profile

    /// Fetch the registration profile (system fields) from the vault
    /// Topic: {ownerSpace}.forVault.profile.get
    /// Response: {ownerSpace}.forApp.profile.get.response
    func getRegistrationProfile() async throws -> RegistrationProfile {
        let request = ProfileGetRequest()
        return try await ownerSpaceClient.request(
            request,
            topic: "profile.get",
            responseType: RegistrationProfile.self,
            timeout: 30
        )
    }

    // MARK: - Sync Profile

    /// Push profile updates to the vault
    /// Topic: {ownerSpace}.forVault.profile.update
    /// Response: {ownerSpace}.forApp.profile.update.response
    func syncProfile(fields: ProfileSyncFields) async throws {
        let _: ProfileSyncResponse = try await ownerSpaceClient.request(
            fields,
            topic: "profile.update",
            responseType: ProfileSyncResponse.self,
            timeout: 30
        )
    }

    // MARK: - Sync Photo

    /// Upload profile photo to the vault (base64 encoded)
    func syncPhoto(base64Data: String) async throws {
        let request = ProfilePhotoRequest(photoData: base64Data)
        let _: ProfileSyncResponse = try await ownerSpaceClient.request(
            request,
            topic: "profile.photo.update",
            responseType: ProfileSyncResponse.self,
            timeout: 30
        )
    }
}

// MARK: - Request Types

struct ProfileGetRequest: Encodable {
    let action = "get"
}

struct ProfileSyncFields: Encodable {
    var displayName: String?
    var bio: String?
    var location: String?
    var email: String?
    var photoData: String? // base64

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case bio
        case location
        case email
        case photoData = "photo_data"
    }
}

struct ProfilePhotoRequest: Encodable {
    let photoData: String

    enum CodingKeys: String, CodingKey {
        case photoData = "photo_data"
    }
}

// MARK: - Response Types

struct RegistrationProfile: Decodable {
    let firstName: String
    let lastName: String
    let email: String

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email
    }
}

struct ProfileSyncResponse: Decodable {
    let success: Bool
    let message: String?
}
