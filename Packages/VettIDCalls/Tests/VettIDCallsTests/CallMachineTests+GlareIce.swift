import Foundation
import Testing
import VettIDVault
@testable import VettIDCalls

/// (C2, VAULT-MESSAGING §10.10 "Glare") The winner's caller sends its candidates as soon as its own start is placed, perhaps all
/// before this device answers it: those that come while this device's lost call is still the session are kept with the held
/// offer and go to the winner's call.
extension CallMachineTests {
    /// Held while `call.start` was out, with the winner's offer and the glare's end; then the start is placed or lost.
    @Test func aGlareWinnersCandidatesHeldDuringTheStartReachItsAnsweredCall() async throws {
        for lost in [false, true] {
            let s = FakeSignalling()
            s.holdStart()
            if lost { s.startResult = { throw CallLostError(callId: callId) } }
            let m = machine(s)
            m.call("conn-1")
            await runCurrent()
            s.deliver(offer(glareId))
            s.deliver(.ice(callId: glareId, candidates: [candidate(1), candidate(2)]))
            s.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
            s.deliver(.ice(callId: glareId, candidates: [candidate(3)]))
            await runCurrent()
            s.releaseStart()
            await runCurrent()
            let l = try live(m)
            #expect(l.direction == .incoming && l.callId == glareId, "lost \(lost)")
            #expect(s.sent.contains("answer(\(glareId))"))
            let engine = engines.last
            // The two held before the glare's end wait with the offer; the one after it reaches the answered call.
            let added = engine.calls.filter { $0.hasPrefix("addRemoteCandidates") }
            #expect(added == ["addRemoteCandidates(2)", "addRemoteCandidates(1)"], "lost \(lost)")
        }
    }

    /// Live: the call placed, the winner's offer and candidates come while it rings, then the glare's end answers the winner.
    @Test func aGlareWinnersLiveCandidatesReachItsAnsweredCall() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1), candidate(2)]))
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(try live(m).callId == glareId)
        #expect(engines.last.calls.filter { $0.hasPrefix("addRemoteCandidates") } == ["addRemoteCandidates(2)"])
    }

    /// The call ends another way (declined), and the held offer rings: its candidates wait for its answer.
    @Test func aHeldOffersCandidatesGoWithItWhenItRings() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1)]))
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try live(m).phase == .incoming && live(m).callId == glareId)
        m.answer()
        await runCurrent()
        #expect(engines.last.calls.filter { $0.hasPrefix("addRemoteCandidates") } == ["addRemoteCandidates(1)"])
    }

    /// The held offer ends (its caller hung up): its candidates are dropped with it, and a later glare offer from the same
    /// connection starts with none.
    @Test func aHeldOfferThatEndsTakesItsCandidatesWithIt() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1)]))
        await runCurrent()
        #expect(m.session?.glareIce.count == 1)
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        #expect(m.session?.glareOffer == nil && m.session?.glareIce.isEmpty == true)
        signalling.deliver(offer(otherId))
        await runCurrent()
        #expect(m.session?.glareIce.isEmpty == true, "another offer keeps none of the first one's")
    }

    /// Not only a glare's: a candidate that comes while the answer is being applied (after the waiting ones were taken, before
    /// the remote description is in) is added once it is, incoming or outgoing.
    @Test func aCandidateThatComesWhileTheAnswerIsAppliedIsAddedAfterIt() async throws {
        let m = machine()
        signalling.deliver(offer())
        await runCurrent()
        m.answer()
        signalling.deliver(.ice(callId: callId, candidates: [candidate(1)]))
        await runCurrent()
        #expect(engines.last.calls.filter { $0.hasPrefix("addRemoteCandidates") } == ["addRemoteCandidates(1)"])
        #expect(m.session?.pendingRemote.isEmpty == true)

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        try await placed(m2)
        s2.deliver(answerEvent().0)
        s2.deliver(.ice(callId: callId, candidates: [candidate(2)]))
        await runCurrent()
        #expect(engines.last.calls.filter { $0.hasPrefix("addRemoteCandidates") } == ["addRemoteCandidates(1)"])
        #expect(m2.session?.pendingRemote.isEmpty == true)
    }

    /// A start refused (`busy`) while the connection's offer and its candidates were held: the offer rings with them.
    @Test func aRefusedStartRingsTheHeldOfferWithItsHeldCandidates() async throws {
        let s = FakeSignalling()
        s.holdStart()
        s.startResult = { throw CallRefusedError(code: "busy") }
        let m = machine(s)
        m.call("conn-1")
        await runCurrent()
        s.deliver(offer(glareId))
        s.deliver(.ice(callId: glareId, candidates: [candidate(1), candidate(2)]))
        await runCurrent()
        s.releaseStart()
        await runCurrent()
        #expect(try live(m).phase == .incoming && live(m).callId == glareId)
        #expect(m.session?.pendingRemote.count == 2)
    }

    /// Another offer from the connection takes the held one's place: the first one's candidates go; the same offer delivered
    /// again keeps them.
    @Test func aHeldOfferReplacedByAnotherDropsItsCandidates() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1)]))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(m.session?.glareIce.count == 1, "the same offer again keeps them")
        signalling.deliver(offer(otherId))
        await runCurrent()
        #expect(m.session?.glareOffer?.callId == otherId)
        #expect(m.session?.glareIce.isEmpty == true)
    }

    /// Kept no further than a call's own waiting candidates are.
    @Test func aHeldOffersCandidatesAreBounded() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        let many = (1...CallMachine.maxPendingCandidates).map(candidate)
        signalling.deliver(.ice(callId: glareId, candidates: many))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1)]))
        await runCurrent()
        #expect(m.session?.glareIce.count == CallMachine.maxPendingCandidates)
    }

    /// The glare's end came before the winner's offer: the winner's candidates in between are kept and go with its answer.
    @Test func aGlareWinnersCandidatesBeforeItsOfferReachItsAnsweredCall() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        signalling.deliver(.ice(callId: glareId, candidates: [candidate(1)]))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(try live(m).callId == glareId)
        #expect(engines.last.calls.filter { $0.hasPrefix("addRemoteCandidates") } == ["addRemoteCandidates(1)"])
    }
}
