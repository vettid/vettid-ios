import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The release check after an opening, end to end over ``FakeVaultService`` (owner decisions 2026-11-17: the current
/// release only, fail closed).
extension VaultManagerReleaseUpdateTests {
    /// The vault's release listed under another number (its PCR0 and number do not match) while a newer active release is
    /// listed: behind it, offered as one that has ended.
    @Test func aReleaseListedUnderAnotherNumberIsBehindANewerOne() async throws {
        defer { phone.close() }
        try await setUp()
        service.release3ListedAs = 2
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        #expect(offer.current.number == 3 && offer.target.number == 4 && offer.kind == .ended)
        #expect(m.releaseUpdate.behind && m.releaseUpdate.required)
    }

    /// The same with nothing newer listed: the release cannot be checked, so the check holds (fail closed) and is read
    /// again until the manifest checks it.
    @Test func aReleaseListedUnderAnotherNumberWithNothingNewerHolds() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = false
        #expect(await eventually { !m.releaseUpdate.checking })
        service.release3ListedAs = 2
        m.releaseUpdate.vaultOpened()
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.checkFailed && m.releaseUpdate.holdsFeatures && m.featuresGated())
        service.release3ListedAs = 3
        #expect(await eventually(within: .seconds(10)) { !m.releaseUpdate.checking }, "read again after 2 seconds")
        #expect(!m.releaseUpdate.required && !m.featuresGated())
    }

    /// A foreground read that finds the manifest no longer checks the release, after the opening's check passed: the app
    /// holds again (the gate, the checking screen with what failed), and opens once a read checks it.
    @Test func aForegroundReadThatNoLongerChecksTheReleaseHoldsAgain() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = false
        #expect(await eventually { !m.releaseUpdate.checking })
        #expect(!m.releaseUpdate.required)
        service.release3ListedAs = 2
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.checking && m.releaseUpdate.checkFailed && m.releaseUpdate.required && m.featuresGated())
        service.release3ListedAs = 3
        #expect(await eventually(within: .seconds(10)) { !m.releaseUpdate.checking })
        #expect(!m.releaseUpdate.required)
    }

    /// A lock from the checking screen ends a failing check: the manifest is not read again for a vault that is not open.
    @Test func aLockEndsAFailingCheck() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = false
        #expect(await eventually { !m.releaseUpdate.checking })
        service.manifestOffline = true
        m.releaseUpdate.vaultOpened()
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.checkFailed)
        try await m.lock()
        #expect(!m.releaseUpdate.checking && !m.releaseUpdate.required)
        let fetches = service.manifestFetches
        try await Task.sleep(for: .seconds(3))
        #expect(service.manifestFetches == fetches, "no read after the lock (the first retry was due after 2 s)")
    }

    /// While the release is checked, the votes' work with the public site waits (the vault may be behind), though the
    /// opening's own reads run; it may run once the check ends.
    @Test func theVotesSiteWorkWaitsForTheCheck() async throws {
        defer { phone.close() }
        try await setUp()
        service.listsRelease4 = false
        #expect(await eventually { !m.releaseUpdate.checking })
        m.releaseUpdate.vaultOpened()
        #expect(m.votes.held() && !m.featuresGated())
        await m.releaseUpdate.refreshOffer()
        #expect(!m.votes.held())
    }
}
