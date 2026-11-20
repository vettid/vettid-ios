import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// (chosen; not in the spec: as vettid-android #411) A continued opening's catch-up that failed is tried once more by the
/// lists' read (``FeedManager/readOnIfOwed()``), and only once: counted by the `feed.list` requests that reach the vault.
extension VaultManagerWaitingAsksTests {
    /// The `feed.list` requests that reached the vault so far.
    var feedLists: Int { service.requestsSeen.filter { $0 == "feed.list" }.count }

    /// Held during a failing release check, then a blip and a return whose catch-up is refused [failures] times.
    /// Returns the `feed.list` requests made from the return on.
    func returnWithFailedCatchUps(_ failures: Int) async throws -> Int {
        let id = try await connected()
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        #expect(await eventually { m.feed.heldEvents.count == 1 })
        try await blip()
        service.release3ListedAs = 3
        service.refuse("feed.list", with: "retry", times: failures)
        let before = feedLists
        try await back()
        #expect(await eventually { !m.releaseUpdate.checking })
        try await quiet()
        return feedLists - before
    }

    /// The first catch-up fails; the lists' read reads on once more, which succeeds, and what was held comes after it.
    @Test func aFailedCatchUpIsReadOnOnceMore() async throws {
        defer { phone.close() }
        let lists = try await returnWithFailedCatchUps(1)
        #expect(lists == 2, "the failed catch-up, then the one more: \(lists)")
        #expect(!m.feed.catchUpOwed && m.feed.heldEvents.isEmpty)
        #expect(live.count == 1, "\(live)")
    }

    /// Both fail: the second is not tried again (no loop); what was held waits for the next event or read.
    @Test func aSecondFailedCatchUpIsNotTriedAgain() async throws {
        defer { phone.close() }
        let lists = try await returnWithFailedCatchUps(2)
        #expect(lists == 2, "the failed catch-up and its one retry, no more: \(lists)")
        #expect(m.feed.catchUpOwed && m.feed.heldEvents.count == 1)
        #expect(live.isEmpty, "\(live)")
    }
}
