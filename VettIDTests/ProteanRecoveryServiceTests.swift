import XCTest
@testable import VettID

/// Tests for ProteanRecoveryService state management
@MainActor
final class ProteanRecoveryServiceTests: XCTestCase {

    // MARK: - State Tests

    func testInitialStateIsIdle() async {
        // Given
        let service = ProteanRecoveryService(authTokenProvider: { nil })

        // Then
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.activeRecovery)
        XCTAssertNil(service.error)
    }

    func testRequestRecoveryRequiresAuthentication() async {
        // Given
        let service = ProteanRecoveryService(authTokenProvider: { nil })

        // When
        await service.requestRecovery()

        // Then
        XCTAssertEqual(service.error, .notAuthenticated)
    }

    func testResetClearsAllState() async {
        // Given
        let service = ProteanRecoveryService(authTokenProvider: { "test-token" })

        // When
        service.reset()

        // Then
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.activeRecovery)
        XCTAssertNil(service.error)
    }

    // MARK: - Time Helper Tests

    func testRemainingTimeWhenNoActiveRecovery() async {
        // Given
        let service = ProteanRecoveryService(authTokenProvider: { "test-token" })

        // Then
        XCTAssertNil(service.remainingTime)
    }

    func testRemainingTimeStringWhenNoActiveRecovery() async {
        // Given
        let service = ProteanRecoveryService(authTokenProvider: { "test-token" })

        // Then
        XCTAssertEqual(service.remainingTimeString, "Ready")
    }

    // MARK: - Error Tests

    func testRecoveryErrorDescriptions() {
        // Test all error descriptions are non-nil
        let errors: [ProteanRecoveryError] = [
            .notAuthenticated,
            .requestFailed("test"),
            .statusCheckFailed("test"),
            .cancelFailed("test"),
            .downloadFailed("test"),
            .recoveryNotReady,
            .invalidCredentialData,
            .noPendingRecovery
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
        }
    }

    func testRecoveryErrorEquality() {
        // Same errors should be equal
        XCTAssertEqual(ProteanRecoveryError.notAuthenticated, ProteanRecoveryError.notAuthenticated)
        XCTAssertEqual(ProteanRecoveryError.recoveryNotReady, ProteanRecoveryError.recoveryNotReady)

        // Errors with same message should be equal
        XCTAssertEqual(
            ProteanRecoveryError.requestFailed("same"),
            ProteanRecoveryError.requestFailed("same")
        )

        // Different errors should not be equal
        XCTAssertNotEqual(
            ProteanRecoveryError.notAuthenticated,
            ProteanRecoveryError.recoveryNotReady
        )
    }
}

// MARK: - ActiveRecoveryInfo Tests

extension ProteanRecoveryServiceTests {

    func testActiveRecoveryInfoProgress() {
        // Given - recovery requested 12 hours ago, available in 24 hours
        let requestedAt = Date().addingTimeInterval(-12 * 3600)
        let availableAt = requestedAt.addingTimeInterval(24 * 3600)

        let recovery = ActiveRecoveryInfo(
            recoveryId: "test-id",
            requestedAt: requestedAt,
            availableAt: availableAt,
            status: .pending
        )

        // Then - should be approximately 50% complete
        XCTAssertGreaterThan(recovery.progress, 0.45)
        XCTAssertLessThan(recovery.progress, 0.55)
    }

    func testActiveRecoveryInfoProgressAtStart() {
        // Given - just requested
        let requestedAt = Date()
        let availableAt = requestedAt.addingTimeInterval(24 * 3600)

        let recovery = ActiveRecoveryInfo(
            recoveryId: "test-id",
            requestedAt: requestedAt,
            availableAt: availableAt,
            status: .pending
        )

        // Then - should be near 0%
        XCTAssertLessThan(recovery.progress, 0.05)
    }

    func testActiveRecoveryInfoProgressComplete() {
        // Given - recovery available in past
        let requestedAt = Date().addingTimeInterval(-25 * 3600)
        let availableAt = Date().addingTimeInterval(-1 * 3600)

        let recovery = ActiveRecoveryInfo(
            recoveryId: "test-id",
            requestedAt: requestedAt,
            availableAt: availableAt,
            status: .ready
        )

        // Then - should be 100%
        XCTAssertEqual(recovery.progress, 1.0)
    }

    func testActiveRecoveryInfoIsReady() {
        // Given - ready status and past availability
        let recovery1 = ActiveRecoveryInfo(
            recoveryId: "test-id",
            requestedAt: Date().addingTimeInterval(-25 * 3600),
            availableAt: Date().addingTimeInterval(-1 * 3600),
            status: .ready
        )

        // Then
        XCTAssertTrue(recovery1.isReady)

        // Given - pending status
        let recovery2 = ActiveRecoveryInfo(
            recoveryId: "test-id",
            requestedAt: Date(),
            availableAt: Date().addingTimeInterval(24 * 3600),
            status: .pending
        )

        // Then
        XCTAssertFalse(recovery2.isReady)
    }

    func testActiveRecoveryInfoCodable() throws {
        // Given
        let original = ActiveRecoveryInfo(
            recoveryId: "recovery-123",
            requestedAt: Date(timeIntervalSince1970: 1700000000),
            availableAt: Date(timeIntervalSince1970: 1700086400),
            status: .pending,
            remainingSeconds: 3600
        )

        // When
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActiveRecoveryInfo.self, from: encoded)

        // Then
        XCTAssertEqual(decoded.recoveryId, original.recoveryId)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.remainingSeconds, original.remainingSeconds)
    }
}

// MARK: - Recovery State Tests

extension ProteanRecoveryServiceTests {

    func testRecoveryStateEquality() {
        XCTAssertEqual(ProteanRecoveryState.idle, ProteanRecoveryState.idle)
        XCTAssertEqual(ProteanRecoveryState.pending, ProteanRecoveryState.pending)
        XCTAssertEqual(ProteanRecoveryState.ready, ProteanRecoveryState.ready)
        XCTAssertEqual(ProteanRecoveryState.complete, ProteanRecoveryState.complete)
        XCTAssertEqual(ProteanRecoveryState.cancelled, ProteanRecoveryState.cancelled)
        XCTAssertEqual(ProteanRecoveryState.expired, ProteanRecoveryState.expired)
        XCTAssertEqual(ProteanRecoveryState.error, ProteanRecoveryState.error)

        XCTAssertNotEqual(ProteanRecoveryState.idle, ProteanRecoveryState.pending)
        XCTAssertNotEqual(ProteanRecoveryState.ready, ProteanRecoveryState.complete)
    }

    func testRecoveryStatusRawValues() {
        // Verify raw values match expected strings for API communication
        XCTAssertEqual(ProteanRecoveryStatus.pending.rawValue, "pending")
        XCTAssertEqual(ProteanRecoveryStatus.ready.rawValue, "ready")
        XCTAssertEqual(ProteanRecoveryStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(ProteanRecoveryStatus.expired.rawValue, "expired")
    }
}
