import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

struct Unexpected: Error {}

/// A gate a test opens: `wait()` returns after one `open()`.
@MainActor
final class Gate {
    private let stream: AsyncStream<Void>
    private let cont: AsyncStream<Void>.Continuation

    init() { (stream, cont) = AsyncStream.makeStream(of: Void.self) }

    func open() { cont.yield() }

    func wait() async {
        var it = stream.makeAsyncIterator()
        _ = await it.next()
    }
}

@MainActor
final class FakeGateway: CallGateway {
    let stream: AsyncStream<CallEvent>
    private let cont: AsyncStream<CallEvent>.Continuation
    var asked: [String] = []
    var incomingResult: (VaultMessage) throws -> IncomingCall = { _ in throw CallMessageError("not set") }
    var acceptResult: (OutgoingCall) throws -> AcceptedCall = { _ in throw CallMessageError("not set") }
    var startResult: (String, String) throws -> OutgoingCall = { _, _ in throw CallMessageError("not set") }
    var startGate: Gate?
    var answerKeys: CallKeys?
    var acceptGate: Gate?

    init() { (stream, cont) = AsyncStream.makeStream(of: CallEvent.self) }

    func send(_ e: CallEvent) { cont.yield(e) }

    func events() -> AsyncStream<CallEvent> { stream }

    func start(connectionId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite]) async throws -> OutgoingCall {
        asked.append("start(\(connectionId), \(suites.map(\.id)))")
        await startGate?.wait()
        return try startResult(connectionId, pinnedFingerprint)
    }

    func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall {
        asked.append("incoming(\(pinnedFingerprint), \(suites.map(\.id)))")
        return try incomingResult(event)
    }

    func answer(_ call: IncomingCall, sdp: String) async throws -> CallKeys {
        asked.append("answer(\(call.callId))")
        return try #require(answerKeys)
    }

    func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall {
        asked.append("accept(\(call.callId), \(call.pinnedFingerprint))")
        await acceptGate?.wait()
        return try acceptResult(call)
    }

    func ringing(_ callId: String) async throws { asked.append("ringing") }

    func ice(_ callId: String, _ candidates: [CallCandidate]) async throws { asked.append("ice") }

    func end(_ callId: String, reason: String) async throws { asked.append("end(\(callId), \(reason))") }

    func list(limit: Int) async throws -> CallList { CallList(calls: [], skipped: 0) }
}

/// The adapter is where a call's checks are asked for, so these tests are about what it asks and what it lets through: nothing
/// reaches the state machine that the gateway's checks did not pass, each check is made against the identity of the right
/// connection, and key material does not outlive its use. Port of vettid-android `VaultCallSignallingTest`.
@MainActor
@Suite final class VaultCallSignallingTests {
    let s1 = MediaSuite.aes128Gcm
    let gateway = FakeGateway()
    let clock = TestClock()
    var identities = ["conn-1": "aaaa bbbb", "conn-2": "cccc dddd"]
    var out: [SignalEvent] = []
    var refreshes = 0
    var onRefresh: () -> Void = {}
    private var collector: Task<Void, Never>?

    deinit { collector?.cancel() }

    func signalling(suites: [MediaSuite]? = nil) async -> VaultCallSignalling {
        let s = VaultCallSignalling(
            gateway: gateway, pinned: { [unowned self] in identities[$0] }, suites: suites ?? [s1],
            refreshConnections: { [unowned self] in
                refreshes += 1
                onRefresh()
            },
            clock: clock
        )
        collector = Task { [unowned self] in
            do { for try await e in s.events() { out.append(e) } } catch {}
        }
        await clock.runCurrent()
        return s
    }

    func message(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T60", type: type, ts: t0, body: Array(body.utf8)))
    }

    func offerEvent(_ connectionId: String? = "conn-1") -> CallEvent {
        let body = connectionId.map { #"{"connection_id":"\#($0)","call_id":"\#(callId)"}"# } ?? "{}"
        return .offer(message("call.offer", body))
    }

    func answerEvent(_ id: String = callId) -> CallEvent { .answer(message("call.answer", #"{"call_id":"\#(id)"}"#)) }

    func incomingCall(connectionId: String = "conn-1", chosen: MediaSuite? = nil, offered: [Int] = [1]) throws -> IncomingCall {
        IncomingCall(
            callId: callId, connectionId: connectionId, media: "audio", sdp: "v=0\r\n", exp: at(45_000), ringFor: 45,
            ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []),
            negotiated: try CallMedia.Negotiated(chosen: chosen ?? s1, offered: offered), ek: [UInt8](repeating: 0, count: 1216)
        )
    }

    func outgoingCall(_ connectionId: String = "conn-1", pinned: String = "") throws -> OutgoingCall {
        OutgoingCall(
            callId: callId, connectionId: connectionId, media: "audio", exp: at(45_000),
            ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []), offered: [1], pinnedFingerprint: pinned,
            offerKey: try CallWire.newOfferKey()
        )
    }

    func keys() -> CallKeys { CallKeys(suite: s1, send: filled(32, 5), receive: filled(32, 6)) }

    func settle() async { await clock.runCurrent() }

    func wipedKeys(_ k: MediaKeys) -> Bool { k.send.allSatisfy { $0 == 0 } && k.receive.allSatisfy { $0 == 0 } }

    @Test func anOfferRingsOnlyAfterItsChecksAgainstItsConnectionsIdentity() async throws {
        let s = await signalling()
        gateway.incomingResult = { _ in try self.incomingCall() }
        gateway.send(offerEvent())
        await settle()
        #expect(gateway.asked == ["incoming(aaaa bbbb, [1])"])
        guard case .offer(let o)? = out.first, out.count == 1 else { throw Unexpected() }
        #expect(o.callId == callId)
        #expect(o.connectionId == "conn-1")
        #expect(o.ringFor == .seconds(45))
        #expect(!"\(o)".contains("v=0"), "neither SDP nor addresses in a log line")
        #expect(s.refused == 0)
    }

    @Test func anOfferThatFailsItsChecksOrNamesNoKnownConnectionNeverReachesTheCall() async throws {
        let s = await signalling()
        // The gateway refuses it (a signature, the identity, the SDP, the suites: any of VaultApi's checks).
        gateway.incomingResult = { _ in throw CallMessageError("key-exchange share") }
        gateway.send(offerEvent())
        // A connection the app does not know: not even asked.
        gateway.send(offerEvent("conn-9"))
        gateway.send(offerEvent(nil))
        await settle()
        #expect(out.isEmpty)
        #expect(gateway.asked == ["incoming(aaaa bbbb, [1])"])
        #expect(s.refused == 3)
        // And it cannot be answered.
        await #expect(throws: CallSecurityError.self) { try await s.answer(callId: callId, sdp: "v=0", suites: [self.s1]) }
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("answer") })
    }

    @Test func offersAreNotRungWhileTheVaultIsNotOpen() async throws {
        let s = VaultCallSignalling(
            gateway: gateway, pinned: { [unowned self] in identities[$0] }, suites: [s1], mayRing: { false }, clock: clock
        )
        collector = Task { [unowned self] in
            do { for try await e in s.events() { out.append(e) } } catch {}
        }
        gateway.incomingResult = { _ in try self.incomingCall() }
        gateway.send(offerEvent())
        await settle()
        #expect(out.isEmpty && gateway.asked.isEmpty)
        #expect(s.refused == 1)
    }

    /// Two answers for one call, one checked by the start that was overtaken and one from the events, at the same time: only one
    /// is checked; the other finds no call and cannot end the one accepted.
    @Test func aDuplicateAnswerCannotEndAnAcceptedCall() async throws {
        let s = await signalling()
        gateway.startGate = Gate()
        gateway.acceptGate = Gate()
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let starting = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        gateway.send(answerEvent())
        await settle()
        gateway.startGate?.open()
        await settle()
        // The held answer is being checked (accept waits); the duplicate arrives now.
        #expect(gateway.asked.filter { $0.hasPrefix("accept") }.count == 1)
        gateway.send(answerEvent())
        await settle()
        gateway.acceptGate?.open()
        await settle()
        #expect(gateway.asked.filter { $0.hasPrefix("accept") }.count == 1)
        #expect(!out.contains { if case .answerRejected = $0 { true } else { false } })
        guard case .answer(let a)? = out.first, out.count == 1 else { throw Unexpected() }
        #expect(a.sdp == "v=0 answer")
        await starting.value
    }

    @Test func answeringHandsTheKeysOverOnceAndDestroysTheOriginals() async throws {
        let s = await signalling()
        gateway.incomingResult = { _ in try self.incomingCall() }
        gateway.send(offerEvent())
        await settle()
        let original = keys()
        gateway.answerKeys = original
        let handed = try await s.answer(callId: callId, sdp: "v=0", suites: [s1])
        #expect(handed.send == filled(32, 5) && handed.receive == filled(32, 6))
        #expect(throws: VaultStateError.self) { try original.send() }
        // A call is answered once.
        await #expect(throws: CallSecurityError.self) { try await s.answer(callId: callId, sdp: "v=0", suites: [self.s1]) }
        #expect(gateway.asked.filter { $0.hasPrefix("answer") }.count == 1)
    }

    @Test func anEngineThatCannotDoTheNegotiatedSuiteDoesNotAnswer() async throws {
        let s = await signalling(suites: [.aes256Gcm, s1])
        gateway.incomingResult = { _ in try self.incomingCall(chosen: .aes256Gcm, offered: [2, 1]) }
        gateway.send(offerEvent())
        await settle()
        #expect(gateway.asked == ["incoming(aaaa bbbb, [2, 1])"])
        await #expect(throws: CallSecurityError.self) { try await s.answer(callId: callId, sdp: "v=0", suites: [self.s1]) }
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("answer") })
    }

    @Test func anAnswerIsCheckedAgainstTheConnectionTheCallWasPlacedTo() async throws {
        let s = await signalling()
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        let placed = try await s.start(connectionId: "conn-2", sdp: "v=0", suites: [s1])
        #expect(placed.callId == callId)
        let original = keys()
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: original) }
        gateway.send(answerEvent())
        await settle()
        #expect(gateway.asked == ["start(conn-2, [1])", "accept(\(callId), cccc dddd)"])
        guard case .answer(let a)? = out.first else { throw Unexpected() }
        #expect(a.sdp == "v=0 answer")
        #expect(a.keys.send == filled(32, 5))
        #expect(throws: VaultStateError.self) { try original.receive() }
        // The call's ephemeral key is gone with its answer: a second answer for it is nobody's.
        gateway.send(answerEvent())
        await settle()
        #expect(out.count == 1)
        #expect(gateway.asked.filter { $0.hasPrefix("accept") }.count == 1)
    }

    @Test func aCallToAConnectionTheAppDoesNotKnowIsNotPlaced() async throws {
        let s = await signalling()
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        await #expect(throws: CallRefusedError(code: "not_found")) {
            try await s.start(connectionId: "conn-9", sdp: "v=0", suites: [self.s1])
        }
        #expect(gateway.asked.isEmpty)
    }

    @Test func anAnswerThatFailsItsChecksEndsTheCallAndAnAnswerForNoCallIsIgnored() async throws {
        let s = await signalling()
        gateway.send(answerEvent())
        await settle()
        #expect(out.isEmpty && gateway.asked.isEmpty)

        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1])
        gateway.acceptResult = { _ in throw CallMessageError("key-exchange share") }
        gateway.send(answerEvent())
        await settle()
        #expect(out.count == 1)
        #expect(out.first?.description == "AnswerRejected(\(callId))")
        #expect(s.refused == 1)
        gateway.send(answerEvent())
        await settle()
        #expect(out.count == 1)

        // The connection was removed while it rang: no identity to check against, so no call.
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        _ = try await s.start(connectionId: "conn-2", sdp: "v=0", suites: [s1])
        identities["conn-2"] = nil
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0", keys: self.keys()) }
        gateway.send(answerEvent())
        await settle()
        #expect(out.last?.description == "AnswerRejected(\(callId))")
        #expect(gateway.asked.filter { $0.hasPrefix("accept") }.count == 1)
    }

    @Test func theVaultsRefusalsAndUnverifiableAnswersToCallStart() async throws {
        let s = await signalling()
        gateway.startResult = { _, _ in throw VaultOpError(type: "call.start", code: "busy", detail: "", body: nil) }
        await #expect(throws: CallRefusedError(code: "busy")) { try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [self.s1]) }
        gateway.startResult = { _, _ in throw CallMessageError("ice configuration") }
        await #expect(throws: CallSecurityError.self) { try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [self.s1]) }
    }

    @Test func theOtherEventsPassAndAnEndedCallIsForgotten() async throws {
        let s = await signalling()
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1])
        gateway.send(.ringing(callId: callId))
        gateway.send(.ice(CallIce(callId: callId, candidates: [candidate(1)])))
        gateway.send(.ended(CallEnded(callId: callId, reason: "busy")))
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0", keys: self.keys()) }
        gateway.send(answerEvent())
        await settle()
        #expect(out.map(\.description) == ["Ringing(\(callId))", "Ice(\(callId), 1)", "End(\(callId), busy, nil)"])
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("accept") })
        #expect(!"\(candidate(1))".contains("192.0.2"), "an address is not printed")
        try await s.end(callId: callId, reason: "hangup")
        #expect(gateway.asked.last == "end(\(callId), hangup)")
    }

    @Test func aGlareEndCarriesItsWinner() async throws {
        _ = await signalling()
        gateway.send(.ended(CallEnded(callId: callId, reason: "busy", supersededBy: glareId)))
        await settle()
        guard case .end(let id, let reason, let by)? = out.first else { throw Unexpected() }
        #expect(id == callId && reason == "busy" && by == glareId)
    }

    /// One unexpected error under a check (a vault client that cannot be had around a lock, a relay error, anything) must not
    /// end the flow, and with it all call signalling of the process.
    @Test func whateverGoesWrongWithOneEventTheNextIsStillHandled() async throws {
        let s = await signalling()
        gateway.incomingResult = { _ in throw Unexpected() }
        gateway.send(offerEvent())
        await settle()
        #expect(out.isEmpty)
        #expect(s.refused == 1)
        #expect(s.errors == 1, "counted apart from a failed check")
        gateway.incomingResult = { _ in throw StartFailure() }
        gateway.send(offerEvent())
        await settle()
        gateway.incomingResult = { _ in try self.incomingCall() }
        gateway.send(offerEvent())
        gateway.send(.ended(CallEnded(callId: callId, reason: "hangup")))
        await settle()
        #expect(s.errors == 2)
        #expect(out.map(\.description) == ["Offer(\(callId))", "End(\(callId), hangup, nil)"])

        // The same under an answer: the call is over, the listening is not.
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        _ = try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1])
        gateway.acceptResult = { _ in throw Unexpected() }
        gateway.send(answerEvent())
        gateway.send(.ringing(callId: callId))
        await settle()
        #expect(out.suffix(2).map(\.description) == ["AnswerRejected(\(callId))", "Ringing(\(callId))"])
        #expect(s.errors == 3)
    }

    /// The app's connection list is in memory and is read after the vault opens, so the offer that was waiting in the mailbox at
    /// unlock can be handled first. It is looked for once more after the list was read.
    @Test func aConnectionNotFoundIsLookedForOnceMoreAfterTheListWasReadAgain() async throws {
        let s = await signalling()
        guard let known = identities.removeValue(forKey: "conn-1") else { throw Unexpected() }
        onRefresh = { [unowned self] in identities["conn-1"] = known }
        gateway.incomingResult = { _ in try self.incomingCall() }
        gateway.send(offerEvent())
        await settle()
        #expect(refreshes == 1)
        #expect(gateway.asked == ["incoming(aaaa bbbb, [1])"])
        #expect(out.count == 1)
        // A connection that is not there after it either: refused, and asked about once, not in a loop.
        onRefresh = {}
        gateway.send(offerEvent("conn-9"))
        await settle()
        #expect(refreshes == 2)
        #expect(out.count == 1)
        #expect(s.refused == 1)
        #expect(s.errors == 0)
        // A known connection costs no reading.
        gateway.send(offerEvent())
        await settle()
        #expect(refreshes == 2)
    }

    /// The vault can pass the answer on before its answer to `call.start` has been read here. It used to be dropped as "not a
    /// call this device placed".
    @Test func anAnswerThatOvertakesTheAnswerToCallStartIsUsed() async throws {
        let s = await signalling()
        gateway.startGate = Gate()
        gateway.startResult = { try self.outgoingCall($0, pinned: $1) }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let starting = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        gateway.send(answerEvent())
        // And one for another call, which is nobody's.
        gateway.send(answerEvent("01JB2Z6V9K3M4N5P6Q7R8S9T51"))
        await settle()
        #expect(out.isEmpty && gateway.asked.allSatisfy { !$0.hasPrefix("accept") })
        gateway.startGate?.open()
        await settle()
        await starting.value
        guard case .answer(let a)? = out.first, out.count == 1 else { throw Unexpected() }
        #expect(a.sdp == "v=0 answer")
        #expect(gateway.asked.filter { $0.hasPrefix("accept") }.count == 1)
        // Outside a start, an answer for no call is dropped as before.
        gateway.send(answerEvent("01JB2Z6V9K3M4N5P6Q7R8S9T52"))
        await settle()
        #expect(out.count == 1)
    }
}
