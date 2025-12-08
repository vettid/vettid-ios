import Foundation

/// User profile information
struct Profile: Codable, Equatable {
    let guid: String
    var displayName: String
    var avatarUrl: String?
    var bio: String?
    var location: String?
    let lastUpdated: Date
}

/// Request to update profile
struct UpdateProfileRequest: Encodable {
    let displayName: String
    let bio: String?
    let location: String?
}

/// Response when getting profile
struct ProfileResponse: Decodable {
    let profile: Profile
}

/// Avatar upload response
struct AvatarUploadResponse: Decodable {
    let avatarUrl: String
}
