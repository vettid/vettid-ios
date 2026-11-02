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
    /// The public votes site this phone reads.
    let site = FakeVoteSite()
    let pin = "402817"
    let password = "correct horse battery"
    static let pid = "01JBQZ0000000000000000000A"
    static let vote = #"{"proposal_id":"\#(pid)","connection_id":"conn-1","title":"Adopt the budget","state":"open","opens_at":"2026-11-01T09:00:00.000Z","closes_at":"2026-11-06T17:00:00.000Z","can_cast":true}"#

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service, votesSite: site)
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

    /// The requests as they go over the wire (VAULT-MESSAGING 0.81.3 §10.19.8): every request about a vote names
    /// `connection_id` with `proposal_id`; `vote.list` asks for every state, clamps `limit` and sends `ack_dropped` only
    /// when there is one; `vote.release` carries the PIN only sealed to a UTK.
    @Test func theRequestsCarryThePairAndTheReleaseSealsThePin() async throws {
        defer { phone.close() }
        service.setVotes([])
        try await open()
        #expect(await eventually { m.votes.availability == .available })
        let api = try m.openApi(try await m.openSession())
        let key = VoteKey(connectionID: "conn-7", proposalID: Self.pid)
        let start = service.voteBodies.count
        _ = try? await api.voteGet(key)
        _ = try? await api.voteCast(key, choiceID: "yes")
        try? await api.voteCheck(key)
        _ = try? await api.voteConfirm(key, mine: true)
        _ = try? await api.voteEvidence(key)
        try await api.voteRelease(key, pin: pin)
        let sent = Array(service.voteBodies.dropFirst(start))
        #expect(sent.map(\.type) == ["vote.get", "vote.cast", "vote.check", "vote.confirm", "vote.evidence", "vote.release"])
        for (type, body) in sent {
            #expect(try body.string("connection_id") == "conn-7", "\(type)")
            #expect(try body.string("proposal_id") == Self.pid, "\(type)")
        }
        #expect(try sent[1].body.string("choice_id") == "yes")
        #expect(try sent[3].body.bool("mine") == true)
        let release = sent[5].body
        #expect(release.has("utk_id") && release.has("sealed") && !release.has("pin"))
        #expect(!release.raw.contains(pin))
        #expect(service.votePins == [pin])

        let before = service.voteBodies.count
        _ = try await api.voteList(after: nil, ack: [])
        _ = try await api.voteList(after: "cursor", ack: ["c1", "c2"])
        _ = try await api.voteList(state: "open", limit: 1_000)
        _ = try await api.voteList(limit: 0)
        let lists = service.voteBodies.dropFirst(before).map(\.body)
        #expect(try lists[0].string("state") == "all")
        #expect(try lists[0].uint("limit", min: 0, max: 1_000) == UInt64(VotesManager.page))
        #expect(!lists[0].has("ack_dropped") && !lists[0].has("after"))
        #expect(try lists[1].string("after") == "cursor")
        #expect(try lists[1].array("ack_dropped").map { try $0.asString() } == ["c1", "c2"])
        #expect(try lists[2].string("state") == "open" && lists[2].uint("limit", min: 0, max: 1_000) == 100)
        #expect(try lists[3].uint("limit", min: 0, max: 1_000) == 1)
    }

    /// Leaving the foreground while the lock of a vote's unlock window is on its way (IOS-PLAN §6.6): the collection runs
    /// on, within the background time, so that the lock's answer can arrive; then it stops.
    @Test func theBackgroundWaitsForAVoteWindowsLock() async throws {
        defer { phone.close() }
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.availability == .available })
        service.loseAnswers(["credential.lock"])
        // The cast opens the window with the password; whatever its answer, the window it opened is locked again.
        _ = try? await m.votes.cast(VoteKey(connectionID: "conn-1", proposalID: Self.pid), choiceID: "yes", password: password)
        #expect(m.votes.windowLock != nil)
        let background = Task { @MainActor in await m.onBackground(budget: .seconds(3)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.session?.device.collecting == true, "the collection waits for the window's lock")
        await background.value
        #expect(m.session == nil, "the collection stopped once the background time was up")
    }

    /// The window's lock answered within the background time: the wait ends with it, no notice, then the collection stops.
    @Test func aVoteWindowsLockAnsweredInTheBackgroundEndsTheWaitEarly() async throws {
        defer { phone.close() }
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.availability == .available })
        _ = try? await m.votes.cast(VoteKey(connectionID: "conn-1", proposalID: Self.pid), choiceID: "yes", password: password)
        let start = ContinuousClock.now
        await m.onBackground(budget: .seconds(25))
        #expect(ContinuousClock.now - start < .seconds(10), "the wait ended with the lock, not with the budget")
        #expect(m.session == nil)
        #expect(m.votes.windowNotClosed == nil && m.unlockWindow == nil)
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

    /// A hold that begins during the reads of the lists leaves the work with the site not started.
    @Test func aHoldDuringTheReadsLeavesTheSiteWorkNotStarted() async throws {
        defer { phone.close() }
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { m.votes.siteRunner?.wanted == true })
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.votes.siteRunner?.wanted == false)
        m.refreshListsQuietly()
        await m.listsRead?.value
        #expect(m.votes.siteRunner?.wanted == false)
    }

    /// The public votes site (IOS-PLAN §4.16 "The site"): read after the opening's list, its documents handed to the
    /// vault in `vote.site.sync`, then every hour while the vault is open; nothing after a lock.
    @Test func theOpeningHandsTheSiteToTheVaultAndALockStopsTheWork() async throws {
        defer { phone.close() }
        site.put("index.json", "[]")
        service.setVotes([Self.vote])
        try await open()
        #expect(await eventually { service.voteRequests.contains("vote.site.sync") })
        #expect(site.reads.contains("index.json") && site.reads.contains("p/\(Self.pid)/proposal.json"))
        let entry = try #require(service.voteBodies.last { $0.type == "vote.site.sync" }?.body)
        #expect(try entry.array("entries").count == 1)
        #expect(await eventually { phone.votesPauses.lengths == [3600] })
        try await m.lock()
        site.clearReads()
        phone.votesPauses.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(site.reads.isEmpty)
    }
}

// swiftlint:enable line_length
