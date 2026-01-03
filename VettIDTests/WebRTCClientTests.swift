import XCTest
@testable import VettID

/// Tests for WebRTC client functionality
final class WebRTCClientTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = WebRTCConfiguration.default

        XCTAssertTrue(config.enableAudio)
        XCTAssertTrue(config.enableVideo)
        XCTAssertEqual(config.videoCodec, .vp8)
        XCTAssertEqual(config.audioCodec, .opus)
        XCTAssertFalse(config.iceServers.isEmpty)
    }

    func testDefaultIceServers() {
        let config = WebRTCConfiguration.default

        // Should have STUN servers
        XCTAssertGreaterThanOrEqual(config.iceServers.count, 2)

        let firstServer = config.iceServers[0]
        XCTAssertTrue(firstServer.urls.first?.contains("stun") ?? false)
    }

    func testConfigurationWithTurnServers() {
        let turnUrls = ["turn:turn.example.com:3478"]
        let config = WebRTCConfiguration.withTurnServers(
            turnUrls: turnUrls,
            username: "testuser",
            credential: "testpass"
        )

        // Should have default STUN + custom TURN
        XCTAssertGreaterThan(config.iceServers.count, 2)

        // Find TURN server
        let turnServer = config.iceServers.first { server in
            server.urls.first?.contains("turn") ?? false
        }
        XCTAssertNotNil(turnServer)
        XCTAssertEqual(turnServer?.username, "testuser")
        XCTAssertEqual(turnServer?.credential, "testpass")
    }

    // MARK: - IceServer Tests

    func testIceServerWithoutCredentials() {
        let server = IceServer(urls: ["stun:stun.example.com"])

        XCTAssertEqual(server.urls.count, 1)
        XCTAssertNil(server.username)
        XCTAssertNil(server.credential)
    }

    func testIceServerWithCredentials() {
        let server = IceServer(
            urls: ["turn:turn.example.com:3478"],
            username: "user",
            credential: "pass"
        )

        XCTAssertEqual(server.username, "user")
        XCTAssertEqual(server.credential, "pass")
    }

    // MARK: - SessionDescription Tests

    func testSessionDescriptionOffer() {
        let sdp = SessionDescription(type: .offer, sdp: "v=0\r\no=- 123 2 IN IP4 127.0.0.1")

        XCTAssertEqual(sdp.type, .offer)
        XCTAssertTrue(sdp.sdp.contains("v=0"))
    }

    func testSessionDescriptionAnswer() {
        let sdp = SessionDescription(type: .answer, sdp: "v=0\r\no=- 456 2 IN IP4 127.0.0.1")

        XCTAssertEqual(sdp.type, .answer)
    }

    func testSessionDescriptionCodable() throws {
        let original = SessionDescription(type: .offer, sdp: "test sdp content")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionDescription.self, from: encoded)

        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.sdp, original.sdp)
    }

    // MARK: - IceCandidate Tests

    func testIceCandidateCreation() {
        let candidate = IceCandidate(
            candidate: "candidate:1 1 UDP 2130706431 192.168.1.1 54321 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )

        XCTAssertTrue(candidate.candidate.contains("UDP"))
        XCTAssertEqual(candidate.sdpMid, "0")
        XCTAssertEqual(candidate.sdpMLineIndex, 0)
    }

    func testIceCandidateCodable() throws {
        let original = IceCandidate(
            candidate: "candidate:1 1 UDP 2130706431 10.0.0.1 12345 typ host",
            sdpMid: "audio",
            sdpMLineIndex: 1
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IceCandidate.self, from: encoded)

        XCTAssertEqual(decoded.candidate, original.candidate)
        XCTAssertEqual(decoded.sdpMid, original.sdpMid)
        XCTAssertEqual(decoded.sdpMLineIndex, original.sdpMLineIndex)
    }

    func testIceCandidateCodingKeys() throws {
        // Test that JSON uses snake_case keys
        let candidate = IceCandidate(
            candidate: "test",
            sdpMid: "0",
            sdpMLineIndex: 0
        )

        let data = try JSONEncoder().encode(candidate)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("sdp_mid"))
        XCTAssertTrue(json.contains("sdp_m_line_index"))
    }

    // MARK: - Connection State Tests

    func testConnectionStates() {
        XCTAssertEqual(WebRTCConnectionState.new.rawValue, "new")
        XCTAssertEqual(WebRTCConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(WebRTCConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(WebRTCConnectionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(WebRTCConnectionState.failed.rawValue, "failed")
        XCTAssertEqual(WebRTCConnectionState.closed.rawValue, "closed")
    }

    // MARK: - Codec Tests

    func testVideoCodecs() {
        XCTAssertEqual(VideoCodec.vp8.rawValue, "VP8")
        XCTAssertEqual(VideoCodec.vp9.rawValue, "VP9")
        XCTAssertEqual(VideoCodec.h264.rawValue, "H264")
    }

    func testAudioCodecs() {
        XCTAssertEqual(AudioCodec.opus.rawValue, "opus")
        XCTAssertEqual(AudioCodec.isac.rawValue, "ISAC")
        XCTAssertEqual(AudioCodec.g722.rawValue, "G722")
    }

    // MARK: - Error Tests

    func testWebRTCErrorDescriptions() {
        let errors: [WebRTCError] = [
            .notInitialized,
            .noRemoteDescription,
            .peerConnectionFailed("test reason"),
            .mediaAccessDenied,
            .offerCreationFailed("offer reason"),
            .answerCreationFailed("answer reason"),
            .iceCandidateFailed("ice reason")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testWebRTCErrorPeerConnectionFailed() {
        let error = WebRTCError.peerConnectionFailed("network error")
        XCTAssertTrue(error.errorDescription!.contains("network error"))
    }

    func testWebRTCErrorOfferCreationFailed() {
        let error = WebRTCError.offerCreationFailed("timeout")
        XCTAssertTrue(error.errorDescription!.contains("timeout"))
    }

    // MARK: - CallStatistics Tests

    func testCallStatisticsCreation() {
        let stats = CallStatistics(
            bytesReceived: 1024,
            bytesSent: 2048,
            packetsReceived: 100,
            packetsSent: 200,
            packetsLost: 5,
            roundTripTime: 0.05,
            jitter: 0.01,
            audioLevel: 0.8,
            frameWidth: 1280,
            frameHeight: 720,
            framesPerSecond: 30.0
        )

        XCTAssertEqual(stats.bytesReceived, 1024)
        XCTAssertEqual(stats.bytesSent, 2048)
        XCTAssertEqual(stats.packetsReceived, 100)
        XCTAssertEqual(stats.packetsSent, 200)
        XCTAssertEqual(stats.packetsLost, 5)
        XCTAssertEqual(stats.roundTripTime, 0.05, accuracy: 0.001)
        XCTAssertEqual(stats.jitter, 0.01, accuracy: 0.001)
        XCTAssertEqual(stats.audioLevel, 0.8, accuracy: 0.01)
        XCTAssertEqual(stats.frameWidth, 1280)
        XCTAssertEqual(stats.frameHeight, 720)
        XCTAssertEqual(stats.framesPerSecond ?? 0, 30.0, accuracy: 0.1)
    }

    func testCallStatisticsAudioOnly() {
        let stats = CallStatistics(
            bytesReceived: 512,
            bytesSent: 512,
            packetsReceived: 50,
            packetsSent: 50,
            packetsLost: 0,
            roundTripTime: 0.02,
            jitter: 0.005,
            audioLevel: 0.5,
            frameWidth: nil,
            frameHeight: nil,
            framesPerSecond: nil
        )

        XCTAssertNil(stats.frameWidth)
        XCTAssertNil(stats.frameHeight)
        XCTAssertNil(stats.framesPerSecond)
    }

    // MARK: - SDP Type Tests

    func testSdpTypes() {
        XCTAssertEqual(SessionDescription.SdpType.offer.rawValue, "offer")
        XCTAssertEqual(SessionDescription.SdpType.answer.rawValue, "answer")
        XCTAssertEqual(SessionDescription.SdpType.pranswer.rawValue, "pranswer")
        XCTAssertEqual(SessionDescription.SdpType.rollback.rawValue, "rollback")
    }
}

// MARK: - WebRTCClient Integration Tests

extension WebRTCClientTests {

    @MainActor
    func testWebRTCClientInitialState() {
        let client = WebRTCClient()

        XCTAssertEqual(client.connectionState, .new)
        XCTAssertTrue(client.isAudioEnabled)
        XCTAssertTrue(client.isVideoEnabled)
        XCTAssertFalse(client.isMuted)
        XCTAssertFalse(client.isSpeakerOn)
    }

    @MainActor
    func testWebRTCClientWithCustomConfig() {
        let config = WebRTCConfiguration.withTurnServers(
            turnUrls: ["turn:custom.turn.server"],
            username: "user",
            credential: "pass"
        )
        let client = WebRTCClient(configuration: config)

        XCTAssertEqual(client.connectionState, .new)
    }

    @MainActor
    func testSetAudioEnabled() {
        let client = WebRTCClient()

        client.setAudioEnabled(false)
        XCTAssertFalse(client.isAudioEnabled)
        XCTAssertTrue(client.isMuted)

        client.setAudioEnabled(true)
        XCTAssertTrue(client.isAudioEnabled)
        XCTAssertFalse(client.isMuted)
    }

    @MainActor
    func testSetVideoEnabled() {
        let client = WebRTCClient()

        client.setVideoEnabled(false)
        XCTAssertFalse(client.isVideoEnabled)

        client.setVideoEnabled(true)
        XCTAssertTrue(client.isVideoEnabled)
    }

    @MainActor
    func testCleanup() async {
        let client = WebRTCClient()

        // Setup first
        try? await client.setup()

        // Then cleanup
        client.cleanup()

        XCTAssertEqual(client.connectionState, .closed)
    }

    @MainActor
    func testGetVideoViews() {
        let client = WebRTCClient()

        // Without WebRTC framework, these return nil
        XCTAssertNil(client.getLocalVideoView())
        XCTAssertNil(client.getRemoteVideoView())
    }

    @MainActor
    func testGetStatistics() async {
        let client = WebRTCClient()

        // Without WebRTC framework, returns nil
        let stats = await client.getStatistics()
        XCTAssertNil(stats)
    }
}
