import Foundation
import VettIDCalls
import VettIDCrypto
import VettIDVault
@preconcurrency import WebRTC

/// ``MediaEngine`` on libwebrtc (webrtc-sdk 150.7871.04) with its frame cryptor: one audio-only (Opus) peer connection whose
/// sender and receiver each carry a frame cryptor, enabled before any SDP is applied, keyed per direction (CALL-MEDIA §4, §7;
/// vettid-android `WebRtcMediaEngine`).
///
/// Everything of the stack is touched on one serial queue (``WebRtcRuntime/queue``, shared by every engine of the process,
/// like the factory and the audio device module). The engine never sees an address it does not pass on and keeps no key:
/// ``setKeys(_:send:receive:)`` hands the keys to the stack's key provider and wipes them.
///
/// The audio session (category, activation, routes) is not set here: it belongs to the call screen and CallKit, a later change.
@MainActor
public final class WebRtcMediaEngine: MediaEngine {
    /// What this media stack can do, in ``MediaSuite/preference`` order: AES-256-GCM and AES-128-GCM frames. The key
    /// provider takes the frame key's length since 150.7871.04 (webrtc-sdk/webrtc PR #302); ``FrameKeyOptions`` passes each
    /// suite's. What a call offers and chooses is this list cut down further by the call's form.
    public nonisolated static let supportedSuites: [MediaSuite] = [.aes256Gcm, .aes128Gcm]

    public let suites: [MediaSuite] = supportedSuites
    public let events: AsyncStream<MediaEvent>

    let core: WebRtcMediaCore
    private let channel: AsyncStream<MediaEvent>.Continuation
    private var closed = false

    init(config: MediaConfig, switches: any MediaLoggingSwitches = LiveLoggingSwitches()) {
        let (stream, continuation) = AsyncStream.makeStream(of: MediaEvent.self)
        events = stream
        channel = continuation
        core = WebRtcMediaCore(config: config, switches: switches) { continuation.yield($0) }
    }

    public func createOffer(suite: MediaSuite) async throws -> String {
        try open()
        try await core.onQueue { core in try core.openOffer(suite: suite) }
        return core.announced(try await core.offerDescription())
    }

    public func startGathering(servers: [CallWire.IceServer]) async throws {
        try open()
        try await core.startGathering(servers: servers)
    }

    public func acceptAnswer(sdp: String) async throws {
        try open()
        try await core.acceptAnswer(sdp: sdp)
    }

    public func acceptOffer(sdp: String, servers: [CallWire.IceServer], suite: MediaSuite) async throws -> String {
        try open()
        try await core.onQueue { core in try core.prepareAnswer(servers: servers, suite: suite) }
        try await core.setRemote(.offer, sdp: sdp)
        return core.announced(try await core.answerDescription())
    }

    public func setKeys(_ suite: MediaSuite, send: inout [UInt8], receive: inout [UInt8]) async throws {
        // The caller's arrays are wiped here, in their own buffers, before anything can fail or wait.
        let sendKey = SecretBytes(send)
        let receiveKey = SecretBytes(receive)
        Bytes.wipe(&send)
        Bytes.wipe(&receive)
        defer {
            sendKey.wipe()
            receiveKey.wipe()
        }
        try open()
        try await core.onQueue { core in try core.takeKeys(suite, send: sendKey, receive: receiveKey) }
    }

    public func addRemoteCandidates(_ candidates: [CallCandidate]) async throws {
        try open()
        try await core.onQueue { core in core.addRemoteCandidates(candidates) }
    }

    public func setMuted(_ muted: Bool) {
        guard !closed else { return }
        let core = core
        WebRtcRuntime.queue.async {
            core.wantMuted = muted
            core.applyTrackState()
        }
    }

    public func setHeld(_ held: Bool) {
        guard !closed else { return }
        let core = core
        WebRtcRuntime.queue.async {
            core.held = held
            core.applyTrackState()
        }
    }

    public func diagnostics() async -> MediaDiagnostics? {
        guard !closed, let entries = try? await core.statistics() else { return nil }
        var reading = MediaStatistics.diagnostics(from: entries)
        reading.sendCryptor = core.sendState.value
        reading.receiveCryptor = core.receiveState.value
        return reading
    }

    public func close() {
        guard !closed else { return }
        closed = true
        let core = core
        let channel = channel
        WebRtcRuntime.queue.async {
            core.teardown()
            channel.finish()
        }
    }

    private func open() throws {
        guard !closed else { throw MediaEngineError("the call's media is closed") }
    }
}

/// The engines of one process, on the one shared stack. Creating the first engine fixes the process-wide options.
@MainActor
public final class WebRtcMediaEngineFactory: MediaEngineFactory {
    private let testBuild: Bool

    /// [testBuild]: true only in the builds made for the two-phone tests, which may ask for a ``MediaConfig`` that breaks a
    /// rule on purpose or uses the experimental DTLS trial.
    public init(testBuild: Bool = false) { self.testBuild = testBuild }

    public var suites: [MediaSuite] { WebRtcMediaEngine.supportedSuites }

    public func create(config: MediaConfig) throws -> any MediaEngine {
        // The check next to the dangerous code: whatever asked, a build that was not made for the phone tests makes no engine
        // that breaks a rule on purpose or uses the experimental DTLS trial.
        guard testBuild || config.plain else { throw MediaEngineError("a test configuration in a build that is not a test build") }
        _ = try WebRtcRuntime.start(config)
        return WebRtcMediaEngine(config: config)
    }
}
