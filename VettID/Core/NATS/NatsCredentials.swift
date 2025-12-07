import Foundation

/// NATS connection credentials including JWT and NKey seed
struct NatsCredentials: Codable, Equatable {
    let tokenId: String
    let jwt: String
    let seed: String
    let endpoint: String
    let expiresAt: Date
    let permissions: NatsPermissions

    /// Whether the credentials have expired
    var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Whether credentials should be refreshed (less than 1 hour remaining)
    var shouldRefresh: Bool {
        Date().addingTimeInterval(3600) >= expiresAt
    }

    /// Time remaining until expiration
    var timeUntilExpiration: TimeInterval {
        expiresAt.timeIntervalSince(Date())
    }

    /// Create credentials from API response
    init(from response: NatsTokenResponse) {
        self.tokenId = response.tokenId
        self.jwt = response.natsJwt
        self.seed = response.natsSeed
        self.endpoint = response.natsEndpoint
        self.expiresAt = ISO8601DateFormatter().date(from: response.expiresAt) ?? Date()
        self.permissions = NatsPermissions(
            publish: response.permissions.publish,
            subscribe: response.permissions.subscribe
        )
    }

    /// Create credentials directly
    init(
        tokenId: String,
        jwt: String,
        seed: String,
        endpoint: String,
        expiresAt: Date,
        permissions: NatsPermissions
    ) {
        self.tokenId = tokenId
        self.jwt = jwt
        self.seed = seed
        self.endpoint = endpoint
        self.expiresAt = expiresAt
        self.permissions = permissions
    }
}

/// NATS topic permissions
struct NatsPermissions: Codable, Equatable {
    let publish: [String]
    let subscribe: [String]

    /// Check if publishing to a topic is allowed
    func canPublish(to topic: String) -> Bool {
        permissions(publish, allowTopic: topic)
    }

    /// Check if subscribing to a topic is allowed
    func canSubscribe(to topic: String) -> Bool {
        permissions(subscribe, allowTopic: topic)
    }

    private func permissions(_ patterns: [String], allowTopic topic: String) -> Bool {
        for pattern in patterns {
            if matchesPattern(pattern, topic: topic) {
                return true
            }
        }
        return false
    }

    private func matchesPattern(_ pattern: String, topic: String) -> Bool {
        // Handle NATS wildcard patterns
        // > matches any number of tokens
        // * matches a single token
        if pattern == ">" {
            return true
        }

        let patternParts = pattern.split(separator: ".")
        let topicParts = topic.split(separator: ".")

        var patternIndex = 0
        var topicIndex = 0

        while patternIndex < patternParts.count && topicIndex < topicParts.count {
            let patternPart = String(patternParts[patternIndex])

            if patternPart == ">" {
                // > matches rest of topic
                return true
            } else if patternPart == "*" {
                // * matches single token
                patternIndex += 1
                topicIndex += 1
            } else if patternPart == String(topicParts[topicIndex]) {
                // Exact match
                patternIndex += 1
                topicIndex += 1
            } else {
                return false
            }
        }

        // Check if we consumed both pattern and topic
        if patternIndex < patternParts.count {
            // Remaining pattern must be > to match
            return String(patternParts[patternIndex]) == ">"
        }

        return topicIndex == topicParts.count
    }
}

// MARK: - API Response Types

/// Response from POST /vault/nats/token
struct NatsTokenResponse: Codable {
    let tokenId: String
    let natsJwt: String
    let natsSeed: String
    let natsEndpoint: String
    let expiresAt: String
    let permissions: NatsTokenPermissions

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case natsJwt = "nats_jwt"
        case natsSeed = "nats_seed"
        case natsEndpoint = "nats_endpoint"
        case expiresAt = "expires_at"
        case permissions
    }
}

struct NatsTokenPermissions: Codable {
    let publish: [String]
    let subscribe: [String]
}

/// Response from POST /vault/nats/account
struct NatsAccountResponse: Codable {
    let ownerSpaceId: String
    let messageSpaceId: String
    let natsEndpoint: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case ownerSpaceId = "owner_space_id"
        case messageSpaceId = "message_space_id"
        case natsEndpoint = "nats_endpoint"
        case status
    }
}

/// Response from GET /vault/nats/status
struct NatsStatusResponse: Codable {
    let hasAccount: Bool
    let account: NatsAccountInfo?
    let activeTokens: [NatsActiveToken]
    let natsEndpoint: String

    enum CodingKeys: String, CodingKey {
        case hasAccount = "has_account"
        case account
        case activeTokens = "active_tokens"
        case natsEndpoint = "nats_endpoint"
    }
}

struct NatsAccountInfo: Codable {
    let ownerSpaceId: String
    let messageSpaceId: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case ownerSpaceId = "owner_space_id"
        case messageSpaceId = "message_space_id"
        case status
        case createdAt = "created_at"
    }
}

struct NatsActiveToken: Codable {
    let tokenId: String
    let clientType: String
    let deviceId: String?
    let expiresAt: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case clientType = "client_type"
        case deviceId = "device_id"
        case expiresAt = "expires_at"
        case status
    }
}

// MARK: - Request Types

/// Request body for POST /vault/nats/token
struct NatsTokenRequest: Codable {
    let clientType: String
    let deviceId: String?

    enum CodingKeys: String, CodingKey {
        case clientType = "client_type"
        case deviceId = "device_id"
    }

    static func app(deviceId: String? = nil) -> NatsTokenRequest {
        NatsTokenRequest(clientType: "app", deviceId: deviceId)
    }

    static func vault(deviceId: String? = nil) -> NatsTokenRequest {
        NatsTokenRequest(clientType: "vault", deviceId: deviceId)
    }
}
