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
}
