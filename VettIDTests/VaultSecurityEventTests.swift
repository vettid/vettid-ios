import XCTest
@testable import VettID

/// Tests for VaultSecurityEvent and related types (Issue #17)
final class VaultSecurityEventTests: XCTestCase {

    // MARK: - JSON Decoder Setup

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - RecoveryRequestedEvent Tests

    func testRecoveryRequestedEvent_decoding() throws {
        let json = """
        {
            "request_id": "recovery-123",
            "email": "user@example.com",
            "requested_at": "2026-01-17T10:00:00Z",
            "expires_at": "2026-01-18T10:00:00Z",
            "source_ip": "192.168.1.1",
            "user_agent": "VettID/1.0"
        }
        """

        let event = try decoder.decode(RecoveryRequestedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.requestId, "recovery-123")
        XCTAssertEqual(event.email, "user@example.com")
        XCTAssertEqual(event.sourceIp, "192.168.1.1")
        XCTAssertEqual(event.userAgent, "VettID/1.0")
        XCTAssertNotNil(event.requestedAt)
        XCTAssertNotNil(event.expiresAt)
    }

    func testRecoveryRequestedEvent_decodingWithOptionalFields() throws {
        let json = """
        {
            "request_id": "recovery-456",
            "requested_at": "2026-01-17T10:00:00Z"
        }
        """

        let event = try decoder.decode(RecoveryRequestedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.requestId, "recovery-456")
        XCTAssertNil(event.email)
        XCTAssertNil(event.expiresAt)
        XCTAssertNil(event.sourceIp)
        XCTAssertNil(event.userAgent)
    }

    // MARK: - RecoveryCancelledEvent Tests

    func testRecoveryCancelledEvent_decoding() throws {
        let json = """
        {
            "request_id": "recovery-789",
            "reason": "user_cancelled",
            "cancelled_at": "2026-01-17T11:00:00Z"
        }
        """

        let event = try decoder.decode(RecoveryCancelledEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.requestId, "recovery-789")
        XCTAssertEqual(event.reason, .userCancelled)
        XCTAssertNotNil(event.cancelledAt)
    }

    func testRecoveryCancelReason_allCases() {
        XCTAssertEqual(RecoveryCancelReason.userCancelled.rawValue, "user_cancelled")
        XCTAssertEqual(RecoveryCancelReason.expired.rawValue, "expired")
        XCTAssertEqual(RecoveryCancelReason.fraudDetected.rawValue, "fraud_detected")
        XCTAssertEqual(RecoveryCancelReason.adminCancelled.rawValue, "admin_cancelled")
        XCTAssertEqual(RecoveryCancelReason.systemError.rawValue, "system_error")
    }

    // MARK: - RecoveryCompletedEvent Tests

    func testRecoveryCompletedEvent_decoding() throws {
        let json = """
        {
            "request_id": "recovery-completed-123",
            "completed_at": "2026-01-17T12:00:00Z",
            "new_device_id": "device-new-456"
        }
        """

        let event = try decoder.decode(RecoveryCompletedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.requestId, "recovery-completed-123")
        XCTAssertEqual(event.newDeviceId, "device-new-456")
        XCTAssertNotNil(event.completedAt)
    }

    // MARK: - TransferRequestedEvent Tests

    func testTransferRequestedEvent_decoding() throws {
        let json = """
        {
            "transfer_id": "transfer-123",
            "source_device_id": "device-old",
            "target_device_info": {
                "device_id": "device-new",
                "model": "iPhone 15 Pro",
                "os_version": "iOS 17.2",
                "app_version": "1.0.0",
                "location": "San Francisco, CA"
            },
            "requested_at": "2026-01-17T10:00:00Z",
            "expires_at": "2026-01-17T10:15:00Z"
        }
        """

        let event = try decoder.decode(TransferRequestedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.transferId, "transfer-123")
        XCTAssertEqual(event.sourceDeviceId, "device-old")
        XCTAssertEqual(event.targetDeviceInfo.deviceId, "device-new")
        XCTAssertEqual(event.targetDeviceInfo.model, "iPhone 15 Pro")
        XCTAssertEqual(event.targetDeviceInfo.osVersion, "iOS 17.2")
        XCTAssertEqual(event.targetDeviceInfo.appVersion, "1.0.0")
        XCTAssertEqual(event.targetDeviceInfo.location, "San Francisco, CA")
    }

    // MARK: - TransferApprovedEvent Tests

    func testTransferApprovedEvent_decoding() throws {
        let json = """
        {
            "transfer_id": "transfer-approved-123",
            "approved_at": "2026-01-17T10:05:00Z"
        }
        """

        let event = try decoder.decode(TransferApprovedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.transferId, "transfer-approved-123")
        XCTAssertNotNil(event.approvedAt)
    }

    // MARK: - TransferDeniedEvent Tests

    func testTransferDeniedEvent_decoding() throws {
        let json = """
        {
            "transfer_id": "transfer-denied-123",
            "denied_at": "2026-01-17T10:05:00Z",
            "reason": "User denied the request"
        }
        """

        let event = try decoder.decode(TransferDeniedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.transferId, "transfer-denied-123")
        XCTAssertEqual(event.reason, "User denied the request")
        XCTAssertNotNil(event.deniedAt)
    }

    // MARK: - TransferCompletedEvent Tests

    func testTransferCompletedEvent_decoding() throws {
        let json = """
        {
            "transfer_id": "transfer-completed-123",
            "completed_at": "2026-01-17T10:10:00Z",
            "target_device_id": "device-new-789"
        }
        """

        let event = try decoder.decode(TransferCompletedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.transferId, "transfer-completed-123")
        XCTAssertEqual(event.targetDeviceId, "device-new-789")
    }

    // MARK: - TransferExpiredEvent Tests

    func testTransferExpiredEvent_decoding() throws {
        let json = """
        {
            "transfer_id": "transfer-expired-123",
            "expired_at": "2026-01-17T10:15:00Z"
        }
        """

        let event = try decoder.decode(TransferExpiredEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.transferId, "transfer-expired-123")
        XCTAssertNotNil(event.expiredAt)
    }

    // MARK: - RecoveryFraudDetectedEvent Tests

    func testRecoveryFraudDetectedEvent_decoding() throws {
        let json = """
        {
            "request_id": "fraud-123",
            "reason": "credential_used_during_recovery",
            "detected_at": "2026-01-17T10:30:00Z",
            "credential_used_at": "2026-01-17T10:25:00Z",
            "usage_details": "Credential was used for authentication"
        }
        """

        let event = try decoder.decode(RecoveryFraudDetectedEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.requestId, "fraud-123")
        XCTAssertEqual(event.reason, .credentialUsedDuringRecovery)
        XCTAssertEqual(event.usageDetails, "Credential was used for authentication")
        XCTAssertNotNil(event.detectedAt)
        XCTAssertNotNil(event.credentialUsedAt)
    }

    func testFraudDetectionReason_allCases() {
        XCTAssertEqual(FraudDetectionReason.credentialUsedDuringRecovery.rawValue, "credential_used_during_recovery")
        XCTAssertEqual(FraudDetectionReason.multipleRecoveryAttempts.rawValue, "multiple_recovery_attempts")
        XCTAssertEqual(FraudDetectionReason.suspiciousActivity.rawValue, "suspicious_activity")
    }

    // MARK: - DeviceInfo Tests

    func testDeviceInfo_decoding() throws {
        let json = """
        {
            "device_id": "device-123",
            "model": "iPhone 15 Pro Max",
            "os_version": "iOS 17.2.1",
            "app_version": "2.0.0",
            "location": "New York, NY"
        }
        """

        let info = try decoder.decode(DeviceInfo.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(info.deviceId, "device-123")
        XCTAssertEqual(info.model, "iPhone 15 Pro Max")
        XCTAssertEqual(info.osVersion, "iOS 17.2.1")
        XCTAssertEqual(info.appVersion, "2.0.0")
        XCTAssertEqual(info.location, "New York, NY")
    }

    func testDeviceInfo_displayName() {
        let info = DeviceInfo(
            deviceId: "test",
            model: "iPhone 15",
            osVersion: "iOS 17.0",
            appVersion: nil,
            location: nil
        )

        XCTAssertEqual(info.displayName, "iPhone 15 (iOS 17.0)")
    }

    func testDeviceInfo_encoding() throws {
        let info = DeviceInfo(
            deviceId: "encode-test",
            model: "iPad Pro",
            osVersion: "iPadOS 17.0",
            appVersion: "1.5.0",
            location: "London, UK"
        )

        let data = try encoder.encode(info)
        let decoded = try decoder.decode(DeviceInfo.self, from: data)

        XCTAssertEqual(decoded.deviceId, info.deviceId)
        XCTAssertEqual(decoded.model, info.model)
        XCTAssertEqual(decoded.osVersion, info.osVersion)
        XCTAssertEqual(decoded.appVersion, info.appVersion)
        XCTAssertEqual(decoded.location, info.location)
    }

    // MARK: - SecurityEventMessage Tests

    func testSecurityEventMessage_decoding() throws {
        let json = """
        {
            "event_id": "evt-123",
            "event_type": "recovery.requested",
            "timestamp": "2026-01-17T10:00:00Z",
            "data": {
                "request_id": "recovery-msg-123",
                "requested_at": "2026-01-17T10:00:00Z"
            }
        }
        """

        let message = try decoder.decode(SecurityEventMessage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(message.eventId, "evt-123")
        XCTAssertEqual(message.eventType, "recovery.requested")
        XCTAssertNotNil(message.timestamp)
    }

    // MARK: - VaultSecurityEvent Parsing Tests

    func testVaultSecurityEvent_parseRecoveryRequested() throws {
        let json = """
        {
            "event_id": "evt-recovery",
            "event_type": "recovery.requested",
            "timestamp": "2026-01-17T10:00:00Z",
            "data": {
                "request_id": "recovery-parse-123",
                "email": "test@example.com",
                "requested_at": "2026-01-17T10:00:00Z"
            }
        }
        """

        let event = VaultSecurityEvent.parse(from: json.data(using: .utf8)!)

        if case .recoveryRequested(let e) = event {
            XCTAssertEqual(e.requestId, "recovery-parse-123")
            XCTAssertEqual(e.email, "test@example.com")
        } else {
            XCTFail("Expected recoveryRequested event")
        }
    }

    func testVaultSecurityEvent_parseTransferRequested() throws {
        let json = """
        {
            "event_id": "evt-transfer",
            "event_type": "transfer.requested",
            "timestamp": "2026-01-17T10:00:00Z",
            "data": {
                "transfer_id": "transfer-parse-123",
                "target_device_info": {
                    "device_id": "new-device",
                    "model": "iPhone 15",
                    "os_version": "iOS 17.0"
                },
                "requested_at": "2026-01-17T10:00:00Z",
                "expires_at": "2026-01-17T10:15:00Z"
            }
        }
        """

        let event = VaultSecurityEvent.parse(from: json.data(using: .utf8)!)

        if case .transferRequested(let e) = event {
            XCTAssertEqual(e.transferId, "transfer-parse-123")
            XCTAssertEqual(e.targetDeviceInfo.model, "iPhone 15")
        } else {
            XCTFail("Expected transferRequested event")
        }
    }

    func testVaultSecurityEvent_parseFraudDetected() throws {
        let json = """
        {
            "event_id": "evt-fraud",
            "event_type": "security.fraud_detected",
            "timestamp": "2026-01-17T10:00:00Z",
            "data": {
                "request_id": "fraud-parse-123",
                "reason": "credential_used_during_recovery",
                "detected_at": "2026-01-17T10:00:00Z"
            }
        }
        """

        let event = VaultSecurityEvent.parse(from: json.data(using: .utf8)!)

        if case .recoveryFraudDetected(let e) = event {
            XCTAssertEqual(e.requestId, "fraud-parse-123")
            XCTAssertEqual(e.reason, .credentialUsedDuringRecovery)
        } else {
            XCTFail("Expected recoveryFraudDetected event")
        }
    }

    // MARK: - VaultSecurityEvent Properties Tests

    func testVaultSecurityEvent_eventId() {
        let recoveryEvent = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(
                requestId: "req-123",
                email: nil,
                requestedAt: Date(),
                expiresAt: nil,
                sourceIp: nil,
                userAgent: nil
            )
        )
        XCTAssertEqual(recoveryEvent.eventId, "recovery-req-123")

        let transferEvent = VaultSecurityEvent.transferRequested(
            TransferRequestedEvent(
                transferId: "txfr-456",
                sourceDeviceId: nil,
                targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
                requestedAt: Date(),
                expiresAt: Date()
            )
        )
        XCTAssertEqual(transferEvent.eventId, "transfer-txfr-456")

        let fraudEvent = VaultSecurityEvent.recoveryFraudDetected(
            RecoveryFraudDetectedEvent(
                requestId: "fraud-789",
                reason: .suspiciousActivity,
                detectedAt: Date(),
                credentialUsedAt: nil,
                usageDetails: nil
            )
        )
        XCTAssertEqual(fraudEvent.eventId, "fraud-fraud-789")
    }

    func testVaultSecurityEvent_requiresImmediateAttention() {
        let recoveryRequested = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(requestId: "r", email: nil, requestedAt: Date(), expiresAt: nil, sourceIp: nil, userAgent: nil)
        )
        XCTAssertTrue(recoveryRequested.requiresImmediateAttention)

        let transferRequested = VaultSecurityEvent.transferRequested(
            TransferRequestedEvent(
                transferId: "t",
                sourceDeviceId: nil,
                targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
                requestedAt: Date(),
                expiresAt: Date()
            )
        )
        XCTAssertTrue(transferRequested.requiresImmediateAttention)

        let fraudDetected = VaultSecurityEvent.recoveryFraudDetected(
            RecoveryFraudDetectedEvent(requestId: "f", reason: .suspiciousActivity, detectedAt: Date(), credentialUsedAt: nil, usageDetails: nil)
        )
        XCTAssertTrue(fraudDetected.requiresImmediateAttention)

        let recoveryCancelled = VaultSecurityEvent.recoveryCancelled(
            RecoveryCancelledEvent(requestId: "c", reason: .userCancelled, cancelledAt: Date())
        )
        XCTAssertFalse(recoveryCancelled.requiresImmediateAttention)

        let transferApproved = VaultSecurityEvent.transferApproved(
            TransferApprovedEvent(transferId: "a", approvedAt: Date())
        )
        XCTAssertFalse(transferApproved.requiresImmediateAttention)
    }

    func testVaultSecurityEvent_category() {
        let recoveryEvent = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(requestId: "r", email: nil, requestedAt: Date(), expiresAt: nil, sourceIp: nil, userAgent: nil)
        )
        XCTAssertEqual(recoveryEvent.category, .recovery)

        let transferEvent = VaultSecurityEvent.transferRequested(
            TransferRequestedEvent(
                transferId: "t",
                sourceDeviceId: nil,
                targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
                requestedAt: Date(),
                expiresAt: Date()
            )
        )
        XCTAssertEqual(transferEvent.category, .transfer)

        let fraudEvent = VaultSecurityEvent.recoveryFraudDetected(
            RecoveryFraudDetectedEvent(requestId: "f", reason: .suspiciousActivity, detectedAt: Date(), credentialUsedAt: nil, usageDetails: nil)
        )
        XCTAssertEqual(fraudEvent.category, .fraud)
    }

    // MARK: - Equatable Tests

    func testVaultSecurityEvent_equatable() {
        let event1 = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(requestId: "same", email: "a@b.com", requestedAt: Date(), expiresAt: nil, sourceIp: nil, userAgent: nil)
        )
        let event2 = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(requestId: "same", email: "a@b.com", requestedAt: Date(), expiresAt: nil, sourceIp: nil, userAgent: nil)
        )
        let event3 = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(requestId: "different", email: "a@b.com", requestedAt: Date(), expiresAt: nil, sourceIp: nil, userAgent: nil)
        )

        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
    }
}
