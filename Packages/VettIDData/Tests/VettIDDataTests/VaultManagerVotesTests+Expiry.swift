import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// IOS-PLAN §6.6: when the background time iOS gave runs out, the collection stops at once
/// (``VaultManager/backgroundExpired(began:)``), not in the cancelled work's own time; a vote window's lock on its way keeps
/// the work running until then.
extension VaultManagerVotesTests {
    /// Opened, a vote cast whose window lock never answers, and the background work under way waiting for it (with
    /// [held], a call holding the collection when it began). Returns the work and the leaving's mark.
    func backgroundWaiting(held: VaultManagerHoldCollectionTests.Hold? = nil) async throws -> (Task<Void, Never>, Int) {
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.availability == .available })
        service.loseAnswers(["credential.lock"])
        _ = try? await m.votes.cast(VoteKey(connectionID: "conn-1", proposalID: Self.pid), choiceID: "yes", password: password)
        #expect(m.votes.windowLock != nil)
        if let held { m.holdCollection { held.on } }
        let began = m.foregroundReturns
        let background = Task { @MainActor in await m.onBackground(budget: .seconds(5)) }
        #expect(await eventually { m.backgroundWorks == 1 && m.session?.device.collecting == true })
        return (background, began)
    }

    @Test func theExpirationStopsTheCollectionAtOnce() async throws {
        defer { phone.close() }
        let (background, began) = try await backgroundWaiting()
        m.backgroundExpired(began: began)
        #expect(m.session == nil && m.backgrounded, "stopped synchronously, before the work ends")
        let lifecycle = m.moveFlags.book.lifecycle
        m.backgroundExpired(began: began)
        #expect(m.moveFlags.book.lifecycle == lifecycle, "not twice")
        background.cancel()
        await background.value
        #expect(m.moveFlags.book.lifecycle == lifecycle, "the work's end does not finish the background again")
    }

    @Test func anExpirationAfterTheReturnStopsNothing() async throws {
        defer { phone.close() }
        let (background, began) = try await backgroundWaiting()
        m.onForeground()
        m.backgroundExpired(began: began)
        #expect(m.session?.device.collecting == true && !m.backgrounded)
        background.cancel()
        await background.value
        #expect(m.session != nil)
    }

    /// A call that held the collection when the app left, and ended during the work: the expiration stops it. A call still
    /// live keeps it.
    @Test func anExpirationAfterTheCallEndedStopsTheCollection() async throws {
        defer { phone.close() }
        let hold = VaultManagerHoldCollectionTests.Hold(true)
        let (background, began) = try await backgroundWaiting(held: hold)
        #expect(m.heldBackground == began)
        m.backgroundExpired(began: began)
        #expect(m.session?.device.collecting == true, "the live call keeps it")
        hold.on = false
        m.backgroundExpired(began: began)
        #expect(m.session == nil && m.backgrounded)
        background.cancel()
        await background.value
    }
}
