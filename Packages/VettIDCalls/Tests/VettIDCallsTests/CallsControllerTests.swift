import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// Port of vettid-android `CallsControllerTest` for C1 (form 1): availability, the stale sweep, the 12-hour cap and the history are
/// the same rules; the microphone gate and the end before a lock are this phone's. Time is virtual (``TestClock``). Not ported:
/// keep-alives, permissions, the C2 sweep and the test-build configuration (C2 and later).
@MainActor
@Suite(.serialized) final class CallsControllerTests {
    let vault = FakeCallVault()
    let engines = FakeEngines()
    let clock = TestClock()
    var controllers: [CallsController] = []

    deinit {
        MainActor.assumeIsolated { for c in controllers { c.stop() } }
    }

    /// The call's diagnostics tick once a second; over twelve virtual hours that is 43 200 turns of the clock, so here it is slow.
    static let timings = CallTimings(diagnosticsEvery: .seconds(7200))

    func controller(_ mic: FakeMicrophone, answering: (@MainActor () -> Void)? = nil) -> CallsController {
        let c = CallsController(vault: vault, engines: engines, microphone: mic, clock: clock, timings: Self.timings, answering: answering)
        controllers.append(c)
        return c
    }

    func settle() async { await clock.runCurrent() }

    func unlock() async {
        vault.setUnlocked(true)
        await settle()
    }

    func refusal(_ code: String) -> VaultOpError { VaultOpError(type: "error", code: code, detail: "", body: nil) }

    func outgoing(_ connectionId: String = "conn-1") throws -> OutgoingCall {
        OutgoingCall(
            callId: callId, connectionId: connectionId, media: "audio", exp: at(45_000),
            ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []), offered: [1], pinnedFingerprint: "",
            offerKey: try CallWire.newOfferKey()
        )
    }

    func incoming(_ connectionId: String = "conn-1") throws -> IncomingCall {
        IncomingCall(
            callId: callId, connectionId: connectionId, media: "audio", sdp: "v=0\r\n", exp: at(45_000), ringFor: 45,
            ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []),
            negotiated: try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1]), ek: [UInt8](repeating: 0, count: 1216)
        )
    }

    func offerEvent() -> CallEvent {
        let body = #"{"connection_id":"conn-1","call_id":"\#(callId)"}"#
        return .offer(VaultMessage(inner: Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T60", type: "call.offer", ts: t0, body: Array(body.utf8))))
    }

    /// An outgoing call placed and answered, until media flows.
    func activeCall(_ c: CallsController) async throws {
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        vault.gatewayFake.acceptResult = { _ in
            let keys = CallKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
            return AcceptedCall(callId: callId, sdp: "v=0\r\ns=answer\r\n", keys: keys)
        }
        c.call("conn-1")
        await settle()
        vault.gatewayFake.send(.answer(VaultMessage(inner: Inner(
            id: "01JB2Z6V9K3M4N5P6Q7R8S9T61", type: "call.answer", ts: t0, body: Array(#"{"call_id":"\#(callId)"}"#.utf8)
        ))))
        await settle()
        let engine = engines.last
        engine.emit(.connection(.connected))
        engine.emit(.cryptor(.send, .ok))
        engine.emit(.cryptor(.receive, .ok))
        await settle()
        guard case .live(let l) = c.state, l.phase == .active else { throw WrongState(state: c.state) }
    }

    // MARK: availability

    @Test func theVaultIsAskedAtEveryUnlockAndAnAnswerMeansCalls() async {
        let c = controller(FakeMicrophone(.granted))
        await settle()
        #expect(c.availability == .unknown, "nothing is known while the vault is locked")
        #expect(vault.gatewayFake.listCalls == 0)
        await unlock()
        #expect(c.availability == .ready)
        #expect(vault.gatewayFake.listCalls == 1)
        vault.setUnlocked(false)
        await settle()
        #expect(c.availability == .unknown, "nothing is kept across a lock")
        await unlock()
        #expect(vault.gatewayFake.listCalls == 2, "asked again after each unlock")
        #expect(c.availability == .ready)
    }

    @Test func aVaultWithoutCallsSaysSoAndNothingIsSwept() async {
        vault.gatewayFake.listResult = { throw self.refusal("unsupported_type") }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(c.availability == .notInVault)
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.asked.isEmpty && c.microphonePrompt == nil, "no call, no prompt")
    }

    @Test func anotherRefusalLeavesItNotKnownAndTheRecheckAsksAgain() async {
        vault.gatewayFake.listResult = { throw self.refusal("owner_check_required") }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(c.availability == .unknown)
        #expect(vault.gatewayFake.listCalls == 1, "a refusal is not tried again by itself")
        vault.gatewayFake.listResult = { CallList(calls: [], skipped: 0) }
        vault.recheck()
        await settle()
        #expect(c.availability == .ready)
        // Known now: a further recheck asks nothing.
        vault.recheck()
        await settle()
        #expect(vault.gatewayFake.listCalls == 2)
    }

    @Test func aFailedReadIsTriedAgainTwiceThenGivenUp() async {
        var failures = 2
        vault.gatewayFake.listResult = {
            if failures > 0 {
                failures -= 1
                throw StartFailure()
            }
            return CallList(calls: [], skipped: 0)
        }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(c.availability == .unknown)
        await clock.advance(by: 2000)
        await settle()
        #expect(vault.gatewayFake.listCalls == 2)
        await clock.advance(by: 4000)
        await settle()
        #expect(c.availability == .ready)
        #expect(vault.gatewayFake.listCalls == 3)

        // Never answered: three reads, then it stays not known.
        vault.setUnlocked(false)
        await settle()
        failures = 100
        await unlock()
        await clock.advance(by: 20_000)
        await settle()
        #expect(vault.gatewayFake.listCalls == 6)
        #expect(c.availability == .unknown)
    }

    @Test func aLockDuringTheReadDropsItsAnswer() async {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        vault.gatewayFake.listResult = { CallList(calls: [record(state: "active")], skipped: 2) }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.setUnlocked(false)
        await settle()
        gate.open()
        await settle()
        #expect(c.availability == .unknown)
        #expect(vault.gatewayFake.ended.isEmpty, "nothing is ended after a lock")
        #expect(c.diagnostics.listSkipped == 0)
    }

    @Test func aRecheckDuringTheProbeIsAskedAgainWhenStillNotKnown() async {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        var reads = 0
        vault.gatewayFake.listResult = {
            reads += 1
            if reads == 1 { throw self.refusal("owner_check_required") }
            return CallList(calls: [], skipped: 0)
        }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        // The first read is still out when the daily check is done.
        vault.gatewayFake.listGate = nil
        vault.recheck()
        await settle()
        #expect(vault.gatewayFake.listCalls == 1)
        gate.open()
        await settle()
        #expect(vault.gatewayFake.listCalls == 2, "the recheck was held, not dropped")
        #expect(c.availability == .ready)
    }

    @Test func aHeldRecheckIsDroppedOnceTheVaultIsKnownOrLocked() async {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.listGate = nil
        vault.recheck()
        await settle()
        gate.open()
        await settle()
        #expect(c.availability == .ready && vault.gatewayFake.listCalls == 1, "known: nothing to ask again")
    }

    @Test func theButtonIsDisabledDuringACall() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await settle()
        #expect(c.availability == .inCall)
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.asked == ["start(conn-1)"], "the second tap does nothing")
    }

    // MARK: the stale sweep

    @Test func callsTheVaultStillHoldsLiveAreEndedAtUnlock() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [
                record("A", direction: "out", state: "active", startedAtMs: -3_600_000, answeredAtMs: -3_590_000),
                record("B", direction: "out", state: "ringing", startedAtMs: -200_000),
                record("C", direction: "in", state: "ringing", startedAtMs: -200_000),
                record("D", direction: "out", state: "ringing", startedAtMs: -119_000),
                record("E", direction: "out", state: "ended", reason: "hangup", startedAtMs: -3_600_000, endedAtMs: -3_500_000),
            ], skipped: 0)
        }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended == ["A failed", "B timeout", "C failed"])
        #expect(c.diagnostics.staleEnded == 3)
    }

    @Test func aRingingRecordIsStaleOnlyPastTwoMinutes() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [
                record("A", direction: "out", state: "ringing", startedAtMs: -120_000),
                record("B", direction: "out", state: "ringing", startedAtMs: -120_001),
            ], skipped: 0)
        }
        _ = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended == ["B timeout"], "exactly 120 s is still ringing")
    }

    @Test func aLockInTheMiddleOfTheSweepStopsItAfterTheCurrentEnd() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [record("A", state: "active"), record("B", state: "active")], skipped: 0)
        }
        let gate = Gate()
        vault.gatewayFake.endGate = gate
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.asked == ["end(A, failed)"], "the first end is out")
        vault.setUnlocked(false)
        await settle()
        gate.open()
        await settle()
        #expect(vault.gatewayFake.ended == ["A failed"] && vault.gatewayFake.asked == ["end(A, failed)"], "B is not ended")
        #expect(c.availability == .unknown)
    }

    @Test func aFailedSweepEndIsNotCountedAndTheOthersGoOn() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [record("A", state: "active"), record("B", state: "active")], skipped: 0)
        }
        vault.gatewayFake.endFails = ["A"]
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended == ["B failed"])
        #expect(c.diagnostics.staleEnded == 1)
        #expect(c.availability == .ready)
    }

    // MARK: the history

    @Test func theHistoryIsTheConnectionsRowsAndSaysWhenSomeCouldNotBeShown() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [
                record("A", direction: "out", reason: "hangup", startedAtMs: -5000, answeredAtMs: -4000, endedAtMs: -1000),
                record("B", connection: "conn-2", direction: "out", reason: "decline", startedAtMs: -3000),
                record("C", direction: "in", reason: "answered_elsewhere", startedAtMs: -2000),
            ], skipped: 1)
        }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let h = await c.history("conn-1")
        #expect(h.entries.map(\.callId) == ["A"], "the other connection's call and the one answered elsewhere have no row")
        #expect(h.entries.first?.outcome == .talked && h.entries.first?.duration == .seconds(3))
        #expect(h.someNotShown, "the vault skipped one entry")
        #expect(c.diagnostics.listSkipped == 1)
    }

    @Test func theHistoryIsEmptyWhileTheVaultHasNoCallsOrIsLocked() async {
        let c = controller(FakeMicrophone(.granted))
        #expect(await c.history("conn-1") == CallHistory())
        vault.gatewayFake.listResult = { throw self.refusal("unsupported_type") }
        await unlock()
        let before = vault.gatewayFake.listCalls
        #expect(await c.history("conn-1") == CallHistory())
        #expect(vault.gatewayFake.listCalls == before, "not asked of a vault without calls")
    }

    @Test func aHistoryReadThatFailsIsEmptyNotAnError() async {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.listResult = { throw StartFailure() }
        #expect(await c.history("conn-1") == CallHistory())
    }

    // MARK: ringing offers

    @Test func anOfferRingsOnlyOnceTheVaultIsOpenAndWaitsAMomentForAnUnlockInProgress() async throws {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await settle()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 1000)
        #expect(c.state == .idle)
        await unlock()
        await clock.advance(by: 100)
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
    }

    @Test func anOfferDoesNotRingInAVaultWithoutCallsAndSendsNothing() async {
        vault.gatewayFake.listResult = { throw self.refusal("unsupported_type") }
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(c.availability == .notInVault)
        vault.gatewayFake.send(offerEvent())
        await settle()
        #expect(c.state == .idle)
        #expect(c.diagnostics.refused == 1, "refused and counted")
        #expect(vault.gatewayFake.asked.isEmpty, "not checked, not rung, no call.ringing, no call.end")
    }

    @Test func anOfferWaitsForTheProbeAndRingsOnceTheVaultHasCalls() async throws {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 1000)
        #expect(c.state == .idle, "the probe has not answered")
        gate.open()
        await clock.advance(by: 100)
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
    }

    @Test func anOfferWaitingForTheProbeDoesNotRingWhenTheAnswerIsNotInVault() async {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        vault.gatewayFake.listResult = { throw self.refusal("unsupported_type") }
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 1000)
        gate.open()
        await clock.advance(by: 100)
        #expect(c.state == .idle)
        #expect(vault.gatewayFake.asked.isEmpty)
    }

    @Test func anOfferDoesNotRingWhileTheVaultIsNotKnownToHaveCalls() async {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        vault.gatewayFake.listResult = { throw self.refusal("owner_check_required") }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 11_000)
        #expect(c.state == .idle && vault.gatewayFake.asked.isEmpty, "a refusal other than unsupported_type: not known")
    }

    @Test func anOfferDoesNotRingWhenTheProbeFailedOnTheNetwork() async {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        vault.gatewayFake.listResult = { throw StartFailure() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 11_000)
        #expect(c.state == .idle && vault.gatewayFake.asked.isEmpty)
    }

    @Test func aProbeThatAnswersAfterTheWaitDoesNotRingTheOffer() async {
        let gate = Gate()
        vault.gatewayFake.listGate = gate
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 11_000)
        gate.open()
        await clock.advance(by: 1000)
        #expect(c.availability == .ready)
        #expect(c.state == .idle, "the offer was refused at the deadline")
    }

    @Test func aRecheckProbeThatAnswersInsideTheWaitLetsTheOfferRing() async throws {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        vault.gatewayFake.listResult = { throw self.refusal("owner_check_required") }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 3000)
        #expect(c.state == .idle)
        vault.gatewayFake.listResult = { CallList(calls: [], skipped: 0) }
        vault.recheck()
        await clock.advance(by: 200)
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
    }

    @Test func anOfferWhoseUnlockDoesNotComeDoesNotRing() async {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await settle()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 11_000)
        #expect(c.state == .idle)
        #expect(c.diagnostics.refused == 1)
    }

    @Test func noOfferRingsWhileTheUpdateScreenCoversTheApp() async {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.updateShowing = true
        vault.gatewayFake.send(offerEvent())
        await settle()
        #expect(c.state == .idle)
    }
}
