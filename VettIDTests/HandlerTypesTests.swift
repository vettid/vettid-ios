import XCTest
@testable import VettID

/// Tests for Handler-related types
final class HandlerTypesTests: XCTestCase {

    // MARK: - HandlerListResponse Tests

    func testHandlerListResponse_decoding() throws {
        let json = """
        {
            "handlers": [
                {
                    "id": "handler-1",
                    "name": "Test Handler",
                    "description": "A test handler",
                    "version": "1.0.0",
                    "category": "utilities",
                    "icon_url": "https://example.com/icon.png",
                    "publisher": "Test Publisher",
                    "installed": true,
                    "installed_version": "1.0.0"
                }
            ],
            "total": 1,
            "page": 1,
            "has_more": false
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HandlerListResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.handlers.count, 1)
        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.page, 1)
        XCTAssertFalse(response.hasMore)

        let handler = response.handlers[0]
        XCTAssertEqual(handler.id, "handler-1")
        XCTAssertEqual(handler.name, "Test Handler")
        XCTAssertTrue(handler.installed)
    }

    func testHandlerListResponse_withMultipleHandlers() throws {
        let json = """
        {
            "handlers": [
                {"id": "1", "name": "Handler 1", "description": "Desc 1", "version": "1.0", "category": "utilities", "icon_url": null, "publisher": "Pub", "installed": false, "installed_version": null},
                {"id": "2", "name": "Handler 2", "description": "Desc 2", "version": "2.0", "category": "messaging", "icon_url": null, "publisher": "Pub", "installed": true, "installed_version": "2.0"}
            ],
            "total": 10,
            "page": 1,
            "has_more": true
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HandlerListResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.handlers.count, 2)
        XCTAssertEqual(response.total, 10)
        XCTAssertTrue(response.hasMore)
    }

    // MARK: - HandlerSummary Tests

    func testHandlerSummary_equality() {
        let handler1 = HandlerSummary(
            id: "test-1",
            name: "Test",
            description: "Desc",
            version: "1.0",
            category: "cat",
            iconUrl: nil,
            publisher: "Pub",
            installed: false,
            installedVersion: nil
        )

        let handler2 = HandlerSummary(
            id: "test-1",
            name: "Test",
            description: "Desc",
            version: "1.0",
            category: "cat",
            iconUrl: nil,
            publisher: "Pub",
            installed: false,
            installedVersion: nil
        )

        let handler3 = HandlerSummary(
            id: "test-2",
            name: "Test",
            description: "Desc",
            version: "1.0",
            category: "cat",
            iconUrl: nil,
            publisher: "Pub",
            installed: false,
            installedVersion: nil
        )

        XCTAssertEqual(handler1, handler2)
        XCTAssertNotEqual(handler1, handler3)
    }

    // MARK: - HandlerDetailResponse Tests

    func testHandlerDetailResponse_decoding() throws {
        let json = """
        {
            "id": "handler-detail-1",
            "name": "Detailed Handler",
            "description": "A detailed description",
            "version": "2.0.0",
            "category": "productivity",
            "icon_url": "https://example.com/icon.png",
            "publisher": "Publisher Inc",
            "published_at": "2025-01-01T12:00:00Z",
            "size_bytes": 102400,
            "permissions": [
                {"type": "network", "scope": "api.example.com", "description": "Access API"}
            ],
            "input_schema": {"message": {"type": "string"}},
            "output_schema": {"result": {"type": "boolean"}},
            "changelog": "Initial release",
            "installed": false,
            "installed_version": null
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HandlerDetailResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.id, "handler-detail-1")
        XCTAssertEqual(response.name, "Detailed Handler")
        XCTAssertEqual(response.version, "2.0.0")
        XCTAssertEqual(response.sizeBytes, 102400)
        XCTAssertEqual(response.permissions.count, 1)
        XCTAssertEqual(response.changelog, "Initial release")
        XCTAssertFalse(response.installed)
    }

    // MARK: - HandlerPermission Tests

    func testHandlerPermission_decoding() throws {
        let json = """
        {
            "type": "network",
            "scope": "*.example.com",
            "description": "Access example.com domains"
        }
        """

        let decoder = JSONDecoder()
        let permission = try decoder.decode(HandlerPermission.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(permission.type, "network")
        XCTAssertEqual(permission.scope, "*.example.com")
        XCTAssertEqual(permission.description, "Access example.com domains")
    }

    func testHandlerPermission_equality() {
        let perm1 = HandlerPermission(type: "network", scope: "api.com", description: "desc")
        let perm2 = HandlerPermission(type: "network", scope: "api.com", description: "desc")
        let perm3 = HandlerPermission(type: "storage", scope: "api.com", description: "desc")

        XCTAssertEqual(perm1, perm2)
        XCTAssertNotEqual(perm1, perm3)
    }

    // MARK: - InstallHandlerResponse Tests

    func testInstallHandlerResponse_decoding() throws {
        let json = """
        {
            "status": "installed",
            "handler_id": "handler-123",
            "version": "1.0.0",
            "installed_at": "2025-01-01T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(InstallHandlerResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "installed")
        XCTAssertEqual(response.handlerId, "handler-123")
        XCTAssertEqual(response.version, "1.0.0")
        XCTAssertNotNil(response.installedAt)
    }

    // MARK: - UninstallHandlerResponse Tests

    func testUninstallHandlerResponse_decoding() throws {
        let json = """
        {
            "status": "uninstalled",
            "handler_id": "handler-456"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(UninstallHandlerResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.status, "uninstalled")
        XCTAssertEqual(response.handlerId, "handler-456")
    }

    // MARK: - InstalledHandler Tests

    func testInstalledHandler_decoding() throws {
        let json = """
        {
            "id": "installed-1",
            "name": "Installed Handler",
            "version": "1.2.3",
            "installed_at": "2025-01-01T10:00:00Z",
            "last_executed_at": "2025-01-02T15:30:00Z",
            "execution_count": 42
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let handler = try decoder.decode(InstalledHandler.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(handler.id, "installed-1")
        XCTAssertEqual(handler.name, "Installed Handler")
        XCTAssertEqual(handler.version, "1.2.3")
        XCTAssertEqual(handler.executionCount, 42)
        XCTAssertNotNil(handler.lastExecutedAt)
    }

    func testInstalledHandler_withoutLastExecuted() throws {
        let json = """
        {
            "id": "installed-2",
            "name": "New Handler",
            "version": "1.0.0",
            "installed_at": "2025-01-01T10:00:00Z",
            "last_executed_at": null,
            "execution_count": 0
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let handler = try decoder.decode(InstalledHandler.self, from: json.data(using: .utf8)!)

        XCTAssertNil(handler.lastExecutedAt)
        XCTAssertEqual(handler.executionCount, 0)
    }
}
