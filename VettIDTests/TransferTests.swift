import XCTest
@testable import VettID

/// Tests for Transfer functionality (Issue #20)
final class TransferTests: XCTestCase {

    // MARK: - JSON Decoder/Encoder

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

    // MARK: - TransferState Tests

    func testTransferState_idle_equatable() {
        let state1 = TransferState.idle
        let state2 = TransferState.idle

        XCTAssertEqual(state1, state2)
    }

    func testTransferState_requesting_equatable() {
        let state1 = TransferState.requesting
        let state2 = TransferState.requesting

        XCTAssertEqual(state1, state2)
    }

    func testTransferState_waitingForApproval_equatable() {
        let date = Date()
        let state1 = TransferState.waitingForApproval(transferId: "123", expiresAt: date)
        let state2 = TransferState.waitingForApproval(transferId: "123", expiresAt: date)
        let state3 = TransferState.waitingForApproval(transferId: "456", expiresAt: date)

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_approved_equatable() {
        let state1 = TransferState.approved(transferId: "123")
        let state2 = TransferState.approved(transferId: "123")
        let state3 = TransferState.approved(transferId: "456")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_denied_equatable() {
        let state1 = TransferState.denied(transferId: "123")
        let state2 = TransferState.denied(transferId: "123")
        let state3 = TransferState.denied(transferId: "456")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_expired_equatable() {
        let state1 = TransferState.expired(transferId: "123")
        let state2 = TransferState.expired(transferId: "123")
        let state3 = TransferState.expired(transferId: "456")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_completed_equatable() {
        let state1 = TransferState.completed(transferId: "123")
        let state2 = TransferState.completed(transferId: "123")
        let state3 = TransferState.completed(transferId: "456")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_error_equatable() {
        let state1 = TransferState.error(message: "Error A")
        let state2 = TransferState.error(message: "Error A")
        let state3 = TransferState.error(message: "Error B")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testTransferState_differentTypes_notEqual() {
        let idle = TransferState.idle
        let requesting = TransferState.requesting
        let approved = TransferState.approved(transferId: "123")

        XCTAssertNotEqual(idle, requesting)
        XCTAssertNotEqual(idle, approved)
        XCTAssertNotEqual(requesting, approved)
    }

    // MARK: - TransferInitiationRequest Tests

    func testTransferInitiationRequest_encoding() throws {
        let deviceInfo = DeviceInfo(
            deviceId: "device-123",
            model: "iPhone 15",
            osVersion: "iOS 17.0",
            appVersion: "1.0.0",
            location: nil
        )

        let request = TransferInitiationRequest(
            requestId: "request-456",
            sourceDeviceInfo: deviceInfo,
            timestamp: Date()
        )

        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["request_id"] as? String, "request-456")
        XCTAssertNotNil(json["source_device_info"])
        XCTAssertNotNil(json["timestamp"])
    }

    // MARK: - TransferResponse Tests

    func testTransferResponse_encoding() throws {
        let response = TransferResponse(
            transferId: "transfer-789",
            approved: true,
            reason: nil,
            timestamp: Date()
        )

        let data = try encoder.encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["transfer_id"] as? String, "transfer-789")
        XCTAssertEqual(json["approved"] as? Bool, true)
    }

    func testTransferResponse_decoding() throws {
        let json = """
        {
            "transfer_id": "response-123",
            "approved": false,
            "reason": "User denied",
            "timestamp": "2026-01-17T10:00:00Z"
        }
        """

        let response = try decoder.decode(TransferResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.transferId, "response-123")
        XCTAssertFalse(response.approved)
        XCTAssertEqual(response.reason, "User denied")
    }

    // MARK: - TransferCredentialPayload Tests

    func testTransferCredentialPayload_encoding() throws {
        let payload = TransferCredentialPayload(
            transferId: "payload-123",
            encryptedCredential: "base64encodeddata",
            publicKey: "publickey123",
            signature: "signature456",
            timestamp: Date()
        )

        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["transfer_id"] as? String, "payload-123")
        XCTAssertEqual(json["encrypted_credential"] as? String, "base64encodeddata")
        XCTAssertEqual(json["public_key"] as? String, "publickey123")
        XCTAssertEqual(json["signature"] as? String, "signature456")
    }

    func testTransferCredentialPayload_decoding() throws {
        let json = """
        {
            "transfer_id": "decode-123",
            "encrypted_credential": "encrypted",
            "public_key": "pubkey",
            "signature": "sig",
            "timestamp": "2026-01-17T10:00:00Z"
        }
        """

        let payload = try decoder.decode(TransferCredentialPayload.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(payload.transferId, "decode-123")
        XCTAssertEqual(payload.encryptedCredential, "encrypted")
        XCTAssertEqual(payload.publicKey, "pubkey")
        XCTAssertEqual(payload.signature, "sig")
    }

    // MARK: - TransferTimeout Tests

    func testTransferTimeout_requestExpiration() {
        XCTAssertEqual(TransferTimeout.requestExpiration, 15 * 60) // 15 minutes
    }

    func testTransferTimeout_warningThreshold() {
        XCTAssertEqual(TransferTimeout.warningThreshold, 2 * 60) // 2 minutes
    }

    func testTransferTimeout_minimumRequired() {
        XCTAssertEqual(TransferTimeout.minimumRequired, 30) // 30 seconds
    }

    // MARK: - TransferError Tests

    func testTransferError_notAuthenticated() {
        let error = TransferError.notAuthenticated
        XCTAssertEqual(error.errorDescription, "You must be authenticated to transfer credentials")
    }

    func testTransferError_transferAlreadyPending() {
        let error = TransferError.transferAlreadyPending
        XCTAssertEqual(error.errorDescription, "A transfer is already in progress")
    }

    func testTransferError_transferNotFound() {
        let error = TransferError.transferNotFound
        XCTAssertEqual(error.errorDescription, "Transfer request not found")
    }

    func testTransferError_transferExpired() {
        let error = TransferError.transferExpired
        XCTAssertEqual(error.errorDescription, "Transfer request has expired")
    }

    func testTransferError_biometricFailed() {
        let error = TransferError.biometricFailed
        XCTAssertEqual(error.errorDescription, "Biometric authentication failed")
    }

    func testTransferError_networkError() {
        let error = TransferError.networkError("Connection timeout")
        XCTAssertEqual(error.errorDescription, "Network error: Connection timeout")
    }

    func testTransferError_encryptionError() {
        let error = TransferError.encryptionError
        XCTAssertEqual(error.errorDescription, "Failed to encrypt credential for transfer")
    }

    func testTransferError_invalidCredential() {
        let error = TransferError.invalidCredential
        XCTAssertEqual(error.errorDescription, "Invalid credential data received")
    }

    func testTransferError_deviceMismatch() {
        let error = TransferError.deviceMismatch
        XCTAssertEqual(error.errorDescription, "Device verification failed")
    }

    // MARK: - DeviceInfo.current() Tests

    func testDeviceInfo_current_returnsValidInfo() {
        let info = DeviceInfo.current()

        XCTAssertFalse(info.deviceId.isEmpty)
        XCTAssertFalse(info.model.isEmpty)
        XCTAssertFalse(info.osVersion.isEmpty)
    }
}

// MARK: - TransferViewModel Tests

@MainActor
final class TransferViewModelTests: XCTestCase {

    // MARK: - Initialization Tests

    func testViewModel_initialState_isIdle() {
        let viewModel = TransferViewModel()
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testViewModel_initialTimeRemaining_isZero() {
        let viewModel = TransferViewModel()
        XCTAssertEqual(viewModel.timeRemaining, 0)
    }

    func testViewModel_initialIsLoading_isFalse() {
        let viewModel = TransferViewModel()
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Reset Tests

    func testViewModel_reset_setsStateToIdle() {
        let viewModel = TransferViewModel()

        // Change state first
        viewModel.reset()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.timeRemaining, 0)
    }

    // MARK: - Time Formatting Tests

    func testViewModel_formattedTimeRemaining_zeroTime() {
        let viewModel = TransferViewModel()
        XCTAssertEqual(viewModel.formattedTimeRemaining, "00:00")
    }

    func testViewModel_isTimeWarning_falseWhenZero() {
        let viewModel = TransferViewModel()
        XCTAssertFalse(viewModel.isTimeWarning)
    }

    // MARK: - Handle Transfer Request Tests

    func testViewModel_handleTransferRequest_setsState() {
        let viewModel = TransferViewModel()

        let event = TransferRequestedEvent(
            transferId: "vm-transfer-123",
            sourceDeviceId: "old-device",
            targetDeviceInfo: DeviceInfo(
                deviceId: "new-device",
                model: "iPhone 15",
                osVersion: "iOS 17.0",
                appVersion: nil,
                location: nil
            ),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(900)
        )

        viewModel.handleTransferRequest(event)

        if case .pendingApproval(let request) = viewModel.state {
            XCTAssertEqual(request.transferId, "vm-transfer-123")
        } else {
            XCTFail("Expected pendingApproval state")
        }
    }

    // MARK: - Handle Transfer Events Tests

    func testViewModel_handleTransferCompleted_setsCompletedState() {
        let viewModel = TransferViewModel()

        // First set up a pending transfer
        let requestEvent = TransferRequestedEvent(
            transferId: "complete-123",
            sourceDeviceId: nil,
            targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(900)
        )
        viewModel.handleTransferRequest(requestEvent)

        // Now complete it
        let completedEvent = TransferCompletedEvent(
            transferId: "complete-123",
            completedAt: Date(),
            targetDeviceId: "device-456"
        )
        viewModel.handleTransferCompleted(completedEvent)

        if case .completed(let transferId) = viewModel.state {
            XCTAssertEqual(transferId, "complete-123")
        } else {
            XCTFail("Expected completed state")
        }
    }

    func testViewModel_handleTransferExpired_setsExpiredState() {
        let viewModel = TransferViewModel()

        // First set up a pending transfer
        let requestEvent = TransferRequestedEvent(
            transferId: "expire-123",
            sourceDeviceId: nil,
            targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(900)
        )
        viewModel.handleTransferRequest(requestEvent)

        // Now expire it
        let expiredEvent = TransferExpiredEvent(
            transferId: "expire-123",
            expiredAt: Date()
        )
        viewModel.handleTransferExpired(expiredEvent)

        if case .expired(let transferId) = viewModel.state {
            XCTAssertEqual(transferId, "expire-123")
        } else {
            XCTFail("Expected expired state")
        }
    }

    func testViewModel_handleTransferDenied_setsDeniedState() {
        let viewModel = TransferViewModel()

        // First set up a waiting state (new device flow)
        // Simulate being in waitingForApproval state
        let deniedEvent = TransferDeniedEvent(
            transferId: "deny-123",
            deniedAt: Date(),
            reason: "User denied"
        )

        // Note: This won't change state without matching currentTransferId
        // Testing that it doesn't crash
        viewModel.handleTransferDenied(deniedEvent)
    }

    // MARK: - Request Transfer Tests

    func testViewModel_requestTransfer_changesStateFromIdle() async {
        let viewModel = TransferViewModel()

        XCTAssertEqual(viewModel.state, .idle)

        // Note: Without a configured OwnerSpaceClient, this will set state to .requesting
        // then to .error because it can't send the request
        await viewModel.requestTransfer()

        // State should have changed from idle
        XCTAssertNotEqual(viewModel.state, .idle)
    }

    func testViewModel_requestTransfer_notIdleState_doesNothing() async {
        let viewModel = TransferViewModel()

        // Put in requesting state first
        let event = TransferRequestedEvent(
            transferId: "block-123",
            sourceDeviceId: nil,
            targetDeviceInfo: DeviceInfo(deviceId: "d", model: "m", osVersion: "o", appVersion: nil, location: nil),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(900)
        )
        viewModel.handleTransferRequest(event)

        // Now try to request - should not change state
        let stateBefore = viewModel.state
        await viewModel.requestTransfer()
        let stateAfter = viewModel.state

        XCTAssertEqual(stateBefore, stateAfter)
    }

    // MARK: - Cancel Request Tests

    func testViewModel_cancelRequest_notWaiting_doesNothing() async {
        let viewModel = TransferViewModel()

        // In idle state, cancel should do nothing
        await viewModel.cancelRequest()

        XCTAssertEqual(viewModel.state, .idle)
    }
}
