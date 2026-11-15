import Foundation
import Testing
import VettIDVault
@testable import VettIDCalls

/// `call.start` placed a call that can no longer be made (``CallLostError``): the machine ends it at the vault, through the
/// ends a lock waits for, with the reason its session calls for.
extension CallMachineTests {
    /// The member's call: it shows failed at once (not ringing out), and the vault is told the call failed.
    @Test func aLostCallShowsFailedAndIsEndedAtTheVault() async throws {
        let m = machine()
        signalling.startResult = { throw CallLostError(callId: callId) }
        m.call("conn-1")
        await runCurrent()
        let e = try ended(m)
        #expect(e.reason == .failed && e.callId == callId)
        #expect(engines.last.closed)
        #expect(signalling.sent.filter { $0.hasPrefix("end") } == ["end(\(callId), failed)"])
        #expect(m.pendingEnds == 0)
    }

    /// The end goes through the ends a lock waits for: counted while it is on its way.
    @Test func aLostCallsEndIsWaitedForByALock() async throws {
        let m = machine()
        signalling.holdEnd()
        signalling.startResult = { throw CallLostError(callId: callId) }
        m.call("conn-1")
        await runCurrent()
        #expect(m.pendingEnds == 1)
        signalling.releaseEnd()
        await runCurrent()
        #expect(m.pendingEnds == 0)
    }

    /// The member hung up while the vault was answering: the lost call is ended as hung up, once, as a placed one would be.
    @Test func aLostCallTheMemberHungUpIsEndedAsHungUp() async throws {
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        m.hangUp()
        await runCurrent()
        #expect(try ended(m).reason == .hungUp)
        signalling.startResult = { throw CallLostError(callId: callId) }
        signalling.releaseStart()
        await runCurrent()
        #expect(signalling.sent.filter { $0.hasPrefix("end") } == ["end(\(callId), hangup)"])
        #expect(try ended(m).reason == .hungUp, "the ended call is not shown failed after the fact")
    }

    /// The vault's own end for the lost call is held by the machine (it came before `call.start` was answered): it says how
    /// the call ended, and nothing more is sent.
    @Test func aLostCallEndedByAHeldEndShowsThatEnd() async throws {
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: CallReason.decline))
        await runCurrent()
        signalling.startResult = { throw CallLostError(callId: callId) }
        signalling.releaseStart()
        await runCurrent()
        let e = try ended(m)
        #expect(e.reason == .declined && e.callId == callId)
        #expect(!hasSent(signalling, "end("), "the vault ended it")
    }

    /// The held end is a glare's, and the winner's offer is held too: the winning call is answered, as for a placed call.
    @Test func aLostCallThatLostAGlareAnswersTheWinner() async throws {
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(offer(glareId))
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        signalling.startResult = { throw CallLostError(callId: callId) }
        signalling.releaseStart()
        await runCurrent()
        let l = try live(m)
        #expect(l.direction == .incoming && l.callId == glareId)
        #expect(signalling.sent.contains("answer(\(glareId))"))
        #expect(!hasSent(signalling, "end("), "nothing sent for the lost call")
    }

    /// A held glare end, and the winner's offer never comes: the wait ends busy at the ring timer, with nothing sent.
    @Test func aLostCallWaitingForAGlaresWinnerEndsBusyWhenItNeverComes() async throws {
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: CallReason.busy, supersededBy: glareId))
        await runCurrent()
        signalling.startResult = { throw CallLostError(callId: callId) }
        signalling.releaseStart()
        await runCurrent()
        let l = try live(m)
        #expect(l.direction == .outgoing && l.callId == callId && l.phase == .calling, "the wait is shown")
        await advance(CallTimings().minRing.wholeMilliseconds + 1_000)
        await runCurrent()
        #expect(try ended(m).reason == .busy)
        #expect(!hasSent(signalling, "end("))
    }
}
