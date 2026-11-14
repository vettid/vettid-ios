import Foundation
import Testing
import VettIDCalls
import VettIDCrypto
import VettIDVault
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// The audio device of the whole test process: installed before the first engine makes the process's factory.
enum TestStack {
    static let device = FakeAudioDevice()
    static let ready: Bool = {
        WebRtcRuntime.testAudioDevice = device
        // Gather on the loopback interface too (ignored by default): the loopback tests use it alone.
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        WebRtcRuntime.testFactoryOptions = options
        return true
    }()
}

/// What an engine said, kept for the test (events arrive on the stack's threads).
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [MediaEvent] = []

    func add(_ event: MediaEvent) { lock.withLock { all.append(event) } }

    var events: [MediaEvent] { lock.withLock { all } }

    var candidates: [CallCandidate] {
        events.compactMap { if case let .localCandidate(candidate) = $0 { candidate } else { nil } }
    }

    func states(_ direction: MediaDirection) -> [CryptorState] {
        events.compactMap { if case let .cryptor(who, state) = $0, who == direction { state } else { nil } }
    }

    /// Counts and states only: the events also hold candidate addresses.
    var summary: String {
        "\(events.count) events, send \(states(.send)), receive \(states(.receive))"
    }
}

/// Two engines in one process, connected the way a call connects them (createOffer, startGathering, acceptOffer, setKeys,
/// acceptAnswer) with the other side's SDP and candidates handed over directly: no network but this machine's own host
/// addresses, no vault, no hardware audio (the process's stack runs on ``FakeAudioDevice``).
@MainActor
final class LoopbackCall {
    let a: WebRtcMediaEngine
    let b: WebRtcMediaEngine
    let heardA = Heard()
    let heardB = Heard()
    var offer = ""
    var answer = ""
    private var tasks: [Task<Void, Never>] = []
    private var forwardedToB = 0
    private var forwardedToA = 0

    init(callerFaults: MediaFaults = MediaFaults(), calleeFaults: MediaFaults = MediaFaults()) throws {
        _ = TestStack.ready
        let factory = WebRtcMediaEngineFactory(testBuild: true)
        a = try #require(try factory.create(config: MediaConfig(faults: callerFaults)) as? WebRtcMediaEngine)
        b = try #require(try factory.create(config: MediaConfig(faults: calleeFaults)) as? WebRtcMediaEngine)
        for (engine, heard) in [(a, heardA), (b, heardB)] {
            let events = engine.events
            tasks.append(Task.detached { for await event in events { heard.add(event) } })
        }
    }

    /// The call as the two devices make it. The caller's cryptors are made for [suiteA], the callee's for [suiteB]; each
    /// sets its keys for the suite given in [keySuiteA] and [suiteB].
    func connect(suiteA: MediaSuite, suiteB: MediaSuite, keySuiteA: MediaSuite? = nil, kCaller: [UInt8], kCallee: [UInt8]) async throws {
        offer = try await a.createOffer(suite: suiteA)
        try await a.startGathering(servers: [])
        answer = try await b.acceptOffer(sdp: offer, servers: [], suite: suiteB)
        var sendB = kCallee, receiveB = kCaller
        try await b.setKeys(suiteB, send: &sendB, receive: &receiveB)
        var sendA = kCaller, receiveA = kCallee
        try await a.setKeys(keySuiteA ?? suiteA, send: &sendA, receive: &receiveA)
        try await a.acceptAnswer(sdp: answer)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.forwardCandidates()
                try? await Task.sleep(for: .milliseconds(50))
            }
        })
    }

    /// Hands each side the other's addresses (only after both descriptions are applied: `connect` starts this last).
    private func forwardCandidates() async {
        // Only the loopback addresses cross: nothing of this machine's network is used.
        let toB = heardA.candidates.filter(Self.isLoopback)
        if toB.count > forwardedToB {
            let fresh = Array(toB[forwardedToB...])
            forwardedToB = toB.count
            try? await b.addRemoteCandidates(fresh)
        }
        let toA = heardB.candidates.filter(Self.isLoopback)
        if toA.count > forwardedToA {
            let fresh = Array(toA[forwardedToA...])
            forwardedToA = toA.count
            try? await a.addRemoteCandidates(fresh)
        }
    }

    private static func isLoopback(_ candidate: CallCandidate) -> Bool { candidate.candidate.contains(" 127.0.0.1 ") }

    /// Polls until [condition] holds or [seconds] pass.
    func wait(seconds: Double = 25, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    /// The SDP the stack holds as the other side's, read from its peer connection.
    func remoteSdp(of engine: WebRtcMediaEngine) async -> String {
        (try? await engine.core.onQueue { core in core.connection?.remoteDescription?.sdp ?? "" }) ?? ""
    }

    func close() {
        tasks.forEach { $0.cancel() }
        a.close()
        b.close()
    }
}

func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }
