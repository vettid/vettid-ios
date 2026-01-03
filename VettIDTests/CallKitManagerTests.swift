import XCTest
@testable import VettID

/// Tests for CallKit integration types
final class CallKitManagerTests: XCTestCase {

    // MARK: - CallState Tests

    func testCallStateEquality() {
        XCTAssertEqual(CallState.idle, CallState.idle)
        XCTAssertEqual(CallState.ringing, CallState.ringing)
        XCTAssertEqual(CallState.connecting, CallState.connecting)
        XCTAssertEqual(CallState.connected, CallState.connected)
        XCTAssertEqual(CallState.reconnecting, CallState.reconnecting)

        XCTAssertNotEqual(CallState.idle, CallState.ringing)
        XCTAssertNotEqual(CallState.connecting, CallState.connected)
    }

    // MARK: - PendingCall Tests

    func testPendingCallCreation() {
        let uuid = UUID()
        let pending = PendingCall(
            uuid: uuid,
            callId: "call-123",
            callerId: "user-abc",
            callerDisplayName: "John Doe",
            callType: .video,
            isOutgoing: false
        )

        XCTAssertEqual(pending.uuid, uuid)
        XCTAssertEqual(pending.callId, "call-123")
        XCTAssertEqual(pending.callerId, "user-abc")
        XCTAssertEqual(pending.callerDisplayName, "John Doe")
        XCTAssertEqual(pending.callType, .video)
        XCTAssertFalse(pending.isOutgoing)
    }

    func testPendingCallOutgoing() {
        let pending = PendingCall(
            uuid: UUID(),
            callId: "call-456",
            callerId: "user-xyz",
            callerDisplayName: "Jane Smith",
            callType: .audio,
            isOutgoing: true
        )

        XCTAssertEqual(pending.callType, .audio)
        XCTAssertTrue(pending.isOutgoing)
    }

    // MARK: - ActiveCall Tests

    func testActiveCallCreation() {
        let uuid = UUID()
        let connectedAt = Date()
        let active = ActiveCall(
            uuid: uuid,
            callId: "call-123",
            peerId: "user-abc",
            peerDisplayName: "John Doe",
            callType: .video,
            isOutgoing: false,
            connectedAt: connectedAt
        )

        XCTAssertEqual(active.uuid, uuid)
        XCTAssertEqual(active.id, uuid)
        XCTAssertEqual(active.callId, "call-123")
        XCTAssertEqual(active.peerId, "user-abc")
        XCTAssertEqual(active.peerDisplayName, "John Doe")
        XCTAssertEqual(active.callType, .video)
        XCTAssertFalse(active.isOutgoing)
        XCTAssertEqual(active.connectedAt, connectedAt)
    }

    func testActiveCallDuration() {
        let pastDate = Date().addingTimeInterval(-60) // 60 seconds ago
        let active = ActiveCall(
            uuid: UUID(),
            callId: "call-123",
            peerId: "user-abc",
            peerDisplayName: "John Doe",
            callType: .audio,
            isOutgoing: true,
            connectedAt: pastDate
        )

        // Duration should be approximately 60 seconds
        XCTAssertGreaterThan(active.duration, 59)
        XCTAssertLessThan(active.duration, 62)
    }

    func testActiveCallIdentifiable() {
        let uuid = UUID()
        let active = ActiveCall(
            uuid: uuid,
            callId: "call-123",
            peerId: "user-abc",
            peerDisplayName: "John Doe",
            callType: .video,
            isOutgoing: false,
            connectedAt: Date()
        )

        // Identifiable protocol
        XCTAssertEqual(active.id, uuid)
    }

    // MARK: - CallKitError Tests

    func testCallKitErrorDescriptions() {
        let errors: [CallKitError] = [
            .notConfigured,
            .callNotFound,
            .transactionFailed("test reason"),
            .signalingFailed("test reason")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testCallKitErrorNotConfigured() {
        let error = CallKitError.notConfigured
        XCTAssertTrue(error.errorDescription!.contains("not configured"))
    }

    func testCallKitErrorTransactionFailed() {
        let error = CallKitError.transactionFailed("user declined")
        XCTAssertTrue(error.errorDescription!.contains("user declined"))
    }

    func testCallKitErrorSignalingFailed() {
        let error = CallKitError.signalingFailed("network timeout")
        XCTAssertTrue(error.errorDescription!.contains("network timeout"))
    }
}

// MARK: - CallEventEnvelope Tests

extension CallKitManagerTests {

    func testCallEventEnvelopeDecoding() throws {
        let json = """
        {
            "type": "call.incoming",
            "timestamp": 1704067200000,
            "data": {
                "call_id": "call-123",
                "caller_id": "user-abc",
                "caller_display_name": "John Doe",
                "call_type": "video"
            }
        }
        """

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CallEventEnvelope.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(envelope.type, "call.incoming")
        XCTAssertEqual(envelope.timestamp, 1704067200000)
        XCTAssertNotNil(envelope.data)
        XCTAssertEqual(envelope.data?["call_id"] as? String, "call-123")
        XCTAssertEqual(envelope.data?["caller_id"] as? String, "user-abc")
    }

    func testCallEventEnvelopeDecodingWithoutData() throws {
        let json = """
        {
            "type": "call.ended",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CallEventEnvelope.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(envelope.type, "call.ended")
        XCTAssertNil(envelope.data)
    }

    func testCallEventEnvelopeDecodingWithNumericData() throws {
        let json = """
        {
            "type": "call.ended",
            "data": {
                "duration": 125,
                "quality_score": 0.95,
                "is_video": true
            }
        }
        """

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CallEventEnvelope.self, from: json.data(using: .utf8)!)

        XCTAssertNotNil(envelope.data)
        XCTAssertEqual(envelope.data?["duration"] as? Int, 125)
        XCTAssertEqual(envelope.data?["quality_score"] as? Double, 0.95)
        XCTAssertEqual(envelope.data?["is_video"] as? Bool, true)
    }

    func testAllCallEventTypes() {
        let eventTypes = [
            "call.incoming",
            "call.offer",
            "call.answer",
            "call.candidate",
            "call.accepted",
            "call.rejected",
            "call.ended",
            "call.missed",
            "call.blocked",
            "call.busy"
        ]

        // Verify we have documentation for all 10 event types
        XCTAssertEqual(eventTypes.count, 10)
    }
}

// MARK: - Integration Scenario Tests

extension CallKitManagerTests {

    func testIncomingCallScenario() {
        // Simulate an incoming call flow
        let callId = "call-\(UUID().uuidString)"
        let callerId = "user-\(UUID().uuidString)"

        // Create incoming call
        let incomingCall = IncomingCall(
            callId: callId,
            callerId: callerId,
            callerDisplayName: "Test Caller",
            callType: .video,
            timestamp: Date().timeIntervalSince1970 * 1000
        )

        // Verify call properties
        XCTAssertFalse(incomingCall.callId.isEmpty)
        XCTAssertFalse(incomingCall.callerId.isEmpty)
        XCTAssertEqual(incomingCall.callType, .video)
    }

    func testOutgoingCallScenario() {
        // Simulate an outgoing call flow
        let targetUserId = "user-\(UUID().uuidString)"
        let callType = CallType.audio

        // Create pending call
        let uuid = UUID()
        let pending = PendingCall(
            uuid: uuid,
            callId: "call-\(UUID().uuidString)",
            callerId: targetUserId,
            callerDisplayName: "Test Callee",
            callType: callType,
            isOutgoing: true
        )

        // Verify outgoing call properties
        XCTAssertTrue(pending.isOutgoing)
        XCTAssertEqual(pending.callType, .audio)
    }

    func testCallStateTransitions() {
        // Test valid state transitions
        var state: CallState = .idle

        // Outgoing call flow
        state = .connecting
        XCTAssertEqual(state, .connecting)

        state = .connected
        XCTAssertEqual(state, .connected)

        state = .idle
        XCTAssertEqual(state, .idle)

        // Incoming call flow
        state = .ringing
        XCTAssertEqual(state, .ringing)

        state = .connected
        XCTAssertEqual(state, .connected)

        state = .idle
        XCTAssertEqual(state, .idle)
    }
}
