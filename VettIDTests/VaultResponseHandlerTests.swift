import XCTest
@testable import VettID

/// Tests for VaultResponseHandler and related types
final class VaultResponseHandlerTests: XCTestCase {

    // MARK: - VaultResponseError Tests

    func testVaultResponseError_timeoutDescription() {
        let error = VaultResponseError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("timed out"))
    }

    func testVaultResponseError_cancelledDescription() {
        let error = VaultResponseError.cancelled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("cancelled"))
    }

    func testVaultResponseError_handlerStoppedDescription() {
        let error = VaultResponseError.handlerStopped
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("stopped"))
    }

    func testVaultResponseError_eventSubmissionFailedDescription() {
        let error = VaultResponseError.eventSubmissionFailed("network error")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("network error"))
    }

    func testVaultResponseError_invalidResponseDescription() {
        let error = VaultResponseError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    // MARK: - API Response Type Tests

    func testProvisionVaultResponse_decoding() throws {
        let json = """
        {
            "instance_id": "i-1234567890",
            "status": "provisioning",
            "region": "us-east-1",
            "availability_zone": "us-east-1a",
            "private_ip": null,
            "estimated_ready_at": "2025-12-07T12:10:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ProvisionVaultResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.instanceId, "i-1234567890")
        XCTAssertEqual(response.status, "provisioning")
        XCTAssertEqual(response.region, "us-east-1")
        XCTAssertEqual(response.availabilityZone, "us-east-1a")
        XCTAssertNil(response.privateIp)
    }

    func testInitializeVaultResponse_decoding() throws {
        let json = """
        {
            "status": "initialized",
            "local_nats_status": "running",
            "central_nats_status": "connected",
            "owner_space_id": "OwnerSpace.user-123",
            "message_space_id": "MessageSpace.user-123"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(InitializeVaultResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "initialized")
        XCTAssertEqual(response.localNatsStatus, "running")
        XCTAssertEqual(response.centralNatsStatus, "connected")
        XCTAssertEqual(response.ownerSpaceId, "OwnerSpace.user-123")
    }

    func testVaultLifecycleResponse_decoding() throws {
        let json = """
        {
            "status": "stopped",
            "message": "Vault instance stopped successfully"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(VaultLifecycleResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "stopped")
        XCTAssertEqual(response.message, "Vault instance stopped successfully")
    }

    func testVaultHealthResponse_decoding() throws {
        let json = """
        {
            "status": "healthy",
            "uptime_seconds": 7200,
            "local_nats": {
                "status": "running",
                "connections": 3
            },
            "central_nats": {
                "status": "connected",
                "latency_ms": 45
            },
            "vault_manager": {
                "status": "running",
                "memory_mb": 512,
                "cpu_percent": 12.5,
                "handlers_loaded": 15
            },
            "last_event_at": "2025-12-07T11:55:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(VaultHealthResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "healthy")
        XCTAssertEqual(response.uptimeSeconds, 7200)
        XCTAssertEqual(response.localNats.status, "running")
        XCTAssertEqual(response.localNats.connections, 3)
        XCTAssertEqual(response.centralNats.status, "connected")
        XCTAssertEqual(response.centralNats.latencyMs, 45)
        XCTAssertEqual(response.vaultManager.status, "running")
        XCTAssertEqual(response.vaultManager.memoryMb, 512)
        XCTAssertEqual(response.vaultManager.cpuPercent, 12.5)
        XCTAssertEqual(response.vaultManager.handlersLoaded, 15)
        XCTAssertEqual(response.lastEventAt, "2025-12-07T11:55:00Z")
    }

    func testVaultHealthResponse_decoding_withoutLastEvent() throws {
        let json = """
        {
            "status": "degraded",
            "uptime_seconds": 300,
            "local_nats": {
                "status": "running",
                "connections": 1
            },
            "central_nats": {
                "status": "reconnecting",
                "latency_ms": 0
            },
            "vault_manager": {
                "status": "running",
                "memory_mb": 128,
                "cpu_percent": 5.0,
                "handlers_loaded": 5
            },
            "last_event_at": null
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(VaultHealthResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "degraded")
        XCTAssertNil(response.lastEventAt)
    }

    // MARK: - LocalNatsHealth Tests

    func testLocalNatsHealth_decoding() throws {
        let json = """
        {
            "status": "running",
            "connections": 10
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(LocalNatsHealth.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "running")
        XCTAssertEqual(response.connections, 10)
    }

    // MARK: - CentralNatsHealth Tests

    func testCentralNatsHealth_decoding() throws {
        let json = """
        {
            "status": "connected",
            "latency_ms": 75
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(CentralNatsHealth.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "connected")
        XCTAssertEqual(response.latencyMs, 75)
    }

    // MARK: - VaultManagerHealth Tests

    func testVaultManagerHealth_decoding() throws {
        let json = """
        {
            "status": "running",
            "memory_mb": 1024,
            "cpu_percent": 25.75,
            "handlers_loaded": 20
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(VaultManagerHealth.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "running")
        XCTAssertEqual(response.memoryMb, 1024)
        XCTAssertEqual(response.cpuPercent, 25.75)
        XCTAssertEqual(response.handlersLoaded, 20)
    }
}
