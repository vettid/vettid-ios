import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// A call already ringing here when the daily owner check comes due or is held, or the update screen comes up (owner decision
/// 2026-11-18): it stops ringing as a ring that ran out, nothing is sent (another device may still answer), and an answered
/// call goes on.
extension CallsControllerTests {
    func ringing() async throws -> CallsController {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        vault.gatewayFake.answerKeys = CallKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 200)
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
        return c
    }

    func stoppedAsMissed(_ c: CallsController) throws {
        guard case .ended(let e) = c.state else { throw WrongState(state: c.state) }
        #expect(e.reason == .missed)
        #expect(vault.gatewayFake.ended.isEmpty && !vault.gatewayFake.asked.contains { $0.hasPrefix("end(") })
    }

    @Test func aRingingCallStopsWhenTheOwnerCheckComesDue() async throws {
        let c = try await ringing()
        await clock.advance(by: 2000)
        guard case .live = c.state else { throw WrongState(state: c.state) }
        vault.ownerCheckShowing = true
        await clock.advance(by: 600)
        try stoppedAsMissed(c)
    }

    @Test func aRingingCallStopsWhenTheUpdateScreenComesUp() async throws {
        let c = try await ringing()
        vault.updateShowing = true
        await clock.advance(by: 600)
        try stoppedAsMissed(c)
    }

    /// The stop reaches CallKit as a missed call (`unanswered`), so its screen goes and Recents shows it missed.
    @Test func aRingStoppedByTheOwnerCheckEndsInCallKitAsUnanswered() async throws {
        let r = try await ringing(FakeMicrophone(.granted))
        let uuid = try #require(r.kit.uuid)
        vault.ownerCheckShowing = true
        await clock.advance(by: 600)
        await settle()
        try stoppedAsMissed(r.controller)
        #expect(r.kit.events.contains(.ended(uuid, .unanswered)), "\(r.kit.events)")
    }

    @Test func anAnsweredCallGoesOnWhenTheOwnerCheckComesDue() async throws {
        let c = try await ringing()
        c.answer()
        await clock.advance(by: 200)
        guard case .live(let l) = c.state, l.phase != .incoming else { throw WrongState(state: c.state) }
        vault.ownerCheckShowing = true
        await clock.advance(by: 2000)
        if case .ended(let e) = c.state { #expect(e.reason != .missed, "not ended by the check") }
    }
}
