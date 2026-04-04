import Foundation

// MARK: - Migration Config

/// Configuration for a pending vault update.
struct MigrationConfig: Codable {
    let version: String
    let summary: String
    let detailsUrl: String?
    let publishedAt: String?
    let mandatoryAfter: String?

    /// Whether this update is now mandatory (past the mandatory deadline).
    var isMandatory: Bool {
        guard let mandatoryAfter = mandatoryAfter else { return false }
        guard let date = ISO8601DateFormatter().date(from: mandatoryAfter) else { return false }
        return Date() >= date
    }

    enum CodingKeys: String, CodingKey {
        case version
        case summary
        case detailsUrl = "details_url"
        case publishedAt = "published_at"
        case mandatoryAfter = "mandatory_after"
    }
}

// MARK: - Migration Status

enum MigrationStatus {
    case none
    case inProgress(progress: Double?)
    case complete(version: String)
    case emergencyRecoveryRequired
}
