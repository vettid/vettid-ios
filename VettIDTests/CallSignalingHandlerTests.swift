import XCTest
@testable import VettID

/// Tests for CallSignalingHandler
final class CallSignalingHandlerTests: XCTestCase {

    // MARK: - CallType Tests

    func testCallTypeRawValues() {
        XCTAssertEqual(CallType.video.rawValue, "video")
        XCTAssertEqual(CallType.audio.rawValue, "audio")
    }

    func testCallTypeCodable() throws {
        // Encode
        let encoder = JSONEncoder()
        let videoData = try encoder.encode(CallType.video)
        let audioData = try encoder.encode(CallType.audio)

        // Decode
        let decoder = JSONDecoder()
        let decodedVideo = try decoder.decode(CallType.self, from: videoData)
        let decodedAudio = try decoder.decode(CallType.self, from: audioData)

        XCTAssertEqual(decodedVideo, .video)
        XCTAssertEqual(decodedAudio, .audio)
    }

    // MARK: - CallRejectReason Tests

    func testCallRejectReasonRawValues() {
        XCTAssertEqual(CallRejectReason.declined.rawValue, "declined")
        XCTAssertEqual(CallRejectReason.busy.rawValue, "busy")
        XCTAssertEqual(CallRejectReason.unavailable.rawValue, "unavailable")
    }

    // MARK: - IncomingCall Tests

    func testIncomingCallDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "caller_display_name": "John Doe",
            "call_type": "video",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let call = try decoder.decode(IncomingCall.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(call.callId, "call-123")
        XCTAssertEqual(call.callerId, "user-abc")
        XCTAssertEqual(call.callerDisplayName, "John Doe")
        XCTAssertEqual(call.callType, .video)
        XCTAssertEqual(call.timestamp, 1704067200000)
    }

    func testIncomingCallDecodingAudioCall() throws {
        let json = """
        {
            "call_id": "call-456",
            "caller_id": "user-xyz",
            "caller_display_name": "Jane Smith",
            "call_type": "audio",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let call = try decoder.decode(IncomingCall.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(call.callType, .audio)
    }

    // MARK: - CallSdp Tests

    func testCallSdpDecodingOffer() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "sdp": "v=0\\no=- 12345 2 IN IP4 127.0.0.1\\ns=-\\nt=0 0",
            "type": "offer",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let sdp = try decoder.decode(CallSdp.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(sdp.callId, "call-123")
        XCTAssertEqual(sdp.callerId, "user-abc")
        XCTAssertEqual(sdp.type, "offer")
        XCTAssertTrue(sdp.sdp.contains("v=0"))
    }

    func testCallSdpDecodingAnswer() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "sdp": "v=0\\no=- 67890 2 IN IP4 127.0.0.1\\ns=-\\nt=0 0",
            "type": "answer",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let sdp = try decoder.decode(CallSdp.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(sdp.type, "answer")
    }

    // MARK: - CallCandidate Tests

    func testCallCandidateDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "candidate": "candidate:1 1 UDP 2122252543 192.168.1.1 54321 typ host",
            "sdp_mid": "audio",
            "sdp_m_line_index": 0,
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let candidate = try decoder.decode(CallCandidate.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(candidate.callId, "call-123")
        XCTAssertEqual(candidate.candidate, "candidate:1 1 UDP 2122252543 192.168.1.1 54321 typ host")
        XCTAssertEqual(candidate.sdpMid, "audio")
        XCTAssertEqual(candidate.sdpMLineIndex, 0)
    }

    func testCallCandidateDecodingWithoutOptionals() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "candidate": "candidate:1 1 UDP 2122252543 192.168.1.1 54321 typ host",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let candidate = try decoder.decode(CallCandidate.self, from: json.data(using: .utf8)!)

        XCTAssertNil(candidate.sdpMid)
        XCTAssertNil(candidate.sdpMLineIndex)
    }

    // MARK: - CallAccepted Tests

    func testCallAcceptedDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "responder_id": "user-xyz",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let accepted = try decoder.decode(CallAccepted.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(accepted.callId, "call-123")
        XCTAssertEqual(accepted.responderId, "user-xyz")
    }

    // MARK: - CallRejected Tests

    func testCallRejectedDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "responder_id": "user-xyz",
            "reason": "busy",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let rejected = try decoder.decode(CallRejected.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(rejected.callId, "call-123")
        XCTAssertEqual(rejected.responderId, "user-xyz")
        XCTAssertEqual(rejected.reason, "busy")
    }

    // MARK: - CallEnded Tests

    func testCallEndedDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "ended_by": "user-abc",
            "timestamp": 1704067200000,
            "duration": 125.5
        }
        """

        let decoder = JSONDecoder()
        let ended = try decoder.decode(CallEnded.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(ended.callId, "call-123")
        XCTAssertEqual(ended.endedBy, "user-abc")
        XCTAssertEqual(ended.duration, 125.5)
    }

    func testCallEndedDecodingWithoutDuration() throws {
        let json = """
        {
            "call_id": "call-123",
            "ended_by": "user-abc",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let ended = try decoder.decode(CallEnded.self, from: json.data(using: .utf8)!)

        XCTAssertNil(ended.duration)
    }

    // MARK: - CallMissed Tests

    func testCallMissedDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "caller_id": "user-abc",
            "caller_display_name": "John Doe",
            "call_type": "video",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let missed = try decoder.decode(CallMissed.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(missed.callId, "call-123")
        XCTAssertEqual(missed.callerId, "user-abc")
        XCTAssertEqual(missed.callerDisplayName, "John Doe")
        XCTAssertEqual(missed.callType, .video)
    }

    // MARK: - CallBlocked Tests

    func testCallBlockedDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "target_id": "user-xyz",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let blocked = try decoder.decode(CallBlocked.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(blocked.callId, "call-123")
        XCTAssertEqual(blocked.targetId, "user-xyz")
    }

    // MARK: - CallBusy Tests

    func testCallBusyDecoding() throws {
        let json = """
        {
            "call_id": "call-123",
            "target_id": "user-xyz",
            "timestamp": 1704067200000
        }
        """

        let decoder = JSONDecoder()
        let busy = try decoder.decode(CallBusy.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(busy.callId, "call-123")
        XCTAssertEqual(busy.targetId, "user-xyz")
    }

    // MARK: - CallInitiationResult Tests

    func testCallInitiationResultCreation() {
        let result = CallInitiationResult(
            callId: "call-123",
            targetUserGuid: "user-xyz",
            callType: .video,
            timestamp: Date()
        )

        XCTAssertEqual(result.callId, "call-123")
        XCTAssertEqual(result.targetUserGuid, "user-xyz")
        XCTAssertEqual(result.callType, .video)
    }

    // MARK: - BlockResult Tests

    func testBlockResultCreation() {
        let result = BlockResult(
            targetId: "user-xyz",
            blockedAt: "2024-01-01T12:00:00Z",
            expiresAt: nil
        )

        XCTAssertEqual(result.targetId, "user-xyz")
        XCTAssertEqual(result.blockedAt, "2024-01-01T12:00:00Z")
        XCTAssertNil(result.expiresAt)
    }

    func testBlockResultWithExpiration() {
        let result = BlockResult(
            targetId: "user-xyz",
            blockedAt: "2024-01-01T12:00:00Z",
            expiresAt: "2024-01-02T12:00:00Z"
        )

        XCTAssertEqual(result.expiresAt, "2024-01-02T12:00:00Z")
    }

    // MARK: - BlockedUser Tests

    func testBlockedUserCreation() {
        let user = BlockedUser(
            targetId: "user-xyz",
            reason: "spam",
            blockedAt: "2024-01-01T12:00:00Z",
            expiresAt: nil
        )

        XCTAssertEqual(user.targetId, "user-xyz")
        XCTAssertEqual(user.reason, "spam")
        XCTAssertNil(user.expiresAt)
    }

    // MARK: - Error Description Tests

    func testCallSignalingErrorDescriptions() {
        let errors: [CallSignalingError] = [
            .notConnected,
            .callInitiationFailed("test reason"),
            .signalingFailed("test reason"),
            .blockFailed("test reason"),
            .unblockFailed("test reason"),
            .blockListFailed("test reason"),
            .invalidResponse
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testCallInitiationFailedErrorContainsReason() {
        let error = CallSignalingError.callInitiationFailed("network timeout")
        XCTAssertTrue(error.errorDescription!.contains("network timeout"))
    }

    func testBlockFailedErrorContainsReason() {
        let error = CallSignalingError.blockFailed("user not found")
        XCTAssertTrue(error.errorDescription!.contains("user not found"))
    }
}

// MARK: - CallEvent Tests

extension CallSignalingHandlerTests {

    func testCallEventEnumCases() {
        // Test each case can be created
        let incoming = IncomingCall(
            callId: "1",
            callerId: "user",
            callerDisplayName: "User",
            callType: .video,
            timestamp: 0
        )
        let sdp = CallSdp(callId: "1", callerId: "user", sdp: "sdp", type: "offer", timestamp: 0)
        let candidate = CallCandidate(
            callId: "1",
            callerId: "user",
            candidate: "candidate",
            sdpMid: nil,
            sdpMLineIndex: nil,
            timestamp: 0
        )
        let accepted = CallAccepted(callId: "1", responderId: "user", timestamp: 0)
        let rejected = CallRejected(callId: "1", responderId: "user", reason: "declined", timestamp: 0)
        let ended = CallEnded(callId: "1", endedBy: "user", timestamp: 0, duration: nil)
        let missed = CallMissed(
            callId: "1",
            callerId: "user",
            callerDisplayName: "User",
            callType: .audio,
            timestamp: 0
        )
        let blocked = CallBlocked(callId: "1", targetId: "user", timestamp: 0)
        let busy = CallBusy(callId: "1", targetId: "user", timestamp: 0)

        // Create CallEvent for each
        let events: [CallEvent] = [
            .incoming(incoming),
            .offer(sdp),
            .answer(sdp),
            .candidate(candidate),
            .accepted(accepted),
            .rejected(rejected),
            .ended(ended),
            .missed(missed),
            .blocked(blocked),
            .busy(busy)
        ]

        XCTAssertEqual(events.count, 10)
    }
}
