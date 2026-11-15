import Foundation
import Testing
@testable import VettIDCalls

/// iOS may end its ring screen after a failed answer action (the microphone gate refused CallKit's Accept). Then CallKit and the
/// machine, still ringing, would disagree: the call must stop ringing here as missed, with nothing sent, not ring on in the app.
extension CallKitCoordinatorTests {
    private func refusing(_ m: CallMachine) -> CallKitCoordinator {
        let c = CallKitCoordinator(
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { true },
            mayAnswer: { _ in false }
        )
        kit.delegate = c
        return c
    }

    private func ringing(_ m: CallMachine, _ c: CallKitCoordinator) async throws -> UUID {
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        return try #require(kit.uuid)
    }

    private func missed(_ m: CallMachine) throws {
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .missed)
        #expect(!signalling.sent.contains { $0.hasPrefix("end(") || $0.hasPrefix("answer(") }, "nothing was sent: no decline, no answer")
    }

    @Test func aRefusedAnswerKeepsTheCallRinging() async throws {
        let m = machine()
        let c = refusing(m)
        let uuid = try await ringing(m, c)
        #expect(!c.performAnswer(uuid: uuid))
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.phase == .incoming)
        c.stop()
    }

    @Test func iosEndingItsScreenAfterARefusedAnswerEndsTheCallAsMissed() async throws {
        let m = machine()
        let c = refusing(m)
        let uuid = try await ringing(m, c)
        #expect(!c.performAnswer(uuid: uuid))
        #expect(c.performEnd(uuid: uuid))
        await clock.runCurrent()
        await settle()
        try missed(m)
        #expect(kit.actions.isEmpty)
        c.stop()
    }

    @Test func aResetAfterARefusedAnswerEndsTheCallAsMissed() async throws {
        let m = machine()
        let c = refusing(m)
        let uuid = try await ringing(m, c)
        #expect(!c.performAnswer(uuid: uuid))
        c.providerDidReset()
        await clock.runCurrent()
        await settle()
        try missed(m)
        c.stop()
    }

    /// Without a refused answer the member's end in CallKit is a decline, as before.
    @Test func anEndWithoutARefusedAnswerStillDeclines() async throws {
        let m = machine()
        let c = refusing(m)
        let uuid = try await ringing(m, c)
        #expect(c.performEnd(uuid: uuid))
        await clock.runCurrent()
        await settle()
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .declinedHere)
        c.stop()
    }
}
