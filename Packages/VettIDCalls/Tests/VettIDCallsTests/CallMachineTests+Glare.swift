import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

extension CallMachineTests {
    func hasSent(_ s: FakeSignalling, _ prefix: String) -> Bool { s.sent.contains { $0.hasPrefix(prefix) } }

    /// An offer of the connection with an exp of its own (the default helper's is 45 s).
    func offerUntil(_ id: String, _ exp: Date) -> SignalEvent {
        .offer(CallOffer(
            callId: id, connectionId: "conn-1", sdp: "v=0\r\ns=offer\r\n", exp: exp, ringFor: .rounded(seconds: exp.timeIntervalSince(t0)),
            servers: [], suite: .aes128Gcm
        ))
    }

    /// (C2, VAULT-MESSAGING §10.10 "Glare", decision D21 a) This device's outgoing call lost a glare: the vault ends it `busy`
    /// with `superseded_by` and rings the connection's own call, which this device answers without asking, whichever of the two
    /// arrives first. Nothing is sent for the lost call, and "busy" is never shown.
    @Test func aLostGlareAnswersTheWinningCall() async throws {
        for offerFirst in [false, true] {
            let s = FakeSignalling()
            let m = machine(s)
            m.call("conn-1")
            await runCurrent()
            let lost = engines.last
            if offerFirst { s.deliver(offer(glareId)) }
            s.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
            if !offerFirst {
                await runCurrent()
                // Waiting for the winner: the outgoing screen stays, and its media is let go.
                #expect(try live(m).direction == .outgoing)
                #expect(lost.closed, "the lost call's engine is closed")
                s.deliver(offer(glareId))
            }
            await runCurrent()
            let l = try live(m)
            #expect(l.direction == .incoming, "offer first: \(offerFirst)")
            #expect(l.callId == glareId)
            #expect(l.phase == .connecting)
            #expect(s.sent.contains("answer(\(glareId))"))
            #expect(!hasSent(s, "end("), "nothing sent for the lost call")
            #expect(!hasSent(s, "ringing("), "no ringing for a call answered at once")
        }
    }

    /// A lost glare whose winner never comes ends as busy at the ring timer, with nothing sent; a hang-up sends nothing.
    @Test func aLostGlareWithoutTheWinningOfferShowsBusy() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(try live(m).direction == .outgoing)
        await advance(46_000)
        await runCurrent()
        #expect(try ended(m).reason == .busy)
        #expect(!hasSent(signalling, "end("))

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        m2.hangUp()
        await runCurrent()
        #expect(try ended(m2).reason == .hungUp)
        #expect(!hasSent(s2, "end("))
        // The winner then rings as any call: the member hung up on the wait, not on the call.
        s2.deliver(offer(glareId))
        await runCurrent()
        #expect(try live(m2).phase == .incoming)
    }

    /// Not a glare: an offer from another connection does not interrupt the call; a plain `busy` (no `superseded_by`) shows
    /// busy; a `superseded_by` naming another call than the offer held does not answer that offer.
    @Test func onlyTheNamedOfferOfTheSameConnectionIsAnsweredForAGlare() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId, connectionId: "conn-2"))
        signalling.deliver(.end(callId: callId, reason: CallReason.busy))
        await runCurrent()
        #expect(try ended(m).reason == .busy)
        #expect(!hasSent(signalling, "answer("))

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(offer(otherId))
        s2.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(try live(m2).direction == .outgoing)
        #expect(!hasSent(s2, "answer("))
        s2.deliver(offer(glareId))
        await runCurrent()
        #expect(try live(m2).callId == glareId)
        #expect(try live(m2).phase == .connecting)
    }

    /// The connection's own offer held while this device's call rang to it is not lost when that call ends another way
    /// (declined there): it rings.
    @Test func aHeldOfferRingsWhenTheOutgoingCallEndsOtherwise() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try live(m).direction == .incoming)
        #expect(try live(m).phase == .incoming)
        #expect(try live(m).callId == glareId)
    }

    /// A lock never rings the connection's held offer (a call rings only while the vault is open here), and so never declines
    /// it unseen; nor does the member's own hang-up.
    @Test func aLockNeverRingsTheHeldOffer() async throws {
        for lock in [true, false] {
            let s = FakeSignalling()
            let m = machine(s)
            m.call("conn-1")
            await runCurrent()
            s.deliver(offer(glareId))
            await runCurrent()
            if lock { m.vaultLocking() } else { m.hangUp() }
            await runCurrent()
            guard case .ended = m.state else { throw WrongState(state: m.state) }
            #expect(!hasSent(s, "ringing(") && !hasSent(s, "end(\(glareId)"))
            if lock {
                m.vaultLocking()
                await runCurrent()
                #expect(!hasSent(s, "end(\(glareId)"))
            }
        }
    }

    /// A held offer whose caller hung up, or one held while the call was answered, is not rung afterwards.
    @Test func aHeldOfferThatEndedOrAnAnsweredCallRingsNothingAfter() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try ended(m).reason == .declined)

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(offer(glareId))
        s2.deliver(answerEvent().0)
        await runCurrent()
        #expect(try live(m2).phase == .connecting)
        s2.deliver(.end(callId: callId, reason: CallReason.hangup))
        await runCurrent()
        #expect(try ended(m2).reason == .peerHungUp)
    }

    /// A held offer whose caller hung up is not held again when its offer is delivered once more: it never rings.
    @Test func aHeldOfferThatEndedIsNotHeldAgain() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offer(glareId))
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        signalling.deliver(offer(glareId))
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        #expect(!hasSent(signalling, "ringing(\(glareId)"))
    }

    /// An offer that arrives while `call.start` is out, and turns out to carry the call's own id, is not held as another call:
    /// the call's own end still ends it.
    @Test func anOfferWithTheCallsOwnIdIsNotHeldOnceTheCallHasIt() async throws {
        signalling.holdStart()
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        #expect(try live(m).phase == .starting)
        signalling.deliver(offer(callId))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try live(m).callId == callId)
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try ended(m).reason == .declined)
    }

    /// X's end delivered twice while the lost glare waits changes nothing; the winner is still answered.
    @Test func aSecondEndOfTheLostCallChangesNothing() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(try live(m).direction == .outgoing)
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(try live(m).callId == glareId)
        #expect(try live(m).phase == .connecting)
    }

    /// The vault refused `call.start` (`busy`: it rang the connection's call first): the call held meanwhile rings here, it is
    /// not answered by itself. The member's own hang-up or a lock in STARTING rings nothing.
    @Test func aRefusedStartRingsTheHeldOfferButTheMembersOwnEndDoesNot() async throws {
        let s = FakeSignalling()
        s.holdStart()
        s.startResult = { throw CallRefusedError(code: "busy") }
        let m = machine(s)
        m.call("conn-1")
        await runCurrent()
        s.deliver(offer(glareId))
        await runCurrent()
        s.releaseStart()
        await runCurrent()
        #expect(try live(m).direction == .incoming)
        #expect(try live(m).phase == .incoming)
        #expect(try live(m).callId == glareId)
        #expect(!hasSent(s, "answer("))

        for lock in [false, true] {
            let s2 = FakeSignalling()
            s2.holdStart()
            let m2 = machine(s2)
            m2.call("conn-1")
            await runCurrent()
            s2.deliver(offer(glareId))
            await runCurrent()
            if lock { m2.vaultLocking() } else { m2.hangUp() }
            await runCurrent()
            guard case .ended = m2.state else { throw WrongState(state: m2.state) }
            #expect(!hasSent(s2, "ringing("), "lock \(lock)")
        }
    }

    /// A held offer past its exp is neither rung when the call ends otherwise nor answered for a glare.
    @Test func anExpiredHeldOfferIsNeitherRungNorAnswered() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(offerUntil(glareId, at(5_000)))
        await runCurrent()
        await advance(6_000)
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try ended(m).reason == .declined)

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(offerUntil(glareId, at(clock.ms + 5_000)))
        await runCurrent()
        await advance(6_000)
        s2.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(!hasSent(s2, "answer("))
        #expect(try live(m2).direction == .outgoing, "waits for the winner as when it is not here")
    }

    /// Not a glare: `superseded_by` with another reason than `busy`, or naming a call that is not lower; an offer with the
    /// outgoing call's own id. None of them is answered by itself, and the call's own end still ends it.
    @Test func whatIsNotAGlareIsNotAnswered() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.end(callId: callId, reason: CallReason.decline, supersededBy: glareId))
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(try live(m).phase == .incoming)
        #expect(!hasSent(signalling, "answer("))

        let s2 = FakeSignalling()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: "01JB2Z6V9K3M4N5P6Q7R8S9T5Z"))
        await runCurrent()
        #expect(try ended(m2).reason == .busy, "a higher id is no glare's winner")

        let s3 = FakeSignalling()
        let m3 = machine(s3)
        m3.call("conn-1")
        await runCurrent()
        s3.deliver(offer(callId))
        s3.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        #expect(try ended(m3).reason == .declined)
    }

    /// While a lost glare waits: an engine failure sends nothing; the winner's own end ends the wait, and its late offer is
    /// ignored.
    @Test func whileALostGlareWaits() async throws {
        let m = machine()
        try await placed(m)
        let lost = engines.last
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        lost.emit(.failed("test"))
        await runCurrent()
        #expect(try live(m).direction == .outgoing)
        #expect(!hasSent(signalling, "end("))
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(!hasSent(signalling, "end("))
        signalling.deliver(offer(glareId))
        await runCurrent()
        guard case .ended = m.state else { throw WrongState(state: m.state) }
    }
}
