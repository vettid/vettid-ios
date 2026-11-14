import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

struct WrongState: Error { let state: CallState }

struct StartFailure: Error {}

/// Port of vettid-android `CallMachineTest`: one suite, every test sharing the fakes and the helpers below. Time is virtual
/// (``TestClock``): nothing sleeps.
@MainActor
@Suite(.serialized) struct CallMachineTests {
    let signalling = FakeSignalling()
    let engines = FakeEngines()
    let clock = TestClock()

    func machine(
        _ s: (any CallSignalling)? = nil, _ e: FakeEngines? = nil, config: MediaConfig = MediaConfig(), timings: CallTimings = CallTimings()
    ) -> CallMachine {
        CallMachine(signalling: s ?? signalling, engines: e ?? engines, clock: clock, timings: timings, config: { config })
    }

    func runCurrent() async { await clock.runCurrent() }

    func advance(_ ms: Int64) async { await clock.advance(by: ms) }

    func live(_ m: CallMachine) throws -> CallState.Live {
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        return l
    }

    func ended(_ m: CallMachine) throws -> CallState.Ended {
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        return e
    }

    func offer(_ id: String = callId, connectionId: String = "conn-1", formTwo: Bool = false) -> SignalEvent {
        .offer(CallOffer(
            callId: id, connectionId: connectionId, sdp: "v=0\r\ns=offer\r\n", exp: at(45_000), ringFor: .seconds(45), servers: [],
            suite: .aes128Gcm, formTwo: formTwo
        ))
    }

    func answerEvent() -> (SignalEvent, MediaKeys) {
        let keys = MediaKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
        return (.answer(CallAnswer(callId: callId, sdp: "v=0\r\ns=answer\r\n", keys: keys)), keys)
    }

    func wiped(_ k: MediaKeys) -> Bool { k.send.allSatisfy { $0 == 0 } && k.receive.allSatisfy { $0 == 0 } }

    /// An outgoing call up to the vault's answer to `call.start`.
    func placed(_ m: CallMachine) async throws {
        m.call("conn-1")
        await runCurrent()
        #expect(try live(m).phase == .calling)
    }

    func noEnd(_ s: FakeSignalling) -> Bool { s.sent.allSatisfy { !$0.hasPrefix("end") } }

    // swiftlint:disable:next function_body_length
    @Test func anOutgoingCallFromTheTapToTheHangUp() async throws {
        let m = machine()
        #expect(m.state == .idle)
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        #expect(m.state == .live(CallState.Live(connectionId: "conn-1", direction: .outgoing, phase: .starting)))
        #expect(signalling.sent == ["start(conn-1, [1])"])
        await advance(120)
        signalling.releaseStart()
        await runCurrent()
        let engine = engines.last
        #expect(m.state == .live(CallState.Live(connectionId: "conn-1", direction: .outgoing, phase: .calling, callId: callId)))
        #expect(engine.calls == ["createOffer", "startGathering(0)"])
        #expect(m.diagnostics.tapToPlacedMs == 120)

        // The other phone rings.
        engine.emit(.localCandidate(candidate(1)))
        await advance(300)
        signalling.deliver(.ringing(callId: callId))
        await runCurrent()
        #expect(try live(m).phase == .ringing)
        #expect(m.diagnostics.tapToRingingMs == 420)

        // Its candidates may come before its answer: kept, and given to the engine only after the answer's SDP.
        signalling.deliver(.ice(callId: callId, candidates: [candidate(7)]))
        await runCurrent()
        #expect(engine.remote.isEmpty)
        let (event, keys) = answerEvent()
        signalling.deliver(event)
        await runCurrent()
        #expect(try live(m).phase == .connecting)
        // The keys before the answer's SDP: no frame is sent or played without them.
        #expect(engine.calls == ["createOffer", "startGathering(0)", "setKeys", "acceptAnswer", "addRemoteCandidates(1)"])
        #expect(engine.sendKey == filled(32, 5) && engine.receiveKey == filled(32, 6), "the engine has the keys")
        #expect(wiped(keys), "and nobody else: the arrays were wiped")
        signalling.deliver(.ice(callId: callId, candidates: [candidate(8), candidate(9)]))
        await runCurrent()
        #expect(engine.remote.count == 3)

        await advance(700)
        engine.emit(.connection(.connected))
        engine.emit(.cryptor(.send, .ok))
        engine.emit(.cryptor(.receive, .ok))
        await runCurrent()
        #expect(try live(m).phase == .active)
        #expect(try live(m).activeSince == at(1120))
        #expect(m.diagnostics.answerToMediaMs == 700)

        m.setMuted(true)
        await runCurrent()
        #expect(engine.micOff)
        #expect(try live(m).muted)
        await advance(1000)
        await runCurrent()
        #expect(m.diagnostics.media?.packetsSent == 1)

        // A long call: neither the ring time nor the connect time ends it.
        await advance(120_000)
        #expect(try live(m).phase == .active)
        m.hangUp()
        await runCurrent()
        #expect(m.state == .ended(CallState.Ended(
            connectionId: "conn-1", direction: .outgoing, reason: .hungUp, callId: callId, duration: .milliseconds(121_000)
        )))
        #expect(signalling.sent.last == "end(\(callId), hangup)")
        #expect(engine.closed)
        m.dismiss()
        await runCurrent()
        #expect(m.state == .idle)
    }

    @Test func localCandidatesAreSentInBatchesAndNeverFasterThanTheRelayTakesThem() async throws {
        let m = machine()
        try await placed(m)
        let engine = engines.last
        for i in 1...20 { engine.emit(.localCandidate(candidate(i))) }
        await runCurrent()
        #expect(signalling.ice.isEmpty, "nothing yet: they wait to be sent together")
        await advance(201)
        #expect(signalling.ice.map(\.count) == [16])
        await advance(299)
        #expect(signalling.ice.count == 1)
        await advance(2)
        #expect(signalling.ice.map(\.count) == [16, 4])
        #expect(Array(signalling.ice.joined()) == (1...20).map { candidate($0) })
        // Having an address, the gathering timeout does nothing.
        await advance(10_000)
        #expect(try live(m).phase == .calling)
    }

    @Test func aCallThatSendsTooManyCandidateMessagesStopsSendingThem() async throws {
        let m = machine(timings: CallTimings(maxIceMessages: 2))
        m.call("conn-1")
        await runCurrent()
        for i in 0..<60 { engines.last.emit(.localCandidate(candidate(i % 200 + 1))) }
        await advance(5_000)
        #expect(signalling.ice.map(\.count) == [16, 16])
    }

    @Test func nobodyAnswersTheCallerSendsTheTimeout() async throws {
        let m = machine()
        try await placed(m)
        engines.last.emit(.localCandidate(candidate(1)))
        signalling.deliver(.ringing(callId: callId))
        await advance(44_999)
        #expect(try live(m).phase == .ringing)
        await advance(2)
        #expect(try ended(m).reason == .noAnswer)
        #expect(signalling.sent.last == "end(\(callId), timeout)")
        #expect(engines.last.closed)
        #expect(try ended(m).duration == nil)
    }

    @Test func theRingTimeStaysWithinBoundsWhateverTheClocksSay() async throws {
        // The vault's clock is far behind this phone's: the offer looks expired already. Ring ten seconds anyway.
        signalling.startResult = { PlacedCall(callId: callId, exp: at(-600_000)) }
        let m = machine()
        try await placed(m)
        engines.last.emit(.localCandidate(candidate(1)))
        await advance(9_999)
        #expect(try live(m).phase == .calling)
        await advance(2)
        #expect(try ended(m).reason == .noAnswer)
        m.dismiss()

        // And far ahead: never longer than a minute.
        signalling.startResult = { PlacedCall(callId: callId, exp: at(6_000_000 + self.clock.ms)) }
        m.call("conn-1")
        await runCurrent()
        engines.last.emit(.localCandidate(candidate(1)))
        await advance(59_999)
        #expect(try live(m).phase == .calling)
        await advance(2)
        #expect(try ended(m).reason == .noAnswer)
    }

    @Test func theOtherSidesEndingsOfAnOutgoingCall() async throws {
        let expected: [(String, CallEnd)] = [
            ("decline", .declined), ("busy", .busy), ("unavailable", .unavailable), ("failed", .failed), ("hangup", .peerHungUp),
            ("timeout", .noAnswer),
        ]
        let m = machine()
        for (reason, end) in expected {
            try await placed(m)
            signalling.sent.removeAll()
            signalling.deliver(.end(callId: callId, reason: reason))
            await runCurrent()
            #expect(try ended(m).reason == end, "\(reason)")
            #expect(noEnd(signalling), "nothing is sent back")
            #expect(engines.last.closed)
        }
        // Another call's ending is not this call's.
        try await placed(m)
        signalling.deliver(.end(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T51", reason: "hangup"))
        await runCurrent()
        #expect(try live(m).phase == .calling)
    }

    @Test func theVaultsRefusalsOfCallStart() async throws {
        let expected: [(String, CallEnd)] = [
            ("busy", .ownVaultBusy), ("calls_off", .callsOff), ("not_found", .unavailable), ("connection_unavailable", .unavailable),
            ("owner_check_required", .ownerCheckRequired), ("unsupported_type", .notSupported), ("bad_request", .failed),
        ]
        let m = machine()
        for (code, end) in expected {
            signalling.startResult = { throw CallRefusedError(code: code) }
            m.call("conn-1")
            await runCurrent()
            #expect(try ended(m).reason == end, "\(code)")
            #expect(try ended(m).callId == nil)
            #expect(noEnd(signalling))
        }
        // The relay could not be reached, or the vault's answer did not verify.
        signalling.startResult = { throw StartFailure() }
        m.call("conn-1")
        await runCurrent()
        #expect(try ended(m).reason == .failed)
        signalling.startResult = { throw CallSecurityError("ice configuration") }
        m.call("conn-1")
        await runCurrent()
        #expect(try ended(m).reason == .notEncrypted)
    }

    @Test func aCallHungUpBeforeTheVaultAnsweredIsEndedWhenItDoes() async throws {
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        m.hangUp()
        await runCurrent()
        #expect(try ended(m).reason == .hungUp)
        #expect(engines.last.closed)
        #expect(noEnd(signalling))
        // The vault had taken the call: it is rung off there, or the other member's phone would ring for nobody.
        signalling.releaseStart()
        await runCurrent()
        #expect(signalling.sent.last == "end(\(callId), hangup)")
        #expect(try ended(m).reason == .hungUp)
    }

    @Test func anIncomingCallRingsAndCanBeDeclined() async throws {
        let m = machine()
        signalling.deliver(offer())
        await runCurrent()
        #expect(m.state == .live(CallState.Live(connectionId: "conn-1", direction: .incoming, phase: .incoming, callId: callId)))
        #expect(signalling.sent == ["ringing(\(callId))"])
        #expect(engines.created.isEmpty, "no media engine, so no address gathered, before the member answers")
        // A second offer while one rings is not shown (the vault answers it busy by itself).
        signalling.deliver(offer("01JB2Z6V9K3M4N5P6Q7R8S9T51", connectionId: "conn-2"))
        await runCurrent()
        #expect(try live(m).connectionId == "conn-1")
        m.decline()
        await runCurrent()
        #expect(try ended(m).reason == .declinedHere)
        #expect(signalling.sent.last == "end(\(callId), decline)")
        #expect(engines.created.isEmpty)
    }

    @Test func aRingingCallWhoseCallerHasGoneStopsByItselfAndSendsNothing() async throws {
        let m = machine()
        signalling.deliver(offer())
        await runCurrent()
        await advance(47_999)
        #expect(try live(m).phase == .incoming)
        await advance(2)
        #expect(try ended(m).reason == .missed)
        // Not `call.end{timeout}`: sent by the callee it would end the call in its own vault before the caller's timeout
        // arrives, and the vault would never record the missed call.
        #expect(signalling.sent == ["ringing(\(callId))"])
    }

    @Test func theEndingsOfARingingIncomingCall() async throws {
        let expected: [(String, CallEnd)] = [
            ("timeout", .missed), ("hangup", .missed), ("unavailable", .missed), ("answered_elsewhere", .answeredElsewhere),
            ("decline", .declinedHere), ("something_new", .missed),
        ]
        let m = machine()
        for (reason, end) in expected {
            signalling.deliver(offer())
            await runCurrent()
            signalling.sent.removeAll()
            signalling.deliver(.end(callId: callId, reason: reason))
            await runCurrent()
            #expect(try ended(m).reason == end, "\(reason)")
            #expect(signalling.sent.isEmpty)
        }
    }

    @Test func answeringAnIncomingCall() async throws {
        let m = machine()
        signalling.deliver(offer())
        await runCurrent()
        // The caller's candidates arrive while it rings.
        signalling.deliver(.ice(callId: callId, candidates: [candidate(1), candidate(2)]))
        await runCurrent()
        m.answer()
        await runCurrent()
        let engine = engines.last
        #expect(try live(m).phase == .connecting)
        #expect(engine.calls == ["acceptOffer", "setKeys", "addRemoteCandidates(2)"])
        #expect(signalling.sent == ["ringing(\(callId))", "answer(\(callId))"])
        #expect(engine.sendKey == filled(32, 1) && engine.receiveKey == filled(32, 2))

        engine.emit(.localCandidate(candidate(3)))
        await advance(250)
        #expect(signalling.ice == [[candidate(3)]])
        signalling.deliver(.ice(callId: callId, candidates: [candidate(4)]))
        engine.emit(.connection(.connected))
        await runCurrent()
        #expect(try live(m).phase == .active)
        #expect(engine.remote.count == 3)
        // The ring time is over long before this: it no longer applies.
        await advance(60_000)
        #expect(try live(m).phase == .active)

        signalling.deliver(.end(callId: callId, reason: "hangup"))
        await runCurrent()
        #expect(try ended(m).reason == .peerHungUp)
        #expect(try ended(m).duration == .milliseconds(60_000))
        #expect(engine.closed)
    }

    @Test func aCalleesCandidatesWaitUntilItsAnswerHasGone() async throws {
        final class Slow: FakeSignalling {
            let gate = AsyncStream<Void>.makeStream()

            override func answer(callId: String, sdp: String, suites: [MediaSuite]) async throws -> MediaKeys {
                var it = gate.0.makeAsyncIterator()
                _ = await it.next()
                return try await super.answer(callId: callId, sdp: sdp, suites: suites)
            }
        }
        let slow = Slow()
        let m = machine(slow)
        slow.deliver(offer())
        await runCurrent()
        m.answer()
        await runCurrent()
        engines.last.emit(.localCandidate(candidate(1)))
        await advance(2_000)
        // Only the call's device may send candidates, and this device is that only once its answer is with the vault.
        #expect(slow.ice.isEmpty)
        slow.gate.1.yield()
        await advance(250)
        #expect(slow.ice.count == 1)
    }

    @Test func anAnswerThatCameTooLateEndsUnavailable() async throws {
        let m = machine()
        signalling.deliver(offer())
        await runCurrent()
        m.answer()
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: "unavailable"))
        await runCurrent()
        #expect(try ended(m).reason == .unavailable)
        #expect(engines.last.closed)
    }

    @Test func noAddressToBeReachedAtEndsTheCallWithItsOwnReason() async throws {
        // The caller: gathering never produces anything (a blocked network permission): not "Gathering" for ever.
        let m = machine()
        try await placed(m)
        await advance(7_999)
        #expect(try live(m).phase == .calling)
        await advance(2)
        #expect(try ended(m).reason == .noAddress)
        #expect(signalling.sent.last == "end(\(callId), failed)")
        #expect(engines.last.closed)
        m.dismiss()

        // Gathering that ends with nothing is not the end: the timer decides.
        try await placed(m)
        engines.last.emit(.gatheringDone(found: 0))
        await advance(7_999)
        #expect(try live(m).phase == .calling)
        await advance(2)
        #expect(try ended(m).reason == .noAddress)
        m.dismiss()

        // The callee, after answering.
        signalling.sent.removeAll()
        signalling.deliver(offer())
        await runCurrent()
        m.answer()
        await runCurrent()
        await advance(8_001)
        #expect(try ended(m).reason == .noAddress)
        #expect(signalling.sent.last == "end(\(callId), failed)")
    }

    @Test func aCandidateAfterEmptyGatheringKeepsTheCallGoing() async throws {
        // The stack finished a round before the network had reported its addresses; a candidate follows.
        let m = machine()
        try await placed(m)
        engines.last.emit(.gatheringDone(found: 0))
        await runCurrent()
        #expect(try live(m).phase == .calling)
        engines.last.emit(.localCandidate(candidate(1)))
        await runCurrent()
        await advance(9_000)
        #expect(try live(m).phase == .calling)
    }
}

extension CallMachineTests {
    /// Stopping the machine during a live call lets the call go (its engine closed, the keys it was given wiped) and sends
    /// nothing: no `call.end`, no candidates, and nothing that arrives afterwards is handled.
    @Test func stoppingTheMachineLetsALiveCallGoAndSendsNothing() async throws {
        let m = machine()
        try await placed(m)
        let engine = engines.last
        let (event, keys) = answerEvent()
        signalling.deliver(event)
        await runCurrent()
        #expect(try live(m).phase == .connecting)
        let sentBefore = signalling.sent
        m.stop()
        await runCurrent()
        #expect(engine.closed)
        #expect(wiped(keys))
        engine.emit(.localCandidate(candidate(1)))
        signalling.deliver(.ice(callId: callId, candidates: [candidate(7)]))
        await advance(120_000)
        #expect(signalling.sent == sentBefore, "nothing sent after the stop")
        #expect(noEnd(signalling))
    }
}
