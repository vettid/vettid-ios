import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The work with the public votes site and the release check after an opening, end to end over ``FakeVaultService``
/// (owner decisions 2026-11-17): nothing is read from the site while the release is being checked, and the work starts
/// once the check ends.
@MainActor
@Suite(.serialized) struct VaultManagerReleaseVotesTests {
    /// The site's reads, and those made while the release was being checked.
    final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var during = 0
        var duringCheck: Int { lock.withLock { during } }
        func note() { lock.withLock { during += 1 } }
    }

    let service: FakeVaultService
    let phone: TestVaultPhone
    let site = FakeVoteSite()
    let watch = Watch()
    let pin = "402817"
    // swiftlint:disable:next line_length
    static let vote = #"{"proposal_id":"01JBQZ0000000000000000000A","connection_id":"conn-1","title":"Adopt the budget","state":"open","opens_at":"2026-11-01T09:00:00.000Z","closes_at":"2026-11-06T17:00:00.000Z","can_cast":true}"#

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service, votesSite: site)
        let phone = phone
        let watch = watch
        site.hold = { _ in
            if await MainActor.run(body: { phone.manager.releaseUpdate.checking }) { watch.note() }
        }
    }

    var m: VaultManager { phone.manager }

    func open() async throws {
        service.setVotes([Self.vote])
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// A check that passes at once: the site is read after it, never during it.
    @Test func theSiteIsReadOnceTheOpeningsCheckEnds() async throws {
        defer { phone.close() }
        service.listsRelease4 = false
        try await open()
        #expect(await eventually { site.reads.contains("services.json") })
        #expect(!m.releaseUpdate.checking && watch.duringCheck == 0)
    }

    /// A check that cannot verify the release holds the features and is read again: no site read meanwhile, and the work
    /// starts once a read verifies it.
    @Test func theSiteIsNotReadWhileAFailingCheckHolds() async throws {
        defer { phone.close() }
        service.listsRelease4 = false
        service.release3ListedAs = 2
        try await open()
        #expect(await eventually { m.releaseUpdate.checkFailed && m.featuresGated() })
        try await Task.sleep(for: .milliseconds(300))
        #expect(site.reads.isEmpty)
        service.release3ListedAs = 3
        // The read that verifies it (Try again, or the retry's own).
        await m.releaseUpdate.refreshOffer()
        #expect(await eventually { site.reads.contains("services.json") })
        #expect(watch.duringCheck == 0 && !m.featuresGated())
    }
}
