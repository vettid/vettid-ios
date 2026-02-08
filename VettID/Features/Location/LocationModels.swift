import Foundation

// MARK: - Location History Entry

struct LocationHistoryEntry: Identifiable, Codable {
    let id: String
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let altitude: Double?
    let speed: Float?
    let timestamp: TimeInterval // epoch seconds
    let source: String // "gps", "network", etc.
    let isSummary: Bool

    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case latitude
        case longitude
        case accuracy
        case altitude
        case speed
        case timestamp
        case source
        case isSummary = "is_summary"
    }

    init(id: String = UUID().uuidString, latitude: Double, longitude: Double,
         accuracy: Float? = nil, altitude: Double? = nil, speed: Float? = nil,
         timestamp: TimeInterval, source: String, isSummary: Bool = false) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.speed = speed
        self.timestamp = timestamp
        self.source = source
        self.isSummary = isSummary
    }
}

// MARK: - Shared Location Update (from peer)

struct SharedLocationUpdate: Codable {
    let connectionId: String
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let timestamp: TimeInterval
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case latitude
        case longitude
        case accuracy
        case timestamp
        case updatedAt = "updated_at"
    }
}

// MARK: - Location List Request

struct LocationListRequest: Encodable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case limit
    }
}

// MARK: - Location List Response

struct LocationListResponse: Decodable {
    let points: [LocationHistoryEntry]
}

// MARK: - Location Add Request

struct LocationAddRequest: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let altitude: Double?
    let speed: Float?
    let timestamp: TimeInterval
    let source: String
}

// MARK: - Time Filter

enum LocationTimeFilter: String, CaseIterable {
    case today
    case lastWeek = "last_week"
    case lastMonth = "last_month"
    case all

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .lastWeek: return "Last 7 Days"
        case .lastMonth: return "Last 30 Days"
        case .all: return "All"
        }
    }

    var startDate: Date {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.startOfDay(for: Date())
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .lastMonth:
            return calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        case .all:
            return Date.distantPast
        }
    }
}

// MARK: - Shared Location Entry (for UI)

struct SharedLocationEntry: Identifiable {
    let connectionId: String
    let peerName: String
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let timestamp: TimeInterval
    let isStale: Bool // > 1 hour old

    var id: String { connectionId }

    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}
