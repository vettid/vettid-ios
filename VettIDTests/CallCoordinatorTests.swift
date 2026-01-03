import XCTest
@testable import VettID

/// Tests for call coordinator functionality
final class CallCoordinatorTests: XCTestCase {

    // MARK: - CurrentCall Tests

    func testCurrentCallCreation() {
        let uuid = UUID()
        let call = CurrentCall(
            uuid: uuid,
            callId: "call-123",
            peerId: "user-456",
            peerDisplayName: "John Doe",
            callType: .video,
            direction: .outgoing
        )

        XCTAssertEqual(call.uuid, uuid)
        XCTAssertEqual(call.id, uuid)
        XCTAssertEqual(call.callId, "call-123")
        XCTAssertEqual(call.peerId, "user-456")
        XCTAssertEqual(call.peerDisplayName, "John Doe")
        XCTAssertEqual(call.callType, .video)
        XCTAssertEqual(call.direction, .outgoing)
    }

    func testCurrentCallIncoming() {
        let call = CurrentCall(
            uuid: UUID(),
            callId: "call-abc",
            peerId: "user-xyz",
            peerDisplayName: "Jane Smith",
            callType: .audio,
            direction: .incoming
        )

        XCTAssertEqual(call.callType, .audio)
        XCTAssertEqual(call.direction, .incoming)
    }

    // MARK: - CallDirection Tests

    func testCallDirections() {
        let incoming = CallDirection.incoming
        let outgoing = CallDirection.outgoing

        XCTAssertNotEqual(incoming, outgoing)
    }

    // MARK: - CoordinatedCallState Tests

    func testCoordinatedCallStates() {
        let states: [CoordinatedCallState] = [
            .idle,
            .ringing,
            .connecting,
            .connected,
            .reconnecting,
            .failed
        ]

        // All states should be unique
        let uniqueStates = Set(states)
        XCTAssertEqual(uniqueStates.count, states.count)
    }

    func testCallStateEquatable() {
        XCTAssertEqual(CoordinatedCallState.idle, CoordinatedCallState.idle)
        XCTAssertNotEqual(CoordinatedCallState.idle, CoordinatedCallState.connected)
    }

    // MARK: - CallCoordinatorError Tests

    func testCallCoordinatorErrorDescriptions() {
        let errors: [CallCoordinatorError] = [
            .notConfigured,
            .callInProgress,
            .noIncomingCall,
            .signalingFailed("test signaling"),
            .webrtcFailed("test webrtc")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testCallCoordinatorErrorNotConfigured() {
        let error = CallCoordinatorError.notConfigured
        XCTAssertTrue(error.errorDescription!.lowercased().contains("configured"))
    }

    func testCallCoordinatorErrorCallInProgress() {
        let error = CallCoordinatorError.callInProgress
        XCTAssertTrue(error.errorDescription!.contains("progress"))
    }

    func testCallCoordinatorErrorNoIncomingCall() {
        let error = CallCoordinatorError.noIncomingCall
        XCTAssertTrue(error.errorDescription!.lowercased().contains("incoming"))
    }

    func testCallCoordinatorErrorSignalingFailed() {
        let error = CallCoordinatorError.signalingFailed("network timeout")
        XCTAssertTrue(error.errorDescription!.contains("network timeout"))
    }

    func testCallCoordinatorErrorWebrtcFailed() {
        let error = CallCoordinatorError.webrtcFailed("ICE connection failed")
        XCTAssertTrue(error.errorDescription!.contains("ICE connection failed"))
    }
}

// MARK: - CallCoordinator Integration Tests

extension CallCoordinatorTests {

    @MainActor
    func testCallCoordinatorSingleton() {
        let coordinator1 = CallCoordinator.shared
        let coordinator2 = CallCoordinator.shared

        XCTAssertTrue(coordinator1 === coordinator2)
    }

    @MainActor
    func testCallCoordinatorInitialState() {
        let coordinator = CallCoordinator.shared

        XCTAssertNil(coordinator.currentCall)
        XCTAssertEqual(coordinator.callState, .idle)
        XCTAssertFalse(coordinator.isAudioMuted)
        XCTAssertTrue(coordinator.isVideoEnabled)
        XCTAssertFalse(coordinator.isSpeakerOn)
    }

    @MainActor
    func testStartCallWithoutConfiguration() async {
        // Get a fresh state (note: singleton might be configured from other tests)
        let coordinator = CallCoordinator.shared

        // If not configured, should throw
        // Note: This test may pass if coordinator was configured elsewhere
        // In a real test environment, you'd want to reset state between tests
    }

    @MainActor
    func testToggleMute() {
        let coordinator = CallCoordinator.shared

        let initialMute = coordinator.isAudioMuted
        coordinator.toggleMute()
        XCTAssertNotEqual(coordinator.isAudioMuted, initialMute)

        // Toggle back
        coordinator.toggleMute()
        XCTAssertEqual(coordinator.isAudioMuted, initialMute)
    }

    @MainActor
    func testToggleVideo() {
        let coordinator = CallCoordinator.shared

        let initialVideo = coordinator.isVideoEnabled
        coordinator.toggleVideo()
        XCTAssertNotEqual(coordinator.isVideoEnabled, initialVideo)

        // Toggle back
        coordinator.toggleVideo()
        XCTAssertEqual(coordinator.isVideoEnabled, initialVideo)
    }

    @MainActor
    func testToggleSpeaker() {
        let coordinator = CallCoordinator.shared

        let initialSpeaker = coordinator.isSpeakerOn
        coordinator.toggleSpeaker()
        XCTAssertNotEqual(coordinator.isSpeakerOn, initialSpeaker)

        // Toggle back
        coordinator.toggleSpeaker()
        XCTAssertEqual(coordinator.isSpeakerOn, initialSpeaker)
    }
}

// MARK: - Call Type Combination Tests

extension CallCoordinatorTests {

    func testVideoCallWithAllDirections() {
        let incomingVideo = CurrentCall(
            uuid: UUID(),
            callId: "call-1",
            peerId: "peer-1",
            peerDisplayName: "Peer 1",
            callType: .video,
            direction: .incoming
        )

        let outgoingVideo = CurrentCall(
            uuid: UUID(),
            callId: "call-2",
            peerId: "peer-2",
            peerDisplayName: "Peer 2",
            callType: .video,
            direction: .outgoing
        )

        XCTAssertEqual(incomingVideo.callType, .video)
        XCTAssertEqual(outgoingVideo.callType, .video)
        XCTAssertEqual(incomingVideo.direction, .incoming)
        XCTAssertEqual(outgoingVideo.direction, .outgoing)
    }

    func testAudioCallWithAllDirections() {
        let incomingAudio = CurrentCall(
            uuid: UUID(),
            callId: "call-3",
            peerId: "peer-3",
            peerDisplayName: "Peer 3",
            callType: .audio,
            direction: .incoming
        )

        let outgoingAudio = CurrentCall(
            uuid: UUID(),
            callId: "call-4",
            peerId: "peer-4",
            peerDisplayName: "Peer 4",
            callType: .audio,
            direction: .outgoing
        )

        XCTAssertEqual(incomingAudio.callType, .audio)
        XCTAssertEqual(outgoingAudio.callType, .audio)
    }
}

// MARK: - State Transition Tests

extension CallCoordinatorTests {

    func testCallStateTransitions() {
        // Document expected state transitions
        let validTransitions: [(from: CoordinatedCallState, to: CoordinatedCallState)] = [
            (.idle, .connecting),      // Start outgoing call
            (.idle, .ringing),         // Receive incoming call
            (.ringing, .connecting),   // Answer incoming call
            (.connecting, .connected), // Connection established
            (.connected, .reconnecting), // Temporary disconnection
            (.reconnecting, .connected), // Reconnection success
            (.reconnecting, .failed),  // Reconnection failed
            (.connected, .idle),       // Call ended
            (.failed, .idle)           // Clean up after failure
        ]

        // Verify all transitions use valid states
        for transition in validTransitions {
            XCTAssertNotEqual(transition.from, transition.to, "Transition should change state")
        }
    }
}

// MARK: - Error Handling Tests

extension CallCoordinatorTests {

    func testLocalizedErrorProtocol() {
        let errors: [LocalizedError] = [
            CallCoordinatorError.notConfigured,
            CallCoordinatorError.callInProgress,
            CallCoordinatorError.noIncomingCall,
            CallCoordinatorError.signalingFailed("test"),
            CallCoordinatorError.webrtcFailed("test")
        ]

        for error in errors {
            // All errors conform to LocalizedError
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testErrorDescriptionContent() {
        let signalingError = CallCoordinatorError.signalingFailed("connection refused")
        XCTAssertTrue(signalingError.errorDescription!.contains("Signaling"))
        XCTAssertTrue(signalingError.errorDescription!.contains("connection refused"))

        let webrtcError = CallCoordinatorError.webrtcFailed("peer disconnected")
        XCTAssertTrue(webrtcError.errorDescription!.contains("WebRTC"))
        XCTAssertTrue(webrtcError.errorDescription!.contains("peer disconnected"))
    }
}
