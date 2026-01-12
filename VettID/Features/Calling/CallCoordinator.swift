import Foundation
import CallKit

/// Coordinates all calling components: CallKit, signaling, and WebRTC
///
/// This is the main entry point for making and receiving calls.
/// It integrates:
/// - CallKitManager: Native iOS call UI
/// - CallSignalingHandler: NATS-based signaling
/// - WebRTCClient: Audio/video streaming
/// - CallEventSubscriber: Incoming event handling
@MainActor
final class CallCoordinator: ObservableObject {

    // MARK: - Singleton

    static let shared = CallCoordinator()

    // MARK: - Published State

    @Published private(set) var currentCall: CurrentCall?
    @Published private(set) var callState: CoordinatedCallState = .idle
    @Published private(set) var isAudioMuted: Bool = false
    @Published private(set) var isVideoEnabled: Bool = true
    @Published private(set) var isSpeakerOn: Bool = false

    // MARK: - Components

    private var callKitManager: CallKitManager?
    private var signalingHandler: CallSignalingHandler?
    private var webRTCClient: WebRTCClient?
    private var eventSubscriber: CallEventSubscriber?

    // MARK: - State

    private var isConfigured = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure all calling components
    /// - Parameters:
    ///   - connectionManager: NATS connection manager
    ///   - vaultResponseHandler: Handler for vault responses
    ///   - ownUserGuid: Current user's GUID
    ///   - ownerSpaceId: User's OwnerSpace ID
    func configure(
        connectionManager: NatsConnectionManager,
        vaultResponseHandler: VaultResponseHandler,
        ownUserGuid: String,
        ownerSpaceId: String
    ) {
        guard !isConfigured else { return }

        // Create signaling handler
        let signaling = CallSignalingHandler(
            vaultResponseHandler: vaultResponseHandler,
            connectionManager: connectionManager,
            ownUserGuid: ownUserGuid
        )
        self.signalingHandler = signaling

        // Create WebRTC client
        let webrtc = WebRTCClient(configuration: .default)
        self.webRTCClient = webrtc

        // Configure CallKit
        let callKit = CallKitManager.shared
        callKit.configure(
            callSignalingHandler: signaling,
            onCallAnswered: { [weak self] activeCall in
                await self?.handleCallAnswered(activeCall)
            },
            onCallEnded: { [weak self] activeCall in
                await self?.handleCallEnded(activeCall)
            }
        )
        self.callKitManager = callKit

        // Create event subscriber
        let subscriber = CallEventSubscriber(
            connectionManager: connectionManager,
            callKitManager: callKit,
            ownerSpaceId: ownerSpaceId
        )
        self.eventSubscriber = subscriber

        // Wire up WebRTC callbacks
        setupWebRTCCallbacks()

        // Wire up event subscriber callbacks
        setupEventSubscriberCallbacks()

        isConfigured = true

        #if DEBUG
        print("[CallCoordinator] Configured successfully")
        #endif
    }

    /// Start listening for incoming calls
    func startListening() async {
        await eventSubscriber?.startListening()
    }

    /// Stop listening for incoming calls
    func stopListening() async {
        await eventSubscriber?.stopListening()
    }

    // MARK: - Outgoing Calls

    /// Start an outgoing call
    /// - Parameters:
    ///   - targetUserGuid: Target user's GUID
    ///   - displayName: Display name of the callee
    ///   - callType: Type of call (video/audio)
    func startCall(
        to targetUserGuid: String,
        displayName: String,
        callType: CallType = .video
    ) async throws {
        guard isConfigured else {
            throw CallCoordinatorError.notConfigured
        }

        guard currentCall == nil else {
            throw CallCoordinatorError.callInProgress
        }

        #if DEBUG
        print("[CallCoordinator] Starting \(callType.rawValue) call to: \(targetUserGuid)")
        #endif

        callState = .connecting

        // Start CallKit call
        guard let callKit = callKitManager else {
            throw CallCoordinatorError.notConfigured
        }

        let (uuid, callId) = try await callKit.startOutgoingCall(
            targetUserGuid: targetUserGuid,
            displayName: displayName,
            callType: callType
        )

        // Create current call
        currentCall = CurrentCall(
            uuid: uuid,
            callId: callId,
            peerId: targetUserGuid,
            peerDisplayName: displayName,
            callType: callType,
            direction: .outgoing
        )

        // Setup WebRTC
        try await webRTCClient?.setup()

        // Create and send offer
        if let offer = try await webRTCClient?.createOffer() {
            try await signalingHandler?.sendOffer(
                targetUserGuid: targetUserGuid,
                callId: callId,
                sdp: offer.sdp
            )
        }

        isVideoEnabled = callType == .video
    }

    /// Answer an incoming call
    func answerCall() async throws {
        guard let call = currentCall, call.direction == .incoming else {
            throw CallCoordinatorError.noIncomingCall
        }

        #if DEBUG
        print("[CallCoordinator] Answering call: \(call.callId)")
        #endif

        callState = .connecting

        // Setup WebRTC
        try await webRTCClient?.setup()

        // Create and send answer
        if let answer = try await webRTCClient?.createAnswer() {
            try await signalingHandler?.sendAnswer(
                targetUserGuid: call.peerId,
                callId: call.callId,
                sdp: answer.sdp
            )
        }

        callState = .connected
    }

    /// End the current call
    func endCall() async throws {
        guard let call = currentCall else {
            return // No call to end
        }

        #if DEBUG
        print("[CallCoordinator] Ending call: \(call.callId)")
        #endif

        // End via CallKit
        if let callKit = callKitManager {
            try await callKit.endCall(uuid: call.uuid)
        }

        // Send end signal
        try await signalingHandler?.endCall(
            peerUserGuid: call.peerId,
            callId: call.callId
        )

        // Cleanup
        await cleanupCall()
    }

    /// Reject an incoming call
    func rejectCall(reason: CallRejectReason = .declined) async throws {
        guard let call = currentCall, call.direction == .incoming else {
            throw CallCoordinatorError.noIncomingCall
        }

        #if DEBUG
        print("[CallCoordinator] Rejecting call: \(call.callId)")
        #endif

        // Reject via signaling
        try await signalingHandler?.rejectCall(
            callerUserGuid: call.peerId,
            callId: call.callId,
            reason: reason
        )

        // End via CallKit
        if let callKit = callKitManager {
            callKit.reportCallEnded(uuid: call.uuid, reason: .declinedElsewhere)
        }

        // Cleanup
        await cleanupCall()
    }

    // MARK: - Media Controls

    /// Toggle audio mute
    func toggleMute() {
        isAudioMuted.toggle()
        webRTCClient?.setAudioEnabled(!isAudioMuted)
    }

    /// Toggle video
    func toggleVideo() {
        isVideoEnabled.toggle()
        webRTCClient?.setVideoEnabled(isVideoEnabled)
    }

    /// Toggle speaker
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        webRTCClient?.setSpeakerEnabled(isSpeakerOn)
    }

    /// Switch camera (front/back)
    func switchCamera() {
        webRTCClient?.switchCamera()
    }

    // MARK: - Private Methods

    private func setupWebRTCCallbacks() {
        webRTCClient?.onLocalSdpGenerated = { [weak self] sdp in
            await self?.handleLocalSdp(sdp)
        }

        webRTCClient?.onIceCandidateGenerated = { [weak self] candidate in
            await self?.handleLocalIceCandidate(candidate)
        }

        webRTCClient?.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateChange(state)
            }
        }
    }

    private func setupEventSubscriberCallbacks() {
        guard let subscriber = eventSubscriber else { return }

        Task {
            await subscriber.setOnSdpOffer { [weak self] sdp in
                await self?.handleRemoteSdpOffer(sdp)
            }

            await subscriber.setOnSdpAnswer { [weak self] sdp in
                await self?.handleRemoteSdpAnswer(sdp)
            }

            await subscriber.setOnIceCandidate { [weak self] candidate in
                await self?.handleRemoteIceCandidate(candidate)
            }
        }
    }

    private func handleLocalSdp(_ sdp: SessionDescription) async {
        // SDP is sent when creating offer/answer, not here
    }

    private func handleLocalIceCandidate(_ candidate: IceCandidate) async {
        guard let call = currentCall else { return }

        do {
            try await signalingHandler?.sendCandidate(
                targetUserGuid: call.peerId,
                callId: call.callId,
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        } catch {
            #if DEBUG
            print("[CallCoordinator] Failed to send ICE candidate: \(error)")
            #endif
        }
    }

    private func handleRemoteSdpOffer(_ sdp: CallSdp) async {
        // Incoming call with offer - create current call if not exists
        if currentCall == nil {
            currentCall = CurrentCall(
                uuid: UUID(),
                callId: sdp.callId,
                peerId: sdp.callerId,
                peerDisplayName: "Unknown", // Will be updated by CallKit
                callType: .video,
                direction: .incoming
            )
        }

        // Set remote description
        let sessionDesc = SessionDescription(type: .offer, sdp: sdp.sdp)
        try? await webRTCClient?.setRemoteDescription(sessionDesc)
    }

    private func handleRemoteSdpAnswer(_ sdp: CallSdp) async {
        // Set remote description
        let sessionDesc = SessionDescription(type: .answer, sdp: sdp.sdp)
        try? await webRTCClient?.setRemoteDescription(sessionDesc)

        // Call is now connected
        callState = .connected
        callKitManager?.reportCallConnected(uuid: currentCall?.uuid ?? UUID())
    }

    private func handleRemoteIceCandidate(_ candidate: CallCandidate) async {
        let iceCandidate = IceCandidate(
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        try? await webRTCClient?.addIceCandidate(iceCandidate)
    }

    private func handleConnectionStateChange(_ state: WebRTCConnectionState) {
        switch state {
        case .connected:
            callState = .connected
        case .disconnected:
            callState = .reconnecting
        case .failed:
            callState = .failed
            Task {
                try? await endCall()
            }
        case .closed:
            callState = .idle
        default:
            break
        }
    }

    private func handleCallAnswered(_ activeCall: ActiveCall) async {
        // Update current call with CallKit info
        currentCall = CurrentCall(
            uuid: activeCall.uuid,
            callId: activeCall.callId,
            peerId: activeCall.peerId,
            peerDisplayName: activeCall.peerDisplayName,
            callType: activeCall.callType,
            direction: activeCall.isOutgoing ? .outgoing : .incoming
        )

        callState = .connected
    }

    private func handleCallEnded(_ activeCall: ActiveCall) async {
        await cleanupCall()
    }

    private func cleanupCall() async {
        webRTCClient?.cleanup()
        currentCall = nil
        callState = .idle
        isAudioMuted = false
        isVideoEnabled = true
        isSpeakerOn = false
    }
}

// MARK: - Current Call

struct CurrentCall: Identifiable {
    let uuid: UUID
    let callId: String
    let peerId: String
    let peerDisplayName: String
    let callType: CallType
    let direction: CallDirection

    var id: UUID { uuid }
}

enum CallDirection {
    case incoming
    case outgoing
}

// MARK: - Coordinated Call State

enum CoordinatedCallState: Equatable {
    case idle
    case ringing
    case connecting
    case connected
    case reconnecting
    case failed
}

// MARK: - Errors

enum CallCoordinatorError: LocalizedError {
    case notConfigured
    case callInProgress
    case noIncomingCall
    case signalingFailed(String)
    case webrtcFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Call coordinator not configured"
        case .callInProgress:
            return "Another call is already in progress"
        case .noIncomingCall:
            return "No incoming call to answer"
        case .signalingFailed(let reason):
            return "Signaling failed: \(reason)"
        case .webrtcFailed(let reason):
            return "WebRTC failed: \(reason)"
        }
    }
}

// MARK: - Call Actions Extension

extension CallCoordinator {

    /// Block a user from calling
    func blockUser(_ userGuid: String, reason: String? = nil) async throws {
        guard let handler = signalingHandler else {
            throw CallCoordinatorError.notConfigured
        }
        _ = try await handler.blockUser(userGuid: userGuid, reason: reason)
    }

    /// Unblock a user
    func unblockUser(_ userGuid: String) async throws {
        guard let handler = signalingHandler else {
            throw CallCoordinatorError.notConfigured
        }
        _ = try await handler.unblockUser(userGuid: userGuid)
    }

    /// Get the block list
    func getBlockList() async throws -> [BlockedUser] {
        guard let handler = signalingHandler else {
            throw CallCoordinatorError.notConfigured
        }
        return try await handler.getBlockList()
    }
}
