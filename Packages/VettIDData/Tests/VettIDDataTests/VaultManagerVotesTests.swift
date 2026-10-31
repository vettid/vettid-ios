import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The votes list end to end (VAULT-MESSAGING 0.81.3 §10.19.8, IOS-PLAN §4.16): this phone against ``FakeVaultService``,
/// which answers `vote.list` as vettid-vault's `features/vote` does (or `unsupported_type`, as a vault without votes).
@MainActor
@Suite(.serialized) struct VaultManagerVotesTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    static let pid = "01JBQZ0000000000000000000A"
    static let vote = #"{"proposal_id":"\#(pid)","connection_id":"conn-1","title":"Adopt the budget","state":"open","opens_at":"2026-11-01T09:00:00.000Z","closes_at":"2026-11-06T17:00:00.000Z","can_cast":true}"#

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func open() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
    }

    /// The opening reads the list; a vote event reads it again; a lock forgets it; the next opening reads it again.
    @Test func theOpeningReadsTheVotesAndALockForgetsThem() async throws {
        defer { phone.close() }
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.votes.count == 1 })
        #expect(m.votes.entry == VotesEntry(shown: true, badge: 1))
        service.setVotes([Self.vote, Self.vote.replacingOccurrences(of: "conn-1", with: "conn-2")])
        try service.voteEventArrives(connectionID: "conn-2", proposalID: Self.pid, event: "proposal", state: "open")
        #expect(await eventually { m.votes.votes.count == 2 })
        try await m.lock()
        #expect(m.votes.votes.isEmpty && m.votes.availability == .unknown && m.votes.entry == VotesEntry())
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { m.votes.votes.count == 2 })
    }

    /// A vault without votes: nothing is shown, and it is not asked again until the next opening.
    @Test func aVaultWithoutVotesShowsNothing() async throws {
        defer { phone.close() }
        try await open()
        #expect(await eventually { m.votes.availability == .unsupported })
        #expect(m.votes.entry == VotesEntry())
        let asked = service.voteRequests.count
        try service.voteEventArrives(connectionID: "conn-1", proposalID: Self.pid, event: "proposal", state: "open")
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.voteRequests.count == asked)
    }

    /// `vault.held` (§3.6.3): the votes are dropped with the rest of the vault's content and read again after another
    /// device's check.
    @Test func aHoldDropsTheVotesAndAnotherDevicesCheckReadsThemAgain() async throws {
        defer { phone.close() }
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.votes.count == 1 })
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.votes.votes.isEmpty)
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        #expect(await eventually { m.votes.votes.count == 1 })
    }
}

// swiftlint:enable line_length
