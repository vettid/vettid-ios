import XCTest
@testable import VettID

/// Tests for NatsCredentials and related types
final class NatsCredentialsTests: XCTestCase {

    // MARK: - NatsCredentials Tests

    func testIsExpired_returnsTrueForPastDate() {
        let credentials = makeCredentials(expiresAt: Date().addingTimeInterval(-3600)) // 1 hour ago
        XCTAssertTrue(credentials.isExpired)
    }

    func testIsExpired_returnsFalseForFutureDate() {
        let credentials = makeCredentials(expiresAt: Date().addingTimeInterval(3600)) // 1 hour from now
        XCTAssertFalse(credentials.isExpired)
    }

    func testShouldRefresh_returnsTrueWhenLessThanOneHourRemaining() {
        let credentials = makeCredentials(expiresAt: Date().addingTimeInterval(1800)) // 30 minutes from now
        XCTAssertTrue(credentials.shouldRefresh)
    }

    func testShouldRefresh_returnsFalseWhenMoreThanOneHourRemaining() {
        let credentials = makeCredentials(expiresAt: Date().addingTimeInterval(7200)) // 2 hours from now
        XCTAssertFalse(credentials.shouldRefresh)
    }

    func testTimeUntilExpiration_returnsCorrectValue() {
        let expirationTime = Date().addingTimeInterval(3600)
        let credentials = makeCredentials(expiresAt: expirationTime)

        // Allow 1 second tolerance
        XCTAssertEqual(credentials.timeUntilExpiration, 3600, accuracy: 1)
    }

    func testEquality() {
        // Use a fixed date to ensure equality comparison works correctly
        let fixedDate = Date(timeIntervalSince1970: 1735689600) // 2025-01-01 00:00:00 UTC
        let credentials1 = makeCredentials(tokenId: "token1", expiresAt: fixedDate)
        let credentials2 = makeCredentials(tokenId: "token1", expiresAt: fixedDate)
        let credentials3 = makeCredentials(tokenId: "token2", expiresAt: fixedDate)

        XCTAssertEqual(credentials1, credentials2)
        XCTAssertNotEqual(credentials1, credentials3)
    }

    func testCodable() throws {
        let original = makeCredentials()

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NatsCredentials.self, from: data)

        XCTAssertEqual(original.tokenId, decoded.tokenId)
        XCTAssertEqual(original.jwt, decoded.jwt)
        XCTAssertEqual(original.seed, decoded.seed)
        XCTAssertEqual(original.endpoint, decoded.endpoint)
    }

    // MARK: - NatsPermissions Tests

    func testCanPublish_exactMatch() {
        let permissions = NatsPermissions(
            publish: ["OwnerSpace.test.forVault.status"],
            subscribe: []
        )

        XCTAssertTrue(permissions.canPublish(to: "OwnerSpace.test.forVault.status"))
        XCTAssertFalse(permissions.canPublish(to: "OwnerSpace.test.forVault.other"))
    }

    func testCanPublish_wildcardGt() {
        let permissions = NatsPermissions(
            publish: ["OwnerSpace.test.forVault.>"],
            subscribe: []
        )

        XCTAssertTrue(permissions.canPublish(to: "OwnerSpace.test.forVault.status"))
        XCTAssertTrue(permissions.canPublish(to: "OwnerSpace.test.forVault.commands.execute"))
        XCTAssertFalse(permissions.canPublish(to: "OwnerSpace.test.forApp.status"))
    }

    func testCanPublish_wildcardStar() {
        let permissions = NatsPermissions(
            publish: ["OwnerSpace.*.forVault.status"],
            subscribe: []
        )

        XCTAssertTrue(permissions.canPublish(to: "OwnerSpace.test.forVault.status"))
        XCTAssertTrue(permissions.canPublish(to: "OwnerSpace.other.forVault.status"))
        XCTAssertFalse(permissions.canPublish(to: "OwnerSpace.test.forApp.status"))
    }

    func testCanSubscribe_exactMatch() {
        let permissions = NatsPermissions(
            publish: [],
            subscribe: ["OwnerSpace.test.forApp.status"]
        )

        XCTAssertTrue(permissions.canSubscribe(to: "OwnerSpace.test.forApp.status"))
        XCTAssertFalse(permissions.canSubscribe(to: "OwnerSpace.test.forApp.other"))
    }

    func testCanSubscribe_wildcardGt() {
        let permissions = NatsPermissions(
            publish: [],
            subscribe: ["OwnerSpace.test.forApp.>"]
        )

        XCTAssertTrue(permissions.canSubscribe(to: "OwnerSpace.test.forApp.status"))
        XCTAssertTrue(permissions.canSubscribe(to: "OwnerSpace.test.forApp.events.new"))
        XCTAssertFalse(permissions.canSubscribe(to: "OwnerSpace.test.forVault.status"))
    }

    // MARK: - NatsTokenResponse Tests

    func testNatsTokenResponseDecoding() throws {
        let json = """
        {
            "token_id": "nats_abc123",
            "nats_jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "nats_seed": "SUAM1234567890",
            "nats_endpoint": "nats://nats.vettid.dev:4222",
            "expires_at": "2025-12-08T12:00:00Z",
            "permissions": {
                "publish": ["OwnerSpace.guid.forVault.>"],
                "subscribe": ["OwnerSpace.guid.forApp.>"]
            }
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(NatsTokenResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.tokenId, "nats_abc123")
        XCTAssertEqual(response.natsJwt, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        XCTAssertEqual(response.natsSeed, "SUAM1234567890")
        XCTAssertEqual(response.natsEndpoint, "nats://nats.vettid.dev:4222")
        XCTAssertEqual(response.permissions.publish.count, 1)
        XCTAssertEqual(response.permissions.subscribe.count, 1)
    }

    func testCredentialsFromResponse() throws {
        let json = """
        {
            "token_id": "nats_abc123",
            "nats_jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "nats_seed": "SUAM1234567890",
            "nats_endpoint": "nats://nats.vettid.dev:4222",
            "expires_at": "2025-12-08T12:00:00Z",
            "permissions": {
                "publish": ["OwnerSpace.guid.forVault.>"],
                "subscribe": ["OwnerSpace.guid.forApp.>"]
            }
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(NatsTokenResponse.self, from: json.data(using: .utf8)!)
        let credentials = NatsCredentials(from: response)

        XCTAssertEqual(credentials.tokenId, "nats_abc123")
        XCTAssertEqual(credentials.jwt, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        XCTAssertEqual(credentials.seed, "SUAM1234567890")
        XCTAssertEqual(credentials.endpoint, "nats://nats.vettid.dev:4222")
    }

    // MARK: - NatsAccountResponse Tests

    func testNatsAccountResponseDecoding() throws {
        let json = """
        {
            "owner_space_id": "OwnerSpace.user-guid-123",
            "message_space_id": "MessageSpace.user-guid-123",
            "nats_endpoint": "nats://nats.vettid.dev:4222",
            "status": "active"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(NatsAccountResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.ownerSpaceId, "OwnerSpace.user-guid-123")
        XCTAssertEqual(response.messageSpaceId, "MessageSpace.user-guid-123")
        XCTAssertEqual(response.status, "active")
    }

    // MARK: - NatsStatusResponse Tests

    func testNatsStatusResponseDecoding_withAccount() throws {
        let json = """
        {
            "has_account": true,
            "account": {
                "owner_space_id": "OwnerSpace.user-guid-123",
                "message_space_id": "MessageSpace.user-guid-123",
                "status": "active",
                "created_at": "2025-12-07T12:00:00Z"
            },
            "active_tokens": [
                {
                    "token_id": "token1",
                    "client_type": "app",
                    "device_id": "device123",
                    "expires_at": "2025-12-08T12:00:00Z",
                    "status": "active"
                }
            ],
            "nats_endpoint": "nats://nats.vettid.dev:4222"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(NatsStatusResponse.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(response.hasAccount)
        XCTAssertNotNil(response.account)
        XCTAssertEqual(response.account?.ownerSpaceId, "OwnerSpace.user-guid-123")
        XCTAssertEqual(response.activeTokens.count, 1)
        XCTAssertEqual(response.activeTokens.first?.tokenId, "token1")
    }

    func testNatsStatusResponseDecoding_withoutAccount() throws {
        let json = """
        {
            "has_account": false,
            "account": null,
            "active_tokens": [],
            "nats_endpoint": "nats://nats.vettid.dev:4222"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(NatsStatusResponse.self, from: json.data(using: .utf8)!)

        XCTAssertFalse(response.hasAccount)
        XCTAssertNil(response.account)
        XCTAssertTrue(response.activeTokens.isEmpty)
    }

    // MARK: - NatsTokenRequest Tests

    func testNatsTokenRequestEncoding_app() throws {
        let request = NatsTokenRequest.app(deviceId: "device123")

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["client_type"] as? String, "app")
        XCTAssertEqual(json["device_id"] as? String, "device123")
    }

    func testNatsTokenRequestEncoding_vault() throws {
        let request = NatsTokenRequest.vault()

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["client_type"] as? String, "vault")
    }

    // MARK: - Helpers

    private func makeCredentials(
        tokenId: String = "test-token-id",
        jwt: String = "test-jwt",
        seed: String = "test-seed",
        endpoint: String = "nats://localhost:4222",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) -> NatsCredentials {
        NatsCredentials(
            tokenId: tokenId,
            jwt: jwt,
            seed: seed,
            endpoint: endpoint,
            expiresAt: expiresAt,
            permissions: NatsPermissions(
                publish: ["OwnerSpace.test.forVault.>"],
                subscribe: ["OwnerSpace.test.forApp.>"]
            )
        )
    }
}
