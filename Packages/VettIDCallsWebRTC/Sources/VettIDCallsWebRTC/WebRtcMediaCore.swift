import Foundation
import VettIDCalls
import VettIDCrypto
import VettIDVault
@preconcurrency import WebRTC

/// Everything of one call that touches the media stack. Every member runs on ``WebRtcRuntime/queue`` (the one serial queue of
/// the stack), except the stack's own callbacks (the observers, the statistics and description completions): those run on the
/// stack's threads and only emit into the thread-safe event stream or resume a continuation. Once ``teardown()`` has run,
/// every body run through ``onQueue`` or ``onQueueAsync`` throws, so a call that races the close opens nothing.
/// ``WebRtcMediaEngine`` is the main-actor face of it. The core never sees an address it does
/// not pass on and keeps no key: ``setKeys`` hands the keys to the stack's key provider and wipes them.
final class WebRtcMediaCore: @unchecked Sendable {
    static let streamId = "vettid"
    static let trackId = "audio0"
    /// The frame cryptors' participant ids: one key per direction.
    static let sendId = "send"
    static let receiveId = "receive"

    let emit: @Sendable (MediaEvent) -> Void
    let faults: MediaFaults
    let relayOnly: Bool
    /// The stack's logging switches, asked before every key is set.
    let switches: any MediaLoggingSwitches

    // On the queue only.
    var connection: RTCPeerConnection?
    var source: RTCAudioSource?
    var track: RTCAudioTrack?
    var provider: RTCFrameCryptorKeyProvider?
    var installed: MediaSuite?
    var senderCryptor: RTCFrameCryptor?
    var receiverCryptor: RTCFrameCryptor?
    var senderObserver: CryptorObserver?
    var receiverObserver: CryptorObserver?
    var peerObserver: PeerObserver?
    /// The sender id of the transceiver that carries the cryptors. Transceiver objects are not kept: the stack hands out new
    /// wrappers at each look, so one is found again by this id.
    var senderId: String?
    var moved = false
    /// Set by ``teardown()`` on the queue: nothing is opened after it.
    var closed: Bool {
        get { closedFlag.value }
        set { closedFlag.value = newValue }
    }

    /// Readable from the stack's threads: an offer that completes after the teardown is not kept.
    let closedFlag = Guarded(false)
    /// Set when a receiver has reported a decryption failure: no key is set again (VAULT-MESSAGING §10.10).
    let everFailed = Guarded(false)
    var wantMuted = false
    var held = false

    /// Read by the statistics and written by the stack's thread.
    let pendingOffer = Guarded<RTCSessionDescription?>(nil)
    let sendState = Guarded(CryptorState.new)
    let receiveState = Guarded(CryptorState.new)

    init(config: MediaConfig, switches: any MediaLoggingSwitches, emit: @escaping @Sendable (MediaEvent) -> Void) {
        self.switches = switches
        faults = config.faults
        relayOnly = config.relayOnly
        self.emit = emit
    }

    // MARK: Offer and answer

    func openOffer(suite: MediaSuite) throws {
        try require(suite)
        let pc = try open(servers: [])
        let negotiation = RTCRtpTransceiverInit()
        negotiation.direction = .sendRecv
        negotiation.streamIds = [Self.streamId]
        guard let transceiver = pc.addTransceiver(with: try newTrack(), init: negotiation) else {
            throw MediaEngineError("the audio transceiver was refused")
        }
        try opusOnly(transceiver)
        try encrypt(transceiver, suite: suite)
    }

    func offerDescription() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let box = try await onQueueAsync { core, done in
            guard let pc = core.connection else { throw MediaEngineError("no offer") }
            pc.offer(for: constraints) { description, error in
                if let description, error == nil {
                    core.storeOffer(description)
                    done.resume(returning: description.sdp)
                } else {
                    done.resume(throwing: MediaEngineError("the description could not be made"))
                }
            }
        }
        return box
    }

    /// Keeps the offer the stack made, unless the call has been torn down meanwhile (the callback comes on the stack's thread).
    func storeOffer(_ description: RTCSessionDescription) {
        pendingOffer.update { if !closed { $0 = description } }
    }

    func startGathering(servers: [CallWire.IceServer]) async throws {
        try await onQueueAsync { core, done in
            guard let pc = core.connection, let offer = core.pendingOffer.value else { throw MediaEngineError("no offer") }
            if !servers.isEmpty, !pc.setConfiguration(core.configuration(servers: servers)) {
                throw MediaEngineError("servers refused")
            }
            pc.setLocalDescription(offer) { error in Self.finish(error, done) }
        }
    }

    func acceptAnswer(sdp: String) async throws {
        try await setRemote(.answer, sdp: sdp)
        try await onQueue { core in try core.requireAllMediaEncrypted() }
    }

    func prepareAnswer(servers: [CallWire.IceServer], suite: MediaSuite) throws {
        try require(suite)
        let pc = try open(servers: servers)
        // A sender with its track and a receiver exist before the offer is applied (the offer's audio section takes this
        // transceiver), so both cryptors are in place and enabled before any SDP.
        guard pc.add(try newTrack(), streamIds: [Self.streamId]) != nil,
              let transceiver = pc.transceivers.first(where: { $0.mediaType == .audio })
        else { throw MediaEngineError("the audio sender was refused") }
        try encrypt(transceiver, suite: suite)
    }

    /// With the offer applied: the checks, the answer, and the answer as the local description. Returns the answer's SDP.
    func answerDescription() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: RTCSessionDescription = try await onQueueAsync { core, done in
            guard let pc = core.connection else { throw MediaEngineError("no offer") }
            try core.adoptOfferedSection()
            try core.requireAllMediaEncrypted()
            pc.answer(for: constraints) { description, error in
                if let description, error == nil {
                    done.resume(returning: description)
                } else {
                    done.resume(throwing: MediaEngineError("the description could not be made"))
                }
            }
        }
        try await onQueueAsync { core, done in
            guard let pc = core.connection else { throw MediaEngineError("no offer") }
            pc.setLocalDescription(answer) { error in Self.finish(error, done) }
        }
        return answer.sdp
    }

    func setRemote(_ type: RTCSdpType, sdp: String) async throws {
        let text = faults.keepRemoteSsrc ? sdp : CallMedia.sdpWithoutSsrc(sdp)
        try await onQueueAsync { core, done in
            guard let pc = core.connection else { throw MediaEngineError("no offer") }
            // The stack's text may quote the SDP: only that it failed goes on.
            pc.setRemoteDescription(RTCSessionDescription(type: type, sdp: text)) { error in Self.finish(error, done) }
        }
    }

    /// This device's SDP as it is sent.
    func announced(_ sdp: String) -> String { faults.misstateOwnSsrc ? MediaFaultSdp.misstateSsrc(sdp) : sdp }

    private static func finish(_ error: Error?, _ done: CheckedContinuation<Void, Error>) {
        if error == nil {
            done.resume()
        } else {
            done.resume(throwing: MediaEngineError("the description was refused"))
        }
    }

    // MARK: The rest of a call

    func addRemoteCandidates(_ candidates: [CallCandidate]) {
        guard let pc = connection else { return }
        for candidate in candidates {
            let remote = RTCIceCandidate(
                sdp: candidate.candidate, sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0), sdpMid: candidate.sdpMid ?? ""
            )
            pc.add(remote) { _ in }
        }
    }

    /// The track sends only when it is neither muted nor held.
    func applyTrackState() { track?.isEnabled = !wantMuted && !held }

    func statistics() async throws -> [StatEntry]? {
        try await onQueueAsync { core, done in
            guard let pc = core.connection else {
                done.resume(returning: nil)
                return
            }
            pc.statistics { report in
                done.resume(returning: report.statistics.values.map(Self.entry))
            }
        }
    }

    private static func entry(_ stat: RTCStatistics) -> StatEntry {
        var members: [String: StatValue] = [:]
        for (key, value) in stat.values {
            if let text = value as? String {
                members[key] = .text(text)
            } else if let number = value as? NSNumber {
                members[key] = .number(number.doubleValue)
            }
        }
        return StatEntry(id: stat.id, type: stat.type, members: members)
    }

    /// Each step on its own: one that fails must not keep the microphone or the keys from being let go.
    func teardown() {
        closed = true
        connection?.close()
        senderCryptor = nil
        receiverCryptor = nil
        connection = nil
        track = nil
        source = nil
        provider = nil
        pendingOffer.update { $0 = nil }
        peerObserver = nil
        senderObserver = nil
        receiverObserver = nil
    }

    // MARK: Building blocks

    /// This call's configuration: the one place that builds it, so every use carries [relayOnly]. TURN ports are pruned by
    /// priority: once a relay allocation on a network is ready, the lower-priority ones on that network are released instead
    /// of being kept for the whole call, since the TURN server reserves capacity for each.
    func configuration(servers: [CallWire.IceServer]) -> RTCConfiguration {
        Self.configuration(servers: servers, relayOnly: relayOnly)
    }

    static func configuration(servers: [CallWire.IceServer], relayOnly: Bool) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = servers.map { server in
            if let user = server.username, let credential = server.credential {
                RTCIceServer(urlStrings: server.urls, username: user, credential: credential)
            } else {
                RTCIceServer(urlStrings: server.urls)
            }
        }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // Not gather-once: a round that completes before the phone's network has reported its addresses would be the only
        // round and the call would have none. Continual gathering gathers again when a network appears or changes.
        config.continualGatheringPolicy = .gatherContinually
        // ICE over TCP between two phones is of no use; relayed candidates (TURN over TCP or TLS) are not affected.
        config.tcpCandidatePolicy = .disabled
        config.shouldPruneTurnPorts = true
        // Test builds only: no host or server-reflexive candidate is gathered, so only a relayed path can connect.
        if relayOnly { config.iceTransportPolicy = .relay }
        return config
    }

    func require(_ suite: MediaSuite) throws {
        guard WebRtcMediaEngine.supportedSuites.contains(suite) else {
            throw MediaEngineError("suite \(suite.id) is not one this engine can do")
        }
    }

    func open(servers: [CallWire.IceServer]) throws -> RTCPeerConnection {
        guard !closed else { throw MediaEngineError("the call's media is closed") }
        guard connection == nil else { throw MediaEngineError("this engine already has a call") }
        let observer = PeerObserver(emit: emit)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = configuration(servers: servers)
        guard let pc = WebRtcRuntime.factory().peerConnection(with: config, constraints: constraints, delegate: observer) else {
            throw MediaEngineError("no peer connection")
        }
        peerObserver = observer
        connection = pc
        return pc
    }

    func newTrack() throws -> RTCAudioTrack {
        let factory = WebRtcRuntime.factory()
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        source = audioSource
        let made = factory.audioTrack(with: audioSource, trackId: Self.trackId)
        made.isEnabled = !wantMuted && !held
        track = made
        return made
    }

    /// Offers Opus alone: nothing else can be negotiated.
    private func opusOnly(_ transceiver: RTCRtpTransceiver) throws {
        let opus = WebRtcRuntime.factory().rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio).codecs
            .filter { $0.name.lowercased() == "opus" }
        guard !opus.isEmpty else { throw MediaEngineError("Opus is not available") }
        // The property's setter is the one that Swift can call (the header's error-returning variant imports with an unusable
        // error argument); it is marked deprecated, the read-back below is the check.
        transceiver.codecPreferences = opus
        let kept = transceiver.codecPreferences
        guard kept.count == opus.count, kept.allSatisfy({ $0.name.lowercased() == "opus" }) else {
            throw MediaEngineError("Opus is not available")
        }
    }

    /// Runs [body] on the stack's queue.
    func onQueue<Result: Sendable>(_ body: @escaping @Sendable (WebRtcMediaCore) throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            WebRtcRuntime.queue.async {
                do {
                    guard !self.closed else { throw MediaEngineError("the call's media is closed") }
                    continuation.resume(returning: try body(self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Starts something on the stack's queue that ends in a callback: [body] resumes [done] itself, or throws before it has.
    func onQueueAsync<Result: Sendable>(
        _ body: @escaping @Sendable (WebRtcMediaCore, CheckedContinuation<Result, Error>) throws -> Void
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            WebRtcRuntime.queue.async {
                do {
                    guard !self.closed else { throw MediaEngineError("the call's media is closed") }
                    try body(self, continuation)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
