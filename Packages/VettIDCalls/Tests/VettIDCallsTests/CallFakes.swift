import Foundation
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"
let glareId = "01JB2Z6V9K3M4N5P6Q7R8S9T4Z"
let otherId = "01JB2Z6V9K3M4N5P6Q7R8S9T4Y"
let t0 = Date(timeIntervalSince1970: 1_791_799_200) // 2026-10-12T10:00:00Z

func candidate(_ n: Int) -> CallCandidate {
    CallCandidate("candidate:\(n) 1 udp 2122260223 192.0.2.\(n) 50000 typ host", sdpMid: "0", sdpMLineIndex: 0)
}

func filled(_ n: Int, _ byte: UInt8) -> [UInt8] { [UInt8](repeating: byte, count: n) }

/// Virtual time: nothing sleeps for real. `advance(by:)` and `runCurrent()` are `advanceTimeBy` and `runCurrent` of
/// kotlinx-coroutines-test, which the Android tests use: `advance(by:)` runs what is due before the new time, `runCurrent()`
/// what is due now. Everything runs on the main actor, so letting the other tasks go by (``settle()``) is deterministic.
@MainActor
final class TestClock: CallClock {
    private struct Sleeper {
        let id: Int
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var ms: Int64 = 0
    private var sleepers: [Sleeper] = []
    private var nextId = 0

    func now() -> Date { at(ms) }

    func elapsedMs() -> Int64 { ms }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = nextId
        nextId += 1
        let deadline = ms + duration.wholeMilliseconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    func settle() async {
        for _ in 0..<400 { await Task.yield() }
    }

    func runCurrent() async {
        while true {
            await settle()
            guard let next = sleepers.filter({ $0.deadline <= ms }).min(by: { $0.deadline < $1.deadline }) else { return }
            sleepers.removeAll { $0.id == next.id }
            next.continuation.resume()
        }
    }

    func advance(by delta: Int64) async {
        let target = ms + delta
        while true {
            await settle()
            guard let next = sleepers.filter({ $0.deadline < target }).min(by: { $0.deadline < $1.deadline }) else { break }
            ms = max(ms, next.deadline)
            sleepers.removeAll { $0.id == next.id }
            next.continuation.resume()
        }
        ms = target
        await settle()
    }
}

func at(_ ms: Int64) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

/// A media engine that records what it was asked, in order, and says what the test tells it to.
@MainActor
final class FakeEngine: MediaEngine {
    let suites: [MediaSuite]
    var calls: [String] = []
    let events: AsyncStream<MediaEvent>
    private let channel: AsyncStream<MediaEvent>.Continuation
    var closed = false
    var suite: MediaSuite?
    var sendKey: [UInt8]?
    var receiveKey: [UInt8]?
    var remote: [CallCandidate] = []
    var micOff = false
    var onKeys: () throws -> Void = {}
    /// What applying the other side's SDP does (an engine that finds media outside the frame encryption throws).
    var onRemoteSdp: () throws -> Void = {}
    /// The suite the cryptors were made for (createOffer, acceptOffer). Like the real engine, never remade.
    var madeFor: MediaSuite?
    /// (C2) Held back until the first decrypted frame (VAULT-MESSAGING "Key confirmation").
    var holding = false
    var streams = 1
    /// The candidate pair the stack reports: relayed, direct, or none yet (nil).
    var relayed: Bool?

    init(suites: [MediaSuite] = [.aes128Gcm]) {
        self.suites = suites
        (events, channel) = AsyncStream.makeStream(of: MediaEvent.self)
    }

    func emit(_ e: MediaEvent) { channel.yield(e) }

    func createOffer(suite: MediaSuite) async throws -> String {
        precondition(suites.contains(suite), "suite \(suite.id)")
        madeFor = suite
        calls.append("createOffer")
        return "v=0\r\ns=offer\r\nm=audio 9 X 111\r\n"
    }

    func startGathering(servers: [CallWire.IceServer]) async throws { calls.append("startGathering(\(servers.count))") }

    func acceptAnswer(sdp: String) async throws {
        calls.append("acceptAnswer")
        try onRemoteSdp()
    }

    func acceptOffer(sdp: String, servers: [CallWire.IceServer], suite: MediaSuite) async throws -> String {
        precondition(suites.contains(suite), "suite \(suite.id)")
        madeFor = suite
        calls.append("acceptOffer")
        try onRemoteSdp()
        return "v=0\r\ns=answer\r\nm=audio 9 X 111\r\n"
    }

    func setKeys(_ suite: MediaSuite, send: inout [UInt8], receive: inout [UInt8]) async throws {
        calls.append("setKeys")
        defer {
            Bytes.wipe(&send)
            Bytes.wipe(&receive)
        }
        if suite != madeFor { throw MediaNotEncryptedError("keys for suite \(suite.id), cryptors made for \(madeFor?.id ?? 0)") }
        self.suite = suite
        sendKey = send
        receiveKey = receive
        try onKeys()
    }

    func addRemoteCandidates(_ candidates: [CallCandidate]) async throws {
        calls.append("addRemoteCandidates(\(candidates.count))")
        remote += candidates
    }

    func setMuted(_ muted: Bool) { micOff = muted }

    func setHeld(_ held: Bool) { holding = held }

    func diagnostics() async -> MediaDiagnostics? {
        MediaDiagnostics(
            packetsSent: 1, inboundAudioStreams: streams,
            local: relayed.map { CandidateInfo(type: $0 ? "relay" : "host", protocol: "udp", network: "wifi") },
            remote: relayed.map { _ in CandidateInfo(type: "host", protocol: "udp", network: "") }
        )
    }

    func close() {
        closed = true
        calls.append("close")
    }
}

/// Engines in the order the machine asked for them.
@MainActor
final class FakeEngines: MediaEngineFactory {
    let suites: [MediaSuite]
    private let make: () throws -> any MediaEngine
    var created: [any MediaEngine] = []
    var config: MediaConfig?

    init(suites: [MediaSuite] = [.aes128Gcm], make: (() throws -> any MediaEngine)? = nil) {
        self.suites = suites
        self.make = make ?? { FakeEngine(suites: suites) }
    }

    func create(config: MediaConfig) throws -> any MediaEngine {
        self.config = config
        let e = try make()
        created.append(e)
        return e
    }

    // swiftlint:disable:next force_cast
    var last: FakeEngine { created.last as! FakeEngine }
}

/// Signalling that records what was sent and delivers what the test gives it.
@MainActor
class FakeSignalling: CallSignalling {
    let channel: AsyncStream<SignalEvent>
    private let deliveries: AsyncStream<SignalEvent>.Continuation
    var sent: [String] = []
    var ice: [[CallCandidate]] = []
    var startResult: () throws -> PlacedCall = { PlacedCall(callId: callId, exp: at(45_000)) }
    /// While set, `start` waits for a value: the vault's answer to `call.start` is held back.
    var startGate: AsyncStream<Void>.Continuation?
    private var startGateStream: AsyncStream<Void>?
    /// (C2) As if the vault were C2.
    var c2 = false
    var answerResult: () -> MediaKeys = { MediaKeys(suite: .aes128Gcm, send: filled(32, 1), receive: filled(32, 2)) }

    init() { (channel, deliveries) = AsyncStream.makeStream(of: SignalEvent.self) }

    var formTwo: Bool { c2 }

    func holdStart() {
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        startGateStream = stream
        startGate = cont
    }

    func releaseStart() { startGate?.yield() }

    func deliver(_ e: SignalEvent) { deliveries.yield(e) }

    func events() -> AsyncThrowingStream<SignalEvent, Error> {
        let source = channel
        return AsyncThrowingStream { c in
            let t = Task {
                for await e in source { c.yield(e) }
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }

    func start(connectionId: String, sdp: String, suites: [MediaSuite]) async throws -> PlacedCall {
        sent.append("start(\(connectionId), \(suites.map(\.id)))")
        if let stream = startGateStream {
            var it = stream.makeAsyncIterator()
            _ = await it.next()
        }
        return try startResult()
    }

    func answer(callId: String, sdp: String, suites: [MediaSuite]) async throws -> MediaKeys {
        sent.append("answer(\(callId))")
        return answerResult()
    }

    func ringing(callId: String) async throws { sent.append("ringing(\(callId))") }

    func ice(callId: String, candidates: [CallCandidate]) async throws {
        sent.append("ice(\(candidates.count))")
        ice.append(candidates)
    }

    func end(callId: String, reason: String) async throws { sent.append("end(\(callId), \(reason))") }
}
