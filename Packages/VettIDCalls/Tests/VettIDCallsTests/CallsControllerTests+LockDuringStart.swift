import Foundation
import Testing
import VettIDCrypto
@testable import VettIDVault
@testable import VettIDCalls

/// A lock while `call.start` is on its way: the call it places is ended at once, by its start's id, and again when the start's
/// answer comes (a duplicate the vault ignores); the lock waits for both (bounded as before), or the other member's phone
/// would ring for a vault that is locked.
extension CallsControllerTests {
    @Test func aLockDuringACallsStartWaitsForTheStartAndThenItsHangUp() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let start = Gate(), end = Gate()
        vault.gatewayFake.startGate = start
        vault.gatewayFake.endGate = end
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.asked.contains("start(conn-1)"))
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 500)
        guard case .ended(let e) = c.state, e.reason == .locked else { throw WrongState(state: c.state) }
        #expect(vault.gatewayFake.asked.filter { $0 == "end(\(callId), hangup)" }.count == 1, "ended at once, by its start's id")
        #expect(!done, "the start is still on its way: the lock waits")
        start.open()
        await clock.advance(by: 100)
        #expect(vault.gatewayFake.asked.filter { $0 == "end(\(callId), hangup)" }.count == 2, "and again once the start placed it")
        #expect(!done, "its hang-ups are not with the relay yet")
        end.open()
        end.open()
        await settle()
        await clock.advance(by: 100)
        #expect(done)
        await waiter.value
    }

    @Test func aStartThatDoesNotAnswerHoldsTheLockNoLongerThanTwoSeconds() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.startGate = Gate()
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await settle()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 1950)
        #expect(!done)
        await clock.advance(by: 100)
        #expect(done, "returns at two seconds, the start still on its way")
        await waiter.value
    }

    /// The lock ends the pending call at once (it cannot know the vault will refuse it); once refused, nothing more is sent.
    @Test func aStartTheVaultRefusesEndsTheWaitWithNothingMoreSent() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let start = Gate()
        vault.gatewayFake.startGate = start
        vault.gatewayFake.startResult = { _, _ in throw VaultOpError(type: "call.start", code: "busy", detail: "", body: nil) }
        c.call("conn-1")
        await settle()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 500)
        #expect(!done)
        start.open()
        await settle()
        await clock.advance(by: 100)
        #expect(done)
        #expect(vault.gatewayFake.asked.filter { $0.hasPrefix("end(") } == ["end(\(callId), hangup)"], "only the lock's own end")
        await waiter.value
    }

    /// A lock while the offer is still being made: the call ends here and no `call.start` goes after the lock, so there is
    /// nothing to end and nothing to wait for.
    @Test func aLockWhileTheOfferIsMadeSendsNoStart() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let offer = Gate()
        engines.offerGate = offer
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await settle()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 100)
        #expect(done, "nothing is owed: no start went")
        offer.open()
        await clock.advance(by: 100)
        #expect(!vault.gatewayFake.asked.contains { $0.hasPrefix("start(") }, "no start after the lock")
        await waiter.value
    }

    /// A lock during a start the vault ends meanwhile (`call.start` then says the call is lost): the lock waits for the start,
    /// and for the lost call's end, as for a placed one.
    @Test func aLockDuringAStartThatComesBackLostWaitsForIt() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let start = Gate()
        vault.gatewayFake.startGate = start
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await settle()
        vault.gatewayFake.send(.ended(CallEnded(callId: callId, reason: "busy")))
        await settle()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 500)
        #expect(!done, "the start is still on its way")
        start.open()
        await clock.advance(by: 100)
        #expect(done)
        #expect(c.machine.startsInFlight == 0 && c.machine.pendingEnds == 0)
        await waiter.value
    }

    /// A start that fails in transit (no answer from the vault): the lock ends its call at once, waits for the start, then goes.
    @Test func aLockDuringAStartThatFailsWaitsForItThenGoes() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        let start = Gate()
        vault.gatewayFake.startGate = start
        vault.gatewayFake.startResult = { _, _ in throw StartFailure() }
        c.call("conn-1")
        await settle()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 500)
        #expect(!done)
        start.open()
        await clock.advance(by: 100)
        #expect(done)
        // The lock's own end, at once; the start's failure in transit sends its durable end through `VaultApi`, not the fake.
        #expect(vault.gatewayFake.asked.filter { $0.hasPrefix("end(") } == ["end(\(callId), hangup)"])
        await waiter.value
    }
}
