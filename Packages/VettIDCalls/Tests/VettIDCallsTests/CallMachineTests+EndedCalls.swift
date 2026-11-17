import Foundation
import Testing
import VettIDVault
@testable import VettIDCalls

/// Calls that ended before their offer came, or while a start was out, or that rang here and ended: their offer is not rung
/// or answered after (``CallMachine/endedWinners``, ``CallMachine/endedOthers``; VAULT-MESSAGING §8.4 gives no order).
extension CallMachineTests {
    func endedId(_ n: Int) -> String { String(format: "01JB2Z6V9K3M4N5P6Q7R8S9%03d", n) }

    /// A winner known only from another call's end is kept among the winners once the glare ends missed: later calls' many
    /// ends do not push it out, and its offer delivered after them is not rung.
    @Test func aWinnerFoundAmongOtherEndsIsKeptAmongTheWinners() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        try await placed(m)
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        #expect(!hasSent(signalling, "ringing(") && !hasSent(signalling, "answer("))
    }

    /// Another call's end held while the start was out is remembered when the call ends before it has its id (refused, or
    /// hung up): that call's offer coming after is not rung.
    @Test func anEndHeldDuringAStartThatEndsIsRemembered() async throws {
        for how in ["refused", "hung up", "locked"] {
            let s = FakeSignalling()
            s.holdStart()
            if how == "refused" { s.startResult = { throw CallRefusedError(code: "busy") } }
            let m = machine(s)
            m.call("conn-1")
            await runCurrent()
            s.deliver(.end(callId: glareId, reason: CallReason.hangup))
            await runCurrent()
            switch how {
            case "refused": s.releaseStart()
            case "hung up": m.hangUp()
            default: m.vaultLocking()
            }
            await runCurrent()
            guard case .ended = m.state else { throw WrongState(state: m.state) }
            // Among the other calls', not the glare winners' (it was not one).
            #expect(m.endedOthers.contains(glareId) && !m.endedWinners.contains(glareId), "\(how)")
            s.deliver(offer(glareId))
            await runCurrent()
            guard case .ended = m.state else { throw WrongState(state: m.state) }
            #expect(!hasSent(s, "ringing("), "\(how)")
            if how != "refused" { s.releaseStart() }
            await runCurrent()
        }
    }

    /// Held ends left once the replay has finished the call (declined): another call's end among them is still remembered,
    /// so that call's offer coming after is not rung.
    @Test func endsHeldBehindTheOneThatFinishesTheCallAreRemembered() async throws {
        signalling.holdStart()
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        signalling.deliver(.end(callId: otherId, reason: CallReason.hangup))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        #expect(m.endedOthers.contains(otherId))
        signalling.deliver(offer(otherId))
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        #expect(!hasSent(signalling, "ringing("))
    }

    /// The same on the lost path: the start lost with no end carried, the held decline finishes the call, and another call's
    /// end held after it is still remembered.
    @Test func endsHeldBehindTheOneThatFinishesALostCallAreRemembered() async throws {
        signalling.holdStart()
        signalling.startResult = { throw CallLostError(callId: callId) }
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        signalling.deliver(.end(callId: otherId, reason: CallReason.hangup))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .declined)
        #expect(m.endedOthers.contains(otherId))
        signalling.deliver(offer(otherId))
        await runCurrent()
        #expect(!hasSent(signalling, "ringing("))
    }

    /// Another call's glare end held with its winner's end (the member's other device lost a glare) does not put that
    /// winner among this device's glare winners.
    @Test func anotherCallsGlareEndDoesNotFillTheWinners() async throws {
        signalling.holdStart()
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: endedId(2), reason: CallReason.hangup))
        signalling.deliver(.end(callId: endedId(5), reason: CallReason.busy, supersededBy: endedId(2)))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(!m.endedWinners.contains(endedId(2)))
        #expect(m.endedOthers.contains(endedId(2)))
    }

    /// The winner's end, then more other calls' ends than ``CallMachine/endedOthers`` keeps, then the glare's end, all held
    /// during the start; placed: missed at once, the winner kept among the winners, and its late offer not answered.
    @Test func aHeldWinnersEndIsNotPushedOutByTheOtherEndsHeldWithIt() async throws {
        signalling.holdStart()
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(!hasSent(signalling, "answer(") && !hasSent(signalling, "ringing("))
    }

    /// Lost, the glare's end carried by the start (applied after the replay), the winner's own end held but pushed out of
    /// ``CallMachine/endedOthers`` by other calls' ends held after it: missed at once all the same (``settleLost``).
    @Test func aLostGlareWhoseHeldWinnersEndWasPushedOutIsMissed() async throws {
        signalling.holdStart()
        signalling.startResult = {
            throw CallLostError(callId: callId, end: .init(reason: CallReason.busy, supersededBy: glareId))
        }
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        #expect(!hasSent(signalling, "end("))
    }

    /// An incoming call that rang here and ended: its offer delivered again is not rung.
    @Test func anIncomingCallThatEndedDoesNotRingAgain() async throws {
        let m = machine()
        signalling.deliver(offer(otherId))
        await runCurrent()
        signalling.deliver(.end(callId: otherId, reason: CallReason.hangup))
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        signalling.sent.removeAll()
        signalling.deliver(offer(otherId))
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(signalling.sent.isEmpty)
    }

    /// Other calls' ends: the oldest goes past the bound, and one delivered again counts as the newest.
    @Test func otherCallsEndsAreBoundedAndTheNewestKept() async throws {
        let m = machine()
        try await placed(m)
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        await runCurrent()
        #expect(m.endedOthers.count == CallMachine.maxEndedOthers)
        #expect(!m.endedOthers.contains(endedId(0)) && m.endedOthers.last == endedId(CallMachine.maxEndedOthers))
        signalling.deliver(.end(callId: endedId(1), reason: CallReason.hangup))
        await runCurrent()
        #expect(m.endedOthers.count == CallMachine.maxEndedOthers && m.endedOthers.last == endedId(1))
        #expect(m.endedOthers.filter { $0 == endedId(1) }.count == 1)
    }

    /// One delivered again is kept once, as the newest.
    @Test func anOtherCallsEndDeliveredAgainIsKeptOnceAsTheNewest() async throws {
        let m = machine()
        try await placed(m)
        for n in [1, 2, 1] { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        await runCurrent()
        #expect(m.endedOthers == [endedId(2), endedId(1)])
    }

    /// An end that comes once the start's held events are full is remembered all the same.
    @Test func anEndPastTheFullHeldEventsIsRemembered() async throws {
        signalling.holdStart()
        let m = machine()
        m.call("conn-1")
        await runCurrent()
        for _ in 0..<CallMachine.maxEarly { signalling.deliver(.ice(callId: endedId(999), candidates: [])) }
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        #expect(m.endedOthers.contains(glareId))
    }

    /// An idle phone gets a call's end before its offer (VAULT-MESSAGING §8.4 gives no order): the offer coming after is not
    /// rung, and nothing is sent.
    @Test func anEndWithNoSessionIsRememberedAndItsLateOfferNotRung() async throws {
        let m = machine()
        await runCurrent()
        signalling.deliver(.end(callId: otherId, reason: CallReason.hangup))
        await runCurrent()
        #expect(m.endedOthers.contains(otherId))
        signalling.deliver(offer(otherId))
        await runCurrent()
        guard case .idle = m.state else { throw WrongState(state: m.state) }
        #expect(signalling.sent.isEmpty)
    }

    /// The winner's end came while the phone was idle; then this phone's call was placed and lost a glare to it, with more
    /// other calls' ends held than are kept: the winner, already ended, is kept among the winners before the replay, and the
    /// call is missed at once.
    @Test func aWinnerEndedBeforeTheCallIsKeptAmongTheWinnersBeforeTheReplay() async throws {
        let m = machine()
        await runCurrent()
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(!hasSent(signalling, "answer(") && !hasSent(signalling, "ringing("))
    }

    /// As above, but the start comes back lost and the glare's end is the one it carries (``CallLostError``), not held: the
    /// winner, known to have ended only among the other calls' ends, is kept among the winners before the replay of the many
    /// ends held, so the call is missed at once and the winner's late offer is not answered or rung.
    @Test func aWinnerEndedBeforeALostCallIsKeptAmongTheWinnersBeforeTheReplay() async throws {
        let m = machine()
        await runCurrent()
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        for n in 0...CallMachine.maxEndedOthers { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        await runCurrent()
        signalling.startResult = {
            throw CallLostError(callId: callId, end: .init(reason: CallReason.busy, supersededBy: glareId))
        }
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        // The case this is about: the other calls' ends replayed have pushed the winner out of the other calls' list.
        #expect(!m.endedOthers.contains(glareId))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(!hasSent(signalling, "answer(") && !hasSent(signalling, "ringing("))
        #expect(!hasSent(signalling, "end("))
    }

    /// The same with the held events full: the call's own glare end, which comes past them, is not held (it is the one the
    /// start carries), and the winner known to have ended is kept among the winners all the same.
    @Test func aWinnerEndedBeforeALostCallIsKeptWithTheHeldEventsFull() async throws {
        let m = machine()
        await runCurrent()
        signalling.deliver(.end(callId: glareId, reason: CallReason.hangup))
        await runCurrent()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        for n in 0..<CallMachine.maxEarly { signalling.deliver(.end(callId: endedId(n), reason: CallReason.hangup)) }
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        signalling.startResult = {
            throw CallLostError(callId: callId, end: .init(reason: CallReason.busy, supersededBy: glareId))
        }
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .missed)
        #expect(m.endedWinners.contains(glareId))
        // The case this is about: the other calls' ends replayed have pushed the winner out of the other calls' list.
        #expect(!m.endedOthers.contains(glareId))
        signalling.deliver(offer(glareId))
        await runCurrent()
        #expect(!hasSent(signalling, "answer(") && !hasSent(signalling, "ringing("))
        #expect(!hasSent(signalling, "end("))
    }

    /// The carried end of another kind, or naming a winner that is not lower, is no glare's: it does not fill the winners.
    @Test func aCarriedEndThatIsNoGlaresDoesNotFillTheWinners() async throws {
        for (reason, by) in [(CallReason.decline, glareId), (CallReason.busy, "01JB2Z6V9K3M4N5P6Q7R8S9ZZZ")] {
            let s = FakeSignalling()
            let m = machine(s)
            await runCurrent()
            s.deliver(.end(callId: by, reason: CallReason.hangup))
            await runCurrent()
            s.holdStart()
            m.call("conn-1")
            await runCurrent()
            s.startResult = { throw CallLostError(callId: callId, end: .init(reason: reason, supersededBy: by)) }
            s.releaseStart()
            await runCurrent()
            #expect(!m.endedWinners.contains(by), "\(reason) by \(by)")
            m.stop()
        }
    }
}
