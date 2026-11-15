import Foundation
import Testing
@testable import VettIDCalls
@testable import VettIDVault

/// Ends that come while a call is being started (`call.start` has not returned): the call they end is not kept, and its
/// ephemeral key is destroyed as soon as it is known.
extension VaultCallSignallingTests {
    /// The vault can end the call (`busy`) before its answer to `call.start` has been read here. The call it then returns is not
    /// kept, and its ephemeral key is destroyed at once, not when later calls push it out.
    @Test func aCallEndedBeforeItsStartReturnedIsNotKeptAndItsKeyIsDestroyed() async throws {
        let s = await signalling()
        gateway.startGate = Gate()
        var made: OutgoingCall?
        gateway.startResult = { [unowned self] in
            let call = try outgoingCall($0, pinned: $1)
            made = call
            return call
        }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let starting = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        gateway.send(.ended(CallEnded(callId: callId, reason: "busy")))
        await settle()
        #expect(out.map(\.description) == ["End(\(callId), busy, nil)"])
        gateway.startGate?.open()
        await settle()
        await starting.value
        let call = try #require(made)
        #expect(throws: (any Error).self, "the offer key is destroyed") { _ = try call.key().seed() }
        // Not kept: an answer for it now finds no call.
        gateway.send(answerEvent())
        await settle()
        #expect(out.count == 1)
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("accept") })
    }

    /// An end for some other call while one is being started does not touch the call being started.
    @Test func anEndForAnotherCallDuringAStartLeavesTheStartedCall() async throws {
        let s = await signalling()
        gateway.startGate = Gate()
        var made: OutgoingCall?
        gateway.startResult = { [unowned self] in
            let call = try outgoingCall($0, pinned: $1)
            made = call
            return call
        }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let starting = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        gateway.send(.ended(CallEnded(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T51", reason: "hangup")))
        await settle()
        gateway.startGate?.open()
        await settle()
        await starting.value
        let call = try #require(made)
        #expect(throws: Never.self) { _ = try call.key().seed() }
        gateway.send(answerEvent())
        await settle()
        guard case .answer(let a)? = out.last else { throw Unexpected() }
        #expect(a.sdp == "v=0 answer")
    }

    /// Two starts in flight (one abandoned, a new call placed): the first is ended by the vault, the second returns first, and the
    /// first's key is still destroyed when it returns. Ten unrelated ends from the vault in between do not push it out.
    @Test func anEndIsRememberedUntilEveryStartInFlightHasReturned() async throws {
        let s = await signalling()
        let second = "01JB2Z6V9K3M4N5P6Q7R8S9T51"
        let first = Gate(), then = Gate()
        gateway.startGates = [first, then]
        var made: [String: OutgoingCall] = [:]
        gateway.startResult = { [unowned self] conn, pinned in
            let call = try outgoingCall(conn, pinned: pinned, id: conn == "conn-1" ? callId : second)
            made[call.callId] = call
            return call
        }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let a = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        let b = Task { _ = try? await s.start(connectionId: "conn-2", sdp: "v=0", suites: [s1]) }
        await settle()
        gateway.send(.ended(CallEnded(callId: callId, reason: "busy")))
        // More than the four calls kept, fewer than the ids remembered.
        for i in 0..<10 { gateway.send(.ended(CallEnded(callId: "01JB2Z6V9K3M4N5P6Q7R8S9U0\(i)", reason: "hangup"))) }
        await settle()
        then.open()
        await settle()
        await b.value
        first.open()
        await settle()
        await a.value
        let ended = try #require(made[callId]), live = try #require(made[second])
        #expect(throws: (any Error).self, "the ended call's key is destroyed") { _ = try ended.key().seed() }
        #expect(throws: Never.self) { _ = try live.key().seed() }
        // The live call was kept: its answer is checked and used.
        gateway.send(answerEvent(second))
        await settle()
        guard case .answer(let ans)? = out.last else { throw Unexpected() }
        #expect(ans.callId == second)
    }

    /// A start held at the gateway, a body run while it is, and the call it returns kept for the test to look at.
    func heldStart(_ s: VaultCallSignalling, during body: () async throws -> Void) async throws -> OutgoingCall {
        gateway.startGate = Gate()
        var made: OutgoingCall?
        gateway.startResult = { [unowned self] in
            let call = try outgoingCall($0, pinned: $1)
            made = call
            return call
        }
        gateway.acceptResult = { AcceptedCall(callId: $0.callId, sdp: "v=0 answer", keys: self.keys()) }
        let starting = Task { _ = try? await s.start(connectionId: "conn-1", sdp: "v=0", suites: [s1]) }
        await settle()
        try await body()
        await settle()
        gateway.startGate?.open()
        await settle()
        await starting.value
        gateway.startGate = nil
        return try #require(made)
    }

    func destroyed(_ call: OutgoingCall) -> Bool { (try? call.key().seed()) == nil }

    /// An offer with the placed call's id rings, and the vault ends it while the start is in flight: the id is remembered like
    /// any other, and the call the start returns is not kept.
    @Test func anEndForARingingCallDuringAStartIsRemembered() async throws {
        let s = await signalling()
        gateway.incomingResult = { _ in try self.incomingCall() }
        let call = try await heldStart(s) {
            gateway.send(offerEvent())
            await settle()
            gateway.send(.ended(CallEnded(callId: callId, reason: "hangup")))
        }
        #expect(destroyed(call))
    }

    /// More ends than are remembered come while a start is in flight (the oldest is the one for this call): the call is not kept.
    @Test func tooManyEndsDuringAStartKeepNoCallItReturns() async throws {
        let s = await signalling()
        let call = try await heldStart(s) {
            gateway.send(.ended(CallEnded(callId: callId, reason: "busy")))
            for i in 0..<16 { gateway.send(.ended(CallEnded(callId: "01JB2Z6V9K3M4N5P6Q7R8S9U\(String(i + 10))", reason: "hangup"))) }
        }
        #expect(destroyed(call))
        gateway.send(answerEvent())
        await settle()
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("accept") })
        // The next start, after no start is in flight, is not affected.
        let next = try await heldStart(s) {}
        #expect(!destroyed(next))
    }

    /// A start that fails with ends remembered: they are forgotten with it, and a later start of a call with the same id is kept.
    @Test func aStartThatFailsForgetsTheEndsAndTheNextStartIsKept() async throws {
        let s = await signalling()
        gateway.startGate = Gate()
        gateway.startResult = { _, _ in throw VaultOpError(type: "call.start", code: "busy", detail: "", body: nil) }
        let failing = Task { try await s.start(connectionId: "conn-1", sdp: "v=0", suites: [self.s1]) }
        await settle()
        gateway.send(.ended(CallEnded(callId: callId, reason: "busy")))
        await settle()
        gateway.startGate?.open()
        await #expect(throws: CallRefusedError(code: "busy")) { try await failing.value }
        let next = try await heldStart(s) {}
        #expect(!destroyed(next))
        gateway.send(answerEvent())
        await settle()
        guard case .answer? = out.last else { throw Unexpected() }
    }

    /// The answer overtakes the start and the end comes after it, both before the start returns: the answer is not used.
    @Test func anAnswerHeldBeforeTheEndIsDropped() async throws {
        let s = await signalling()
        let call = try await heldStart(s) {
            gateway.send(answerEvent())
            await settle()
            gateway.send(.ended(CallEnded(callId: callId, reason: "hangup")))
        }
        #expect(destroyed(call))
        #expect(gateway.asked.allSatisfy { !$0.hasPrefix("accept") })
        #expect(out.map(\.description) == ["End(\(callId), hangup, nil)"])
    }

    /// The call is ended here (`end(callId:)`) while its start is in flight: it is not kept either.
    @Test func aLocalEndDuringAStartIsRemembered() async throws {
        let s = await signalling()
        let call = try await heldStart(s) { try await s.end(callId: callId, reason: "hangup") }
        #expect(destroyed(call))
        #expect(gateway.asked.contains("end(\(callId), hangup)"))
    }
}
