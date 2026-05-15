import Foundation
import AVFoundation
import WebRTC

// MARK: - WebRTC Client (Phase 4.1 — real media)
//
// SPM dep: https://github.com/stasel/WebRTC.git (v147.0.0, prebuilt Google
// WebRTC binary framework). The stub-replacement pass was Phase 4.1.
//
// Threading: the class is @MainActor for @Published mutation safety, but
// every RTCPeerConnectionDelegate method is marked `nonisolated` because
// WebRTC fires delegate callbacks off-main (its internal worker queue).
// Each delegate hop posts state via `Task { @MainActor in … }`.
//
// SSL init: WebRTC's TLS layer needs RTCInitializeSSL() once per process.
// `setupSSLOnce` covers that under a dispatch_once-equivalent.

/// WebRTC client for managing peer-to-peer audio/video connections.
@MainActor
final class WebRTCClient: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectionState: WebRTCConnectionState = .new
    @Published private(set) var isAudioEnabled: Bool = true
    @Published private(set) var isVideoEnabled: Bool = true
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var isSpeakerOn: Bool = false

    // MARK: - Configuration

    private let config: WebRTCConfiguration

    // MARK: - WebRTC Components

    private var peerConnection: RTCPeerConnection?
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var currentCameraPosition: AVCaptureDevice.Position = .front

    // MARK: - State

    private var pendingIceCandidates: [IceCandidate] = []
    private var hasRemoteDescription: Bool = false

    // MARK: - Callbacks

    var onLocalSdpGenerated: ((SessionDescription) async -> Void)?
    var onIceCandidateGenerated: ((IceCandidate) async -> Void)?
    var onConnectionStateChanged: ((WebRTCConnectionState) -> Void)?
    var onRemoteVideoTrackReceived: ((Any) -> Void)? // RTCVideoTrack

    // MARK: - One-time SSL init

    private static let sslOnce: Void = {
        RTCInitializeSSL()
    }()

    // MARK: - Initialization

    init(configuration: WebRTCConfiguration = .default) {
        self.config = configuration
        super.init()
    }

    deinit {
        // Don't touch peerConnection here — its close() may dispatch back
        // onto our queue. cleanup() must be called explicitly before
        // releasing the client (CallCoordinator does this).
    }

    // MARK: - Setup

    /// Initialize WebRTC components.
    func setup() async throws {
        _ = Self.sslOnce
        #if DEBUG
        print("[WebRTCClient] Setting up WebRTC peer connection…")
        #endif

        // Factory with the default audio/video encoder/decoder set.
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        self.peerConnectionFactory = factory

        // RTCConfiguration. Unified Plan is the modern SDP semantic;
        // legacy Plan B is dropped from WebRTC ~M93. Continual ICE
        // gathering keeps us nimble across network changes.
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = config.iceServers.map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls,
                                    username: username,
                                    credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.rtcpMuxPolicy = .require
        rtcConfig.tcpCandidatePolicy = .disabled

        // Mandatory DTLS-SRTP — never run a call without encrypted media.
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let pc = factory.peerConnection(with: rtcConfig,
                                              constraints: constraints,
                                              delegate: self) else {
            throw WebRTCError.peerConnectionFailed("factory returned nil")
        }
        self.peerConnection = pc

        // Configure RTCAudioSession for VoIP. CallKit lifts this — we
        // just set the category up front so AVAudioSession routing works
        // before CallKit's session activation.
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.lockForConfiguration()
        do {
            try rtcAudioSession.setCategory(
                AVAudioSession.Category.playAndRecord,
                with: [.allowBluetooth, .duckOthers]
            )
            try rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat)
        } catch {
            #if DEBUG
            print("[WebRTCClient] Audio session config failed: \(error)")
            #endif
        }
        rtcAudioSession.unlockForConfiguration()

        addLocalAudioTrack(factory: factory, pc: pc)
        if config.enableVideo {
            addLocalVideoTrack(factory: factory, pc: pc)
            try await startCameraCapture()
        }
    }

    /// Clean up WebRTC resources. Must be called before the client is
    /// released — see deinit note.
    func cleanup() {
        #if DEBUG
        print("[WebRTCClient] Cleaning up WebRTC…")
        #endif

        videoCapturer?.stopCapture()
        videoCapturer = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteAudioTrack = nil
        remoteVideoTrack = nil
        videoSource = nil
        peerConnection?.close()
        peerConnection = nil
        peerConnectionFactory = nil
        connectionState = .closed
        pendingIceCandidates.removeAll()
        hasRemoteDescription = false
    }

    // MARK: - Local tracks

    private func addLocalAudioTrack(factory: RTCPeerConnectionFactory,
                                    pc: RTCPeerConnection) {
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: audioSource, trackId: "audio0")
        track.isEnabled = config.enableAudio
        self.localAudioTrack = track
        pc.add(track, streamIds: ["stream0"])
    }

    private func addLocalVideoTrack(factory: RTCPeerConnectionFactory,
                                    pc: RTCPeerConnection) {
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = config.enableVideo
        self.videoSource = source
        self.localVideoTrack = track
        pc.add(track, streamIds: ["stream0"])
    }

    private func startCameraCapture() async throws {
        guard let source = videoSource else { return }
        let capturer = RTCCameraVideoCapturer(delegate: source)
        self.videoCapturer = capturer

        guard let device = AVCaptureDevice.devices(for: .video)
                .first(where: { $0.position == currentCameraPosition })
              ?? AVCaptureDevice.default(for: .video) else {
            #if DEBUG
            print("[WebRTCClient] No camera available")
            #endif
            return
        }

        // Pick the format with the largest dimensions ≤ 1280x720 to keep
        // bandwidth reasonable — WebRTC will downscale dynamically based
        // on network conditions anyway.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let target = CMVideoDimensions(width: 1280, height: 720)
        let withDims = formats.map { f -> (AVCaptureDevice.Format, CMVideoDimensions) in
            (f, CMVideoFormatDescriptionGetDimensions(f.formatDescription))
        }
        let candidates = withDims.filter { $0.1.width <= target.width && $0.1.height <= target.height }
        let best = candidates.max(by: { Int($0.1.width) * Int($0.1.height) < Int($1.1.width) * Int($1.1.height) })
        let bestFormat: AVCaptureDevice.Format? = best.map { $0.0 } ?? formats.first
        guard let format = bestFormat else { return }
        let fps = format.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }
            .max() ?? 30

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                capturer.startCapture(with: device, format: format, fps: min(fps, 30)) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[WebRTCClient] startCapture failed: \(error)")
            #endif
        }
    }

    // MARK: - Offer / Answer

    /// Create an SDP offer (caller side).
    func createOffer() async throws -> SessionDescription {
        guard let pc = peerConnection else { throw WebRTCError.notInitialized }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": config.enableVideo ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        let sdp = try await offer(pc: pc, constraints: constraints)
        try await setLocalDescription(pc: pc, sdp: sdp)
        return SessionDescription(from: sdp)
    }

    /// Create an SDP answer (callee side).
    func createAnswer() async throws -> SessionDescription {
        guard let pc = peerConnection else { throw WebRTCError.notInitialized }
        guard hasRemoteDescription else { throw WebRTCError.noRemoteDescription }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": config.enableVideo ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        let sdp = try await answer(pc: pc, constraints: constraints)
        try await setLocalDescription(pc: pc, sdp: sdp)
        return SessionDescription(from: sdp)
    }

    /// Set the remote SDP (received from peer).
    func setRemoteDescription(_ sdp: SessionDescription) async throws {
        guard let pc = peerConnection else { throw WebRTCError.notInitialized }
        let rtcSdp = RTCSessionDescription(type: sdp.type.rtcType, sdp: sdp.sdp)
        try await setRemoteDescription(pc: pc, sdp: rtcSdp)
        hasRemoteDescription = true

        // Flush queued ICE candidates that arrived before the SDP.
        for candidate in pendingIceCandidates {
            try? await addIceCandidate(candidate)
        }
        pendingIceCandidates.removeAll()
    }

    // MARK: - ICE Candidates

    /// Add an ICE candidate (received from peer).
    func addIceCandidate(_ candidate: IceCandidate) async throws {
        // Queue until remote description lands — RTCPeerConnection
        // rejects candidates before that.
        guard hasRemoteDescription else {
            pendingIceCandidates.append(candidate)
            return
        }
        guard let pc = peerConnection else { throw WebRTCError.notInitialized }
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.add(rtcCandidate) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Media Controls

    func setAudioEnabled(_ enabled: Bool) {
        isAudioEnabled = enabled
        isMuted = !enabled
        localAudioTrack?.isEnabled = enabled
    }

    func setVideoEnabled(_ enabled: Bool) {
        isVideoEnabled = enabled
        localVideoTrack?.isEnabled = enabled
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        isSpeakerOn = enabled

        // RTCAudioSession locks the underlying AVAudioSession; route the
        // override through it so WebRTC's audio I/O thread sees the
        // change atomically.
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            if enabled {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            #if DEBUG
            print("[WebRTCClient] Failed to set speaker: \(error)")
            #endif
        }
    }

    func switchCamera() {
        guard let capturer = videoCapturer else { return }
        currentCameraPosition = currentCameraPosition == .front ? .back : .front

        guard let device = AVCaptureDevice.devices(for: .video)
                .first(where: { $0.position == currentCameraPosition }) else {
            #if DEBUG
            print("[WebRTCClient] No camera at \(currentCameraPosition); reverting")
            #endif
            currentCameraPosition = currentCameraPosition == .front ? .back : .front
            return
        }

        capturer.stopCapture { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                let target = CMVideoDimensions(width: 1280, height: 720)
                let format = formats
                    .filter {
                        let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return d.width <= target.width && d.height <= target.height
                    }
                    .max(by: { a, b in
                        let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                        let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                        return da.width * da.height < db.width * db.height
                    }) ?? formats.first
                guard let format = format else { return }
                let fps = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? 30
                capturer.startCapture(with: device, format: format, fps: min(fps, 30)) { error in
                    #if DEBUG
                    if let error = error {
                        print("[WebRTCClient] switchCamera startCapture failed: \(error)")
                    }
                    #endif
                }
            }
        }
    }

    // MARK: - Video Views

    /// A Metal-rendered local-camera preview. Caller owns the returned view.
    func getLocalVideoView() -> Any? {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        localVideoTrack?.add(view)
        return view
    }

    /// A Metal-rendered remote-track view. Returns nil until the remote
    /// track lands via the delegate.
    func getRemoteVideoView() -> Any? {
        guard let remote = remoteVideoTrack else { return nil }
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        remote.add(view)
        return view
    }

    // MARK: - Statistics

    func getStatistics() async -> CallStatistics? {
        guard let pc = peerConnection else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<CallStatistics?, Never>) in
            pc.statistics { report in
                cont.resume(returning: CallStatistics(from: report))
            }
        }
    }

    // MARK: - Continuation wrappers (delegate-style → async)

    private func offer(pc: RTCPeerConnection,
                       constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let error = error {
                    cont.resume(throwing: WebRTCError.offerCreationFailed(error.localizedDescription))
                } else if let sdp = sdp {
                    cont.resume(returning: sdp)
                } else {
                    cont.resume(throwing: WebRTCError.offerCreationFailed("nil sdp"))
                }
            }
        }
    }

    private func answer(pc: RTCPeerConnection,
                        constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.answer(for: constraints) { sdp, error in
                if let error = error {
                    cont.resume(throwing: WebRTCError.answerCreationFailed(error.localizedDescription))
                } else if let sdp = sdp {
                    cont.resume(returning: sdp)
                } else {
                    cont.resume(throwing: WebRTCError.answerCreationFailed("nil sdp"))
                }
            }
        }
    }

    private func setLocalDescription(pc: RTCPeerConnection,
                                     sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func setRemoteDescription(pc: RTCPeerConnection,
                                      sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate
//
// Delegate methods fire on WebRTC's signaling/network worker queues,
// NOT on the main actor. Every method is marked `nonisolated` and hops
// to @MainActor before touching @Published state or invoking callbacks.

extension WebRTCClient: RTCPeerConnectionDelegate {

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange stateChanged: RTCSignalingState) {
        #if DEBUG
        print("[WebRTCClient] Signaling state: \(stateChanged)")
        #endif
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didAdd stream: RTCMediaStream) {
        // Plan B path — not used in unified-plan mode but iOS WebRTC
        // still emits the legacy callback for compatibility.
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceConnectionState) {
        let mapped: WebRTCConnectionState = {
            switch newState {
            case .new:          return .new
            case .checking, .count: return .connecting
            case .connected, .completed: return .connected
            case .disconnected: return .disconnected
            case .failed:       return .failed
            case .closed:       return .closed
            @unknown default:   return .new
            }
        }()
        Task { @MainActor in
            self.connectionState = mapped
            self.onConnectionStateChanged?(mapped)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceGatheringState) {
        #if DEBUG
        print("[WebRTCClient] ICE gathering: \(newState.rawValue)")
        #endif
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didGenerate candidate: RTCIceCandidate) {
        let mapped = IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        Task { @MainActor in
            await self.onIceCandidateGenerated?(mapped)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didOpen dataChannel: RTCDataChannel) {}

    // Unified-plan: receivers are added rather than streams. The remote
    // track lands here — capture audio/video refs and pass through the
    // remote-video callback so the UI can attach it to an RTCMTLVideoView.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didAdd rtpReceiver: RTCRtpReceiver,
                                    streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        Task { @MainActor in
            if let video = track as? RTCVideoTrack {
                self.remoteVideoTrack = video
                self.onRemoteVideoTrackReceived?(video)
            } else if let audio = track as? RTCAudioTrack {
                self.remoteAudioTrack = audio
            }
        }
    }
}

// MARK: - Configuration

struct WebRTCConfiguration {
    let iceServers: [IceServer]
    let enableAudio: Bool
    let enableVideo: Bool
    let videoCodec: VideoCodec
    let audioCodec: AudioCodec

    static let `default` = WebRTCConfiguration(
        iceServers: [
            IceServer(urls: ["stun:stun.l.google.com:19302"]),
            IceServer(urls: ["stun:stun1.l.google.com:19302"])
        ],
        enableAudio: true,
        enableVideo: true,
        videoCodec: .vp8,
        audioCodec: .opus
    )

    /// Configuration with custom TURN servers
    static func withTurnServers(
        turnUrls: [String],
        username: String,
        credential: String
    ) -> WebRTCConfiguration {
        var servers = WebRTCConfiguration.default.iceServers
        servers.append(IceServer(
            urls: turnUrls,
            username: username,
            credential: credential
        ))
        return WebRTCConfiguration(
            iceServers: servers,
            enableAudio: true,
            enableVideo: true,
            videoCodec: .vp8,
            audioCodec: .opus
        )
    }
}

struct IceServer {
    let urls: [String]
    let username: String?
    let credential: String?

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

enum VideoCodec: String {
    case vp8 = "VP8"
    case vp9 = "VP9"
    case h264 = "H264"
}

enum AudioCodec: String {
    case opus = "opus"
    case isac = "ISAC"
    case g722 = "G722"
}

// MARK: - Connection State

enum WebRTCConnectionState: String {
    case new = "new"
    case connecting = "connecting"
    case connected = "connected"
    case disconnected = "disconnected"
    case failed = "failed"
    case closed = "closed"
}

// MARK: - Session Description

struct SessionDescription: Codable {
    let type: SdpType
    let sdp: String

    enum SdpType: String, Codable {
        case offer
        case answer
        case pranswer
        case rollback

        var rtcType: RTCSdpType {
            switch self {
            case .offer:    return .offer
            case .answer:   return .answer
            case .pranswer: return .prAnswer
            case .rollback: return .rollback
            }
        }
    }

    init(type: SdpType, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    /// Build from an RTCSessionDescription (delegate-layer → app-layer).
    init(from rtc: RTCSessionDescription) {
        switch rtc.type {
        case .offer:    self.type = .offer
        case .answer:   self.type = .answer
        case .prAnswer: self.type = .pranswer
        case .rollback: self.type = .rollback
        @unknown default: self.type = .offer
        }
        self.sdp = rtc.sdp
    }
}

// MARK: - ICE Candidate

struct IceCandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_m_line_index"
    }
}

// MARK: - Call Statistics

struct CallStatistics {
    let bytesReceived: UInt64
    let bytesSent: UInt64
    let packetsReceived: UInt64
    let packetsSent: UInt64
    let packetsLost: UInt64
    let roundTripTime: Double
    let jitter: Double
    let audioLevel: Float
    let frameWidth: Int?
    let frameHeight: Int?
    let framesPerSecond: Double?

    /// Build from RTCStatisticsReport. RTCStatistics has a flat key/value
    /// shape per stat object; the call surface here pulls aggregate
    /// inbound+outbound numbers without breaking down per-stream.
    init?(from report: RTCStatisticsReport) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var pktsIn: UInt64 = 0
        var pktsOut: UInt64 = 0
        var pktsLost: UInt64 = 0
        var rtt: Double = 0
        var jitter: Double = 0
        var audioLvl: Float = 0
        var w: Int?
        var h: Int?
        var fps: Double?

        for (_, stat) in report.statistics {
            switch stat.type {
            case "inbound-rtp":
                bytesIn += UInt64(stat.values["bytesReceived"].flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0)
                pktsIn  += UInt64(stat.values["packetsReceived"].flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0)
                pktsLost += UInt64(stat.values["packetsLost"].flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0)
                if let j = stat.values["jitter"] as? NSNumber { jitter = j.doubleValue }
                if let lvl = stat.values["audioLevel"] as? NSNumber { audioLvl = lvl.floatValue }
                if let width = stat.values["frameWidth"] as? NSNumber { w = width.intValue }
                if let height = stat.values["frameHeight"] as? NSNumber { h = height.intValue }
                if let f = stat.values["framesPerSecond"] as? NSNumber { fps = f.doubleValue }
            case "outbound-rtp":
                bytesOut += UInt64(stat.values["bytesSent"].flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0)
                pktsOut  += UInt64(stat.values["packetsSent"].flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0)
            case "candidate-pair":
                if let nominated = stat.values["nominated"] as? Bool, nominated,
                   let r = stat.values["currentRoundTripTime"] as? NSNumber {
                    rtt = r.doubleValue
                }
            default:
                break
            }
        }

        self.bytesReceived = bytesIn
        self.bytesSent = bytesOut
        self.packetsReceived = pktsIn
        self.packetsSent = pktsOut
        self.packetsLost = pktsLost
        self.roundTripTime = rtt
        self.jitter = jitter
        self.audioLevel = audioLvl
        self.frameWidth = w
        self.frameHeight = h
        self.framesPerSecond = fps
    }
}

// MARK: - Errors

enum WebRTCError: LocalizedError {
    case notInitialized
    case noRemoteDescription
    case peerConnectionFailed(String)
    case mediaAccessDenied
    case offerCreationFailed(String)
    case answerCreationFailed(String)
    case iceCandidateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WebRTC not initialized"
        case .noRemoteDescription:
            return "No remote description set"
        case .peerConnectionFailed(let reason):
            return "Peer connection failed: \(reason)"
        case .mediaAccessDenied:
            return "Camera or microphone access denied"
        case .offerCreationFailed(let reason):
            return "Failed to create offer: \(reason)"
        case .answerCreationFailed(let reason):
            return "Failed to create answer: \(reason)"
        case .iceCandidateFailed(let reason):
            return "Failed to add ICE candidate: \(reason)"
        }
    }
}
