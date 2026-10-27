import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

// Request bodies stay on one line each.
// swiftlint:disable line_length

/// The approvals, the feed and History end to end (VAULT-MESSAGING §10.4, §10.9, §10.12, §10.13; IOS-PLAN §8 I2.3's
/// acceptance: the approvals of ANDROID-PLAN §4, the export): this phone against ``FakeVaultService``, which answers as
/// vettid-vault's `features/feed`, `features/audit`, `features/grants`, `features/critical` and `features/connauth` do
/// and emulates the connection that asks. On the dev stack the connection is `vaultctl`'s peer.
@MainActor
@Suite(.serialized) struct VaultManagerActivityTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var feed: FeedManager { phone.manager.feed }
    var approvals: ApprovalsManager { phone.manager.approvals }

    /// Enrolled and open, connected with another member, the feed read; returns the connection id.
    func connected() async throws -> String {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        let r = try await m.connections.acceptInvite(try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo"))
        #expect(await eventually { m.connections.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        try await approvals.approveOutgoing(r.connectionID)
        #expect(await eventually { m.connections.connections.map(\.id) == [r.connectionID] })
        #expect(await eventually { feed.load == .loaded })
        return r.connectionID
    }

    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    /// The connection asks for items, to use a critical item, and to confirm it is the member; a share rule asks too.
    /// Each reaches Approvals and the feed; each decision answers the connection and marks the feed item read.
    @Test func theAsksOfAConnectionAreDecided() async throws {
        defer { phone.close() }
        let id = try await connected()
        let grant = try service.peerAsksForItems(id, [AskedItem(ref: "01JITEM000000000000000000A", label: "Passport"), AskedItem(kind: "category", ref: "insurance", label: "Insurance card", available: false)], reason: "Check-in")
        let use = try service.peerAsksCriticalUse(id, payload: Array("challenge".utf8))
        let auth = try service.peerAsksAuthentication(id)
        try service.shareRuleAsks("01JRULE000000000000000000A", id, items: ["01JITEM000000000000000000B"])
        #expect(await eventually { approvals.approvals.count == 4 && feed.badge.unread == 4 })
        #expect(Set(feed.items.compactMap { FeedKinds.target($0) == .approval(key: "grant:\(grant)") ? $0.ref : nil }) == [grant])

        // IOS-PLAN §4.4 (2): a code this app does not map names itself; the approval stays.
        service.refuseNext("grant.decide", code: "some_new_code")
        #expect(await kind { try await approvals.decideGrant(grant, approve: true) } == .vaultCode("some_new_code"))
        try await approvals.decideGrant(grant, approve: true)
        guard case .critical(let c)? = approvals.approvals.first(where: { $0.key == "critical:\(use)" }) else { throw CocoaError(.featureUnsupported) }
        #expect(c.payloadVerified)
        #expect(await kind { try await approvals.approveCriticalUse(use, password: "wrong") } == .badPassword)
        #expect(try await approvals.approveCriticalUse(use, password: password) == "ok")
        try await approvals.approveAuthentication(auth, password: password)
        try await approvals.decideShare("01JRULE000000000000000000A", include: ["01JITEM000000000000000000B"], decline: [])
        #expect(service.asksAnswered == ["data.decided:\(grant):approved:0", "critical-secret.result:\(use):ok", "connection.authenticate.response:\(auth):signed"])
        #expect(service.shareQuestion("01JRULE000000000000000000A") == nil)
        #expect(approvals.approvals.isEmpty)
        #expect(await eventually { feed.badge.unread == 0 }, "deciding an ask marks its feed item read")
        #expect(await eventually { feed.items.allSatisfy { service.feedStatus($0.itemID) == "read" } }, "in the vault too")
    }

    /// Another device's decision and status changes reach this phone; denials answer neutrally and are History entries.
    @Test func theOwnersOtherDevicesAndDenials() async throws {
        defer { phone.close() }
        let id = try await connected()
        let first = try service.peerAsksForItems(id, [AskedItem(ref: "01JITEM000000000000000000A", label: "Passport")])
        let second = try service.peerAsksForItems(id, [AskedItem(ref: "01JITEM000000000000000000A", label: "Passport")])
        #expect(await eventually { approvals.approvals.count == 2 })
        try service.otherDeviceDecidesGrant(first, approved: true)
        #expect(await eventually { approvals.approvals.map(\.key) == ["grant:\(second)"] })
        try await approvals.decideGrant(second, approve: false)
        #expect(service.asksAnswered == ["data.decided:\(second):denied"])
        let item = try #require(feed.items.first { $0.ref == first })
        try service.otherDeviceSetsFeedStatus(item.itemID, "archived")
        #expect(await eventually { feed.items.first { $0.itemID == item.itemID }?.status == "archived" })
        let page = try await m.history.auditPage(AuditRequest(filter: AuditFilter(category: .items)))
        #expect(page.entries.map(\.kind).prefix(1) == ["grant.denied"] && page.searchSent == false)
    }

    /// Locked, the feed and every approval are dropped from memory (nothing of them is written to the phone); the unlock
    /// reads the vault's lists again, and what only an event brought (a member authentication) does not come back. While
    /// a lock is pending nothing is taken in or sent.
    @Test func approvalsAndTheFeedFollowTheLock() async throws {
        defer { phone.close() }
        let id = try await connected()
        let auth = try service.peerAsksAuthentication(id)
        let grant = try service.peerAsksForItems(id, [AskedItem(ref: "01JITEM000000000000000000A", label: "Passport")])
        #expect(await eventually { approvals.approvals.count == 2 && feed.items.count == 2 })
        try await m.lock()
        #expect(feed.items.isEmpty && feed.badge == FeedBadge() && approvals.listed.isEmpty && approvals.approvals.isEmpty)
        for name in VaultFiles.retired {
            #expect(!FileManager.default.fileExists(atPath: phone.directory.appendingPathComponent(name).path))
        }
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { feed.items.count == 2 && approvals.approvals.map(\.key) == ["grant:\(grant)"] }, "read again at the opening")

        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        #expect(await kind { try await approvals.denyAuthentication(auth) } == .other, "nothing goes to a vault whose lock is pending")
        #expect(service.asksAnswered.isEmpty)
    }

    /// The opening and a passed owner check read the feed and the approvals' lists; in the background a read nobody
    /// asked for sends nothing and opens no session.
    @Test func quietReadsNeverOpenASessionInTheBackground() async throws {
        defer { phone.close() }
        _ = try await connected()
        let reads = { service.requestsSeen.filter { $0 == "feed.list" || $0 == "grant.list" }.count }
        #expect(await eventually { service.requestsSeen.contains("critical-secret-use.list") }, "the opening's reads, one after the other")
        let before = reads()
        #expect(try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil) == .passed)
        #expect(await eventually { reads() == before + 2 })
        await m.onBackground()
        #expect(m.session == nil)
        feed.catchUp()
        await #expect(throws: VaultFailure.self) { try await approvals.refreshApprovals(quietly: true, requests: false) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.session == nil && reads() == before + 2)
    }

    /// History with its search and the chain, and the export: the preview, a wrong PIN, then the file of the entries the
    /// member confirmed (IOS-PLAN §8 I2.3's acceptance, the bytes saved through Save to Files by the screens).
    @Test func historySearchAndExport() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.storeAuditEntries(120, connectionID: id)
        let all = try await m.history.auditPage(AuditRequest(limit: 100))
        #expect(all.entries.count == 100 && all.nextBeforeSeq != nil && AuditChain.consistent(all.entries))
        let found = try await m.history.auditPage(AuditRequest(filter: AuditFilter(query: "morgan")))
        #expect(found.searchSent && !found.entries.isEmpty && found.entries.allSatisfy { $0.entry.connectionID == id })

        let filter = AuditFilter(category: .security)
        let preview = try await m.historyExport.preview(filter)
        #expect(preview.count == 40 && service.exportsSeen.isEmpty)
        #expect(await kind { try await m.historyExport.export(filter, format: .csv, uptoSeq: preview.uptoSeq, pin: "999999") } == .badPin)
        let answer = try await m.historyExport.export(filter, format: .csv, uptoSeq: preview.uptoSeq, pin: pin)
        #expect(answer.entrySeq != nil && answer.answeredAt != nil && service.exportsSeen.last?.pin == pin)
        let rows = try await m.historyExport.entries(filter, answer: answer)
        #expect(rows.count == 40 && rows.allSatisfy { $0.kind == "credential.rotated" })
        let csv = HistoryCsv.bytes(rows.map { ExportRow(record: $0, label: $0.kind) })
        #expect((String(bytes: csv.dropFirst(3), encoding: .utf8) ?? "").components(separatedBy: "\r\n").count == 42)
        #expect(service.auditKinds.last == "audit.exported" && !rows.contains { $0.kind == "audit.exported" })
        #expect(service.lastAuditEntry?.ref == "format=csv;count=40;seqs=\(rows.last?.seq ?? 0)-\(rows.first?.seq ?? 0);filters=kinds")
        // The vault lists this app with an empty name: this phone, not a removed device.
        let devices = try #require(await m.history.devices())
        #expect(devices.device("dev-1") == .thisPhone && devices.device("dev-2") == .named("Work laptop") && devices.device("dev-9") == .removed)
    }

    /// The opening's reads one after the other: the connections, the requests, the approvals' lists and the feed before
    /// the conversations (one request per connection), so that asks are not kept waiting behind them.
    @Test func theOpeningReadsInOrder() async throws {
        defer { phone.close() }
        _ = try await connected()
        try await m.lock()
        let start = service.requestsSeen.count
        #expect(try await m.unlock(pin: pin) == .success)
        let order = ["connection.list", "connection.request.list", "grant.list", "critical-secret-use.list", "feed.list", "message.list"]
        #expect(await eventually { service.requestsSeen.dropFirst(start).contains("message.list") })
        let seen = Array(service.requestsSeen.dropFirst(start))
        let at = order.map { t in seen.firstIndex(of: t) ?? -1 }
        #expect(!at.contains(-1) && at == at.sorted(), "\(seen)")
    }

    /// Due or held by the owner check's state (§3.6.3, not only on `vault.held`): no feed content, approval or
    /// connection request (with its name and safety code) is kept; after the check they are read again.
    @Test func theFeedAndTheAsksAreDroppedWhileTheCheckIsDue() async throws {
        defer { phone.close() }
        let id = try await connected()
        let grant = try service.peerAsksForItems(id, [AskedItem(ref: "01JITEM000000000000000000A", label: "Passport")])
        let r = try await m.connections.acceptInvite(try service.peerInvite(first: "Sam", last: "Ray", name: "Sam"))
        #expect(await eventually { feed.items.count == 1 && m.connections.requests.first?.sas != nil })
        let sas = m.connections.requests.first?.sas
        #expect(await eventually { Set(approvals.approvals.map(\.key)) == ["grant:\(grant)", "outgoing:\(r.connectionID)"] })
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        #expect(feed.items.isEmpty && feed.badge == FeedBadge())
        #expect(approvals.approvals.isEmpty && m.connections.requests.isEmpty && m.connections.local.requestNames.isEmpty)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { feed.items.count == 1 }, "read again after the check")
        #expect(await eventually { Set(approvals.approvals.map(\.key)) == ["grant:\(grant)", "outgoing:\(r.connectionID)"] })
        #expect(m.connections.requests.map(\.sas) == [sas])
    }

    /// The vault's `share.decide`: items not waiting are ignored, and the answer names what was decided.
    @Test func aShareDecisionIgnoresItemsNotWaiting() async throws {
        defer { phone.close() }
        let id = try await connected()
        try service.shareRuleAsks("01JRULE000000000000000000A", id, items: ["01JITEM000000000000000000B", "01JITEM000000000000000000C"])
        #expect(await eventually { approvals.approvals.count == 1 })
        try await approvals.decideShare("01JRULE000000000000000000A", include: ["01JITEM000000000000000000B", "01JITEM000000000000000000Z"], decline: ["01JITEM000000000000000000C"])
        #expect(service.shareQuestion("01JRULE000000000000000000A") == nil)
        #expect(Array(service.auditKinds.suffix(2)) == ["share.included", "share.declined"])
    }
}

// swiftlint:enable line_length
