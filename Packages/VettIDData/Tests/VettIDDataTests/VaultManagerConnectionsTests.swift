import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Connecting end to end (VAULT-MESSAGING §6.4, §10.4, §10.4.1; IOS-PLAN §8 I2.1's acceptance: an invitation, the same
/// safety code on both screens, both members approve): this phone against ``FakeVaultService``, which answers the
/// connection types as vettid-vault's handlers do and emulates the other member's vault (its accept, its approval, its
/// decline). On the dev stack the other member is `vaultctl`'s peer.
@MainActor
@Suite(.serialized) struct VaultManagerConnectionsTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var c: ConnectionsManager { phone.manager.connections }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// The failure kind [op] throws.
    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    /// This member accepts another member's invitation (sent as the URL on that member's relay), and both approve: the
    /// peer first, then this member. Returns the connection id.
    @discardableResult
    func connectByAccepting(name: String? = "Mo") async throws -> String {
        let link = try service.peerInvite(first: "Morgan", last: "Lee", name: name, remote: true, ttl: 3_600)
        let r = try await c.acceptInvite("https://relay.peer.example/connect#\(link)")
        #expect(!r.exists && r.name == name)
        #expect(await eventually { c.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        #expect(await eventually { c.requests.first?.peerApproved == true })
        try await c.approveOutgoing(r.connectionID)
        #expect(await eventually { c.connections.contains { $0.id == r.connectionID } && c.requests.isEmpty })
        return r.connectionID
    }

    /// The inviter's side: an invitation, the other member's accept, the same code on both screens, both approvals.
    @Test func theInviterInvitesComparesTheCodeAndBothApprove() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(try await c.inviteTtls() == [.tenMinutes, .oneHour, .oneDay], "never above the relay's limits (24 h here)")
        let invite = try await c.createInvite(.tenMinutes)
        #expect(!invite.remote && invite.exp > Date() && invite.exp <= Date().addingTimeInterval(601))
        #expect(invite.url == "\(service.vaultRelay.baseURL)/connect#\(invite.link)")
        #expect(InviteLinks.parse(invite.qr) == .ok(link: invite.link, exp: invite.exp))
        #expect(try await c.outstandingInvites().map(\.inviteID) == [invite.inviteID])

        let pendingID = try service.peerAccepts(invite.inviteID, first: "Alex", last: "Kim", name: "Al")
        #expect(await eventually { !c.requests.isEmpty })
        guard case .incoming(let r) = try #require(c.requests.first) else { throw VaultFailure(.other) }
        #expect(r.pendingID == pendingID && r.sas == service.sas(of: pendingID), "the code the other member's screen shows")
        #expect(r.name == "Alex Kim" && r.displayName == "Al" && r.state == .pending && !r.remote)
        #expect(try await c.outstandingInvites().isEmpty, "single use")

        try await c.approveConnection(pendingID)
        #expect(c.requests.first?.state == .approved && service.approvedSent == [pendingID])
        try service.peerApproves(pendingID)
        #expect(await eventually { c.requests.isEmpty && c.connections.count == 1 })
        let conn = try #require(c.connections.first)
        #expect(service.connectionIDs == [conn.id] && conn.state == .active)
        #expect(conn.displayName == "Alex Kim" && conn.secondaryName == "Al" && conn.keyFingerprint?.count == 39)
    }

    /// The accepter's side: the outgoing request waits for its handshake, then shows the inviter's code.
    @Test func theAccepterWaitsForTheCodeThenBothApprove() async throws {
        defer { phone.close() }
        try await setUp()
        service.holdsHandshakes = true
        let link = try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo")
        let r = try await c.acceptInvite("vettid://connect#\(link)")
        #expect(c.requests.first?.state == .waiting && c.requests.first?.name == "Mo")
        // No code yet: an approval is refused (0.10.3), and the request stays.
        #expect(await kind { try await c.approveOutgoing(r.connectionID) } == .other)
        #expect(c.requests.count == 1)
        try service.runHandshake(r.connectionID)
        #expect(await eventually { c.requests.first?.state == .pending })
        #expect(c.requests.first?.sas == service.sas(of: r.connectionID))
        try await c.approveOutgoing(r.connectionID)
        #expect(c.requests.first?.state == .approved)
        try service.peerApproves(r.connectionID)
        #expect(await eventually { c.requests.isEmpty && c.connections.map(\.id) == [r.connectionID] })
        #expect(c.connections.first?.displayName == "Morgan Lee" && c.connections.first?.secondaryName == "Mo")
        let got = try await c.connection(r.connectionID)
        #expect(got.displayName == "Morgan Lee" && got.state == .active)
    }

    /// §6.4 "Already connected", a spent link, and a blocked inviter.
    @Test func anInviterAlreadyConnectedSpentLinksAndBlocks() async throws {
        defer { phone.close() }
        try await setUp()
        let id = try await connectByAccepting()
        let again = try service.peerInvite(sameAs: id)
        #expect(try await c.acceptInvite(again) == AcceptedConnection(connectionID: id, exists: true))
        #expect(c.requests.isEmpty)
        #expect(await kind { try await c.acceptInvite(again) } == .inviteUnavailable, "the claim was fetched once")
        let later = try service.peerInvite(sameAs: id)
        try await c.block(id)
        #expect(c.connections.isEmpty && service.connectionIDs.isEmpty && service.blockedKeys.count == 1)
        #expect(await kind { try await c.acceptInvite(later) } == .blocked)
    }

    /// Either member's decline (0.10.5): the vault sends `connection.declined` once it can; the member whose request
    /// was declined is told once, with the name the request showed.
    @Test func declines() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await c.createInvite(.oneHour)
        let pendingID = try service.peerAccepts(first: "Alex", last: "Kim")
        #expect(await eventually { c.requests.count == 1 })
        try await c.declineConnection(pendingID)
        #expect(c.requests.isEmpty && c.requestEnds[pendingID] == .declined && service.declinedSent == [pendingID])

        let link = try service.peerInvite(name: "Mo")
        let r = try await c.acceptInvite(link)
        #expect(await eventually { c.requests.first?.state == .pending })
        try service.peerDeclines(r.connectionID)
        #expect(await eventually { c.peerDeclines.count == 1 })
        #expect(c.peerDeclines.first?.name == "Mo" && c.peerDeclines.first?.outgoing == true)
        #expect(c.requests.isEmpty && c.requestEnds[r.connectionID] == .peerDeclined)
        c.dismissPeerDecline(r.connectionID)
        #expect(c.peerDeclines.isEmpty)

        // Declined while waiting: nothing can be sent yet (no token to the inviter, no epoch).
        service.holdsHandshakes = true
        let waiting = try await c.acceptInvite(try service.peerInvite())
        try await c.declineOutgoing(waiting.connectionID)
        #expect(c.requests.isEmpty && !service.declinedSent.contains(waiting.connectionID))
        #expect(await kind { try await c.declineOutgoing(waiting.connectionID) } == .notFound)
    }

    /// The owner's own metadata, the asks (§10.4.1), the peer's profile changing, and a removal.
    @Test func favouritesAsksProfileAndRemoval() async throws {
        defer { phone.close() }
        try await setUp()
        let id = try await connectByAccepting()
        try await c.setFavorite(id, favorite: true)
        #expect(c.connections.first?.favorite == true && c.connections.first?.version == 1)
        try await c.setAsksMuted(id, muted: true)
        #expect(c.connections.first?.asks?.muted == true)
        try await c.resumeAsks(id)
        #expect(c.connections.first?.asks == AskState(muted: true))
        try service.peerProfileChanged(id, name: "Morgan L.")
        #expect(await eventually { c.connections.first?.secondaryName == "Morgan L." })
        try await c.remove(id)
        #expect(c.connections.isEmpty && service.connectionIDs.isEmpty)
        #expect(await kind { try await c.setFavorite(id, favorite: false) } == .notFound)
    }

    /// Invitations: one above the relay's limits is refused; one is cancelled.
    @Test func invitationsAreListedAndCancelled() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await kind { try await c.createInvite(.sevenDays) } == .notSupported)
        let i = try await c.createInvite(.oneDay)
        #expect(i.remote)
        try await c.cancelInvite(i.inviteID)
        #expect(try await c.outstandingInvites().isEmpty && service.inviteIDs.isEmpty)
        #expect(await kind { try await c.cancelInvite(i.inviteID) } == .notFound)
    }

    /// Locked, the lists read from the vault are not kept in memory; the unlock reads them again. The other member's
    /// decline not yet seen is kept on the phone across a restart.
    @Test func theListsFollowTheLockAndDeclinesTheRestart() async throws {
        defer { phone.close() }
        try await setUp()
        let id = try await connectByAccepting()
        let r = try await c.acceptInvite(try service.peerInvite(first: "Sam", last: "Ray", name: "Sam"))
        #expect(await eventually { c.requests.count == 1 })
        try service.peerDeclines(r.connectionID)
        #expect(await eventually { c.peerDeclines.count == 1 })
        try await m.lock()
        #expect(c.connections.isEmpty && c.requests.isEmpty)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { c.connections.map(\.id) == [id] })
        try phone.restart()
        try await m.refresh()
        #expect(c.peerDeclines.map(\.name) == ["Sam"])
    }

    /// Nothing the vault sends is taken into the lists while a lock is pending (as vettid-android): a request that
    /// arrives between the lock and its confirmation is neither shown nor kept.
    @Test func eventsWhileALockIsPendingAreNotTaken() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        let event = #"{"pending_id":"p1","sas":"042817","state":"pending","profile":{"first_name":"Alex","last_name":"Kim"}}"#
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "connection.request.pending", ts: Date(), body: Array(event.utf8))))
        #expect(c.requests.isEmpty && c.connections.isEmpty && c.local.requestNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: phone.directory.appendingPathComponent(VaultFiles.connections).path))
    }

    /// The fake refuses what vettid-vault's `connection.update` refuses: members of the wrong type and the limits.
    @Test func theFakeRefusesBadUpdatesAsTheVaultDoes() async throws {
        defer { phone.close() }
        try await setUp()
        let id = try await connectByAccepting()
        let api = try m.openApi(try await m.openSession())
        for bad in [#""favorite":"yes""#, #""archived":1"#, #""tags":"family""#, #""tags":["Family"]"#, #""tags":["a","a"]"#,
                    #""alias":"\#(String(repeating: "a", count: 129))""#, #""note":7"#, #""other":true"#] {
            let body = Array(#"{"connection_id":"\#(id)","version":0,\#(bad)}"#.utf8)
            await #expect(throws: VaultOpError.self, "\(bad)") { _ = try await api.device.op("connection.update", body: body) }
        }
        #expect(try await api.connectionUpdate(id, version: 0, change: ConnectionMetaChange(alias: "Mo", tags: ["family"])) == 1)
        let got = try await api.connectionGet(id)
        #expect(got.alias == "Mo" && got.tags == ["family"])
    }

    /// A passed owner check reads the lists again (§3.6.3: nothing held back is replayed as events; as vettid-android's
    /// `onPassed`); a failed one does not.
    @Test func aPassedOwnerCheckReadsTheListsAgain() async throws {
        defer { phone.close() }
        try await setUp()
        func reads() -> Int { service.requestsSeen.filter { $0 == "connection.list" || $0 == "connection.request.list" }.count }
        #expect(await eventually { reads() == 2 }, "the reads at the opening")
        _ = try? await m.ownerChecks.check(pin: "111111", password: "correct horse battery", holdOff: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reads() == 2, "a failed check reads nothing")
        #expect(try await m.ownerChecks.check(pin: pin, password: "correct horse battery", holdOff: nil) == .passed)
        #expect(await eventually { reads() == 4 })
    }

    /// In the background (the session dropped) a read nobody asked for sends nothing and opens no session.
    @Test func aBackgroundReadOpensNoSession() async throws {
        defer { phone.close() }
        try await setUp()
        func reads() -> Int { service.requestsSeen.filter { $0 == "connection.list" || $0 == "connection.request.list" }.count }
        #expect(await eventually { reads() == 2 })
        await m.onBackground()
        #expect(m.session == nil)
        c.refreshAllQuietly()
        c.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: Date(), body: Array(#"{"kind":"block.added"}"#.utf8))))
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.session == nil && reads() == 2)
    }
}
