import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// (Rule 3) The release check and the notifications, end to end: an item that arrives while a failing check holds the
/// features notifies once the check passes, and a passed owner check's waiting-asks replay that comes due meanwhile runs
/// after the lift's reads.
extension VaultManagerWaitingAsksTests {
    /// A re-read that no longer verifies the vault's release: the check holds the features again (fail closed).
    func failReleaseCheck() async {
        service.release3ListedAs = 2
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.checking && m.featuresGated())
    }

    /// A read that verifies it: the gate lifts.
    func passReleaseCheck() async {
        service.release3ListedAs = 3
        await m.releaseUpdate.refreshOffer()
        #expect(!m.releaseUpdate.checking && !m.featuresGated())
    }

    @Test func anItemDuringAFailingReleaseCheckNotifiesOnceItPasses() async throws {
        defer { phone.close() }
        let id = try await connected()
        await failReleaseCheck()
        _ = try service.feedItemArrives("message.received", connectionID: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(live.isEmpty, "nothing while the check fails")
        await passReleaseCheck()
        #expect(await eventually { live.count == 1 }, "\(live)")
        try await settled()
        #expect(live.count == 1 && replays.isEmpty, "once")
    }

    @Test func aCheckPassedElsewhereWhileAFailingReleaseCheckHoldsReplaysAfterTheLift() async throws {
        defer { phone.close() }
        let id = try await connected()
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        // The test vault sends `feed.event` for these while this phone is held (the vault sends none then): whenever they come,
        // nothing that comes while held is kept for later, so none notifies as a new arrival at the lift.
        let expected = try asksWhileHeld(id)
        await failReleaseCheck()
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        try await Task.sleep(for: .milliseconds(300))
        #expect(replays.isEmpty, "nothing while the release check fails")
        await passReleaseCheck()
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected && live.isEmpty, "once, and nothing else")
    }
}
