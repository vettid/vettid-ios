import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// The vault's call messages for the controller's tests: the list, the end (which a test can hold back), the events.
@MainActor
final class ControllerGateway: CallGateway {
    private var stream: AsyncStream<CallEvent>
    private var cont: AsyncStream<CallEvent>.Continuation
    var asked: [String] = []
    var ended: [String] = []
    var listCalls = 0
    /// What `call.list` answers; thrown errors are the vault's refusals or a transport failure.
    var listResult: () throws -> CallList = { CallList(calls: [], skipped: 0) }
    /// Held until the test opens it: a `call.list` or a `call.end` the vault is slow to answer.
    var listGate: Gate?
    var endGate: Gate?
    /// Call ids whose `call.end` fails.
    var endFails: Set<String> = []
    var startResult: (String, String) throws -> OutgoingCall = { _, _ in throw CallMessageError("not set") }
    var acceptResult: (OutgoingCall) throws -> AcceptedCall = { _ in throw CallMessageError("not set") }
    var incomingResult: (VaultMessage) throws -> IncomingCall = { _ in throw CallMessageError("not set") }
    var answerKeys: CallKeys?

    init() { (stream, cont) = AsyncStream.makeStream(of: CallEvent.self) }

    func send(_ e: CallEvent) { cont.yield(e) }

    func events() -> AsyncStream<CallEvent> { stream }

    func start(connectionId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite]) async throws -> OutgoingCall {
        asked.append("start(\(connectionId))")
        return try startResult(connectionId, pinnedFingerprint)
    }

    func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall {
        try incomingResult(event)
    }

    func answer(_ call: IncomingCall, sdp: String) async throws -> CallKeys {
        asked.append("answer(\(call.callId))")
        return try #require(answerKeys)
    }

    func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall { try acceptResult(call) }

    func ringing(_ callId: String) async throws {}

    func ice(_ callId: String, _ candidates: [CallCandidate]) async throws {}

    func end(_ callId: String, reason: String) async throws {
        asked.append("end(\(callId), \(reason))")
        await endGate?.wait()
        if endFails.contains(callId) { throw StartFailure() }
        ended.append("\(callId) \(reason)")
    }

    func list(limit: Int) async throws -> CallList {
        listCalls += 1
        await listGate?.wait()
        return try listResult()
    }
}

/// The app's vault, as the calls see it: opened and locked by the test.
@MainActor
final class FakeCallVault: CallVault {
    let gatewayFake = ControllerGateway()
    var gateway: any CallGateway { gatewayFake }
    var updateShowing = false
    var identities = ["conn-1": "aaaa bbbb"]
    var firstNames = ["conn-1": "Sam"]
    private(set) var unlocked = false
    private var watchers: [AsyncStream<Bool>.Continuation] = []
    private var rechecking: [AsyncStream<Void>.Continuation] = []

    func unlockedChanges() -> AsyncStream<Bool> {
        let (stream, c) = AsyncStream.makeStream(of: Bool.self)
        c.yield(unlocked)
        watchers.append(c)
        return stream
    }

    func rechecks() -> AsyncStream<Void> {
        let (stream, c) = AsyncStream.makeStream(of: Void.self)
        rechecking.append(c)
        return stream
    }

    func setUnlocked(_ open: Bool) {
        unlocked = open
        for w in watchers { w.yield(open) }
    }

    func recheck() { for r in rechecking { r.yield() } }

    func fingerprint(_ connectionId: String) async -> String? { identities[connectionId] }

    func name(_ connectionId: String) -> String? { firstNames[connectionId] }

    func firstName(_ connectionId: String) -> String? { firstNames[connectionId] }

    func refreshConnections() async {}
}

@MainActor
final class FakeMicrophone: MicrophonePermission {
    var status: MicrophoneStatus
    /// What the member does at the system's prompt.
    var allows = true
    private(set) var requests = 0
    /// Held until the test opens it: the member is still at the system's prompt.
    var requestGate: Gate?

    init(_ status: MicrophoneStatus) { self.status = status }

    func request() async -> Bool {
        requests += 1
        await requestGate?.wait()
        status = allows ? .granted : .denied
        return allows
    }
}

func record(
    _ id: String = callId, connection: String = "conn-1", direction: String = "out", state: String = "ended", reason: String? = nil,
    startedAtMs: Int64 = 0, answeredAtMs: Int64? = nil, endedAtMs: Int64? = nil
) -> CallRecord {
    CallRecord(
        callId: id, connectionId: connection, direction: direction, media: "audio", state: state, reason: reason,
        startedAt: Timestamps.formatMillis(at(startedAtMs)), answeredAt: answeredAtMs.map { Timestamps.formatMillis(at($0)) },
        endedAt: endedAtMs.map { Timestamps.formatMillis(at($0)) }
    )
}
