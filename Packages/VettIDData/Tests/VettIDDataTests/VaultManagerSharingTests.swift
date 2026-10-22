import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Share rules and grants end to end against ``FakeVaultService``, which answers as vettid-vault does (VAULT-MESSAGING
/// §10.12): a rule's dry run and its save (what it includes and what it asks about, `ask` winning over `auto`), the
/// questions among the approvals, a delete that revokes, a stale version; and a received grant listed, fetched with its
/// content sealed to the fetch's one-time key (§10.12 grant seal), counted, refused, revoked, and a category asked for.
@MainActor
@Suite(.serialized) struct VaultManagerSharingTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var sharing: SharingManager { phone.manager.sharing }
    var approvals: ApprovalsManager { phone.manager.approvals }

    /// Enrolled and open, connected with another member; returns the connection id.
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
        #expect(await eventually { m.items.load == .loaded })
        return r.connectionID
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    func shareDecisions() -> [ShareDecision] {
        approvals.approvals.compactMap { if case .share(let s) = $0 { s } else { nil } }
    }

    @Test func aRuleIsPreviewedSavedReplacedAndDeleted() async throws {
        defer { phone.close() }
        let id = try await connected()
        let allergies = service.addItem(name: "Allergies", tags: ["medical"])
        let key = service.addItem(name: "Signing key", sensitivity: "critical", category: "crypto_wallet", tags: ["medical"])
        _ = service.addItem(name: "Visa", tags: ["travel"])

        // The dry run changes nothing and says what saving does to each item; a critical item is never included.
        let draft = RuleDraft(connectionID: id, tags: ["medical"], mode: .auto, uses: 3, perHour: 5)
        let p = try await sharing.preview(draft)
        #expect(p.total == 2 && p.matches.map(\.itemID) == [allergies, key].sorted())
        #expect(p.matches.first { $0.itemID == allergies }?.outcome == "include" && p.matches.first { $0.itemID == key }?.outcome == nil)
        #expect(p.matches.first { $0.itemID == key }?.sensitivity == .critical)
        #expect(try await sharing.rules(connectionID: nil).isEmpty && service.sharingRequests.contains("share.rule.set:dry"))

        // Saved: the existing item is included at once, its grant carrying the rule's uses and limits.
        let rule = try await sharing.saveRule(draft)
        #expect(rule.connectionID == id && rule.tags == ["medical"] && rule.mode == .auto && rule.uses == 3 && rule.perHour == 5 && rule.version == 1)
        #expect(rule.included == [allergies] && rule.pending.isEmpty)
        #expect(service.ruleGrants(rule.ruleID).map(\.item) == [allergies])
        let given = try await sharing.grants().given
        #expect(given.map(\.itemRef) == [allergies] && given[0].ruleID == rule.ruleID && given[0].uses == 3 && given[0].perHour == 5 && given[0].name == "Allergies")
        #expect(sharing.tags?.tags.first { $0.tag == "medical" }?.rules == [rule.ruleID], "the registry was read again")

        // Replaced from a stale version: a conflict; from the current one: version 2, the item still included.
        var edit = RuleDraft.of(rule)
        edit.version = 7
        #expect(await failure { try await sharing.saveRule(edit) }?.kind == .conflict)
        edit.version = rule.version
        edit.uses = 5
        let replaced = try await sharing.saveRule(edit)
        #expect(replaced.version == 2 && replaced.uses == 5 && replaced.included == [allergies])

        // Deleted: its grants are revoked; deleting it again is not_found.
        try await sharing.deleteRule(rule.ruleID)
        let left = try await sharing.rules(connectionID: nil)
        #expect(service.ruleGrants(rule.ruleID).map(\.state) == ["revoked"] && left.isEmpty)
        #expect(await failure { try await sharing.deleteRule(rule.ruleID) }?.code == "not_found")
    }

    @Test func askWinsOverAutoAndTheQuestionsAreAnsweredOnce() async throws {
        defer { phone.close() }
        let id = try await connected()
        let allergies = service.addItem(name: "Allergies", tags: ["medical", "insurance"])
        // An `ask` rule asks about the item; an `auto` rule that covers it asks too, naming the `ask` rule.
        let ask = try await sharing.saveRule(RuleDraft(connectionID: id, tags: ["medical"], mode: .ask))
        #expect(ask.included.isEmpty && ask.pending == [allergies])
        let preview = try await sharing.preview(RuleDraft(connectionID: id, tags: ["insurance"], mode: .auto))
        #expect(preview.matches.map(\.outcome) == ["ask"] && preview.matches.map(\.askRuleID) == [ask.ruleID])
        let auto = try await sharing.saveRule(RuleDraft(connectionID: id, tags: ["insurance"], mode: .auto))
        #expect(auto.included.isEmpty && auto.pending == [allergies] && service.ruleGrants(auto.ruleID).isEmpty)

        // The approvals are built from `share.pending.list`: one question for the item, in the first rule (0.23.0).
        try await approvals.refreshApprovals()
        let questions = shareDecisions()
        #expect(questions.map(\.ruleID) == [ask.ruleID] && questions[0].items.map(\.itemID) == [allergies] && questions[0].items[0].alsoIn == [auto.ruleID])
        #expect(questions[0].tags == ["medical"] && questions[0].rules.map(\.ruleID) == [ask.ruleID, auto.ruleID])
        #expect(questions[0].subjectConnectionID == id)

        // One answer includes the item in both rules; each issues its grant.
        try await approvals.decideShare(ask.ruleID, include: [allergies], decline: [])
        let rules = try await sharing.rules(connectionID: id)
        #expect(rules.map(\.included) == [[allergies], [allergies]] && rules.allSatisfy { $0.pending.isEmpty })
        #expect(service.ruleGrants(ask.ruleID).map(\.state) == ["active"] && service.ruleGrants(auto.ruleID).map(\.state) == ["active"])
        try await approvals.refreshApprovals()
        #expect(shareDecisions().isEmpty)
    }

    @Test func aRuleTheVaultRefusesIsAFailure() async throws {
        defer { phone.close() }
        let id = try await connected()
        #expect(await failure { try await sharing.saveRule(RuleDraft(connectionID: "nobody", tags: ["a"])) }?.code == "not_found")
        // The member's checks come first: nothing is sent for a draft out of range.
        let before = service.sharingRequests.count
        #expect(await failure { try await sharing.saveRule(RuleDraft(connectionID: id, tags: ["a"], uses: 0)) }?.code == "bad_request")
        #expect(service.sharingRequests.count == before)
        // A tag the registry would not take is the vault's bad_request.
        #expect(await failure { try await sharing.saveRule(RuleDraft(connectionID: id, tags: ["not a tag!"])) }?.code == "bad_request")
    }

    @Test func aReceivedGrantIsFetchedCountedAndRefused() async throws {
        defer { phone.close() }
        let id = try await connected()
        let grantID = try service.peerSharesItem(
            id, ref: "x9", name: "Insurance card", category: "insurance",
            fields: [.init("Policy", "P-42"), .init("Address", kind: "address", #"{"city":"Paris"}"#)], notes: "Call first", uses: 2, perHour: 5
        )
        let received = try await sharing.grants().received
        let g = try #require(received.first)
        #expect(received.count == 1 && g.grantID == grantID && g.direction == .received && g.connectionID == id && g.name == "Insurance card" && g.category == "insurance")
        #expect(g.labels == [GrantFieldLabel(fieldID: "f1", label: "Policy", kind: "text"), GrantFieldLabel(fieldID: "f2", label: "Address", kind: "address")])
        #expect(g.uses == 2 && g.perHour == 5 && g.perDay == nil && g.active)

        // The content comes back sealed to the fetch's one-time key, with the uses left.
        guard case .shared(let first) = try await sharing.fetchShared(grantID) else { Issue.record("shared"); return }
        #expect(first.itemID == "x9" && first.name == "Insurance card" && first.notes == "Call first" && first.usesLeft == 1)
        #expect(first.fields.map(\.label) == ["Policy", "Address"] && first.fields[0].value == .text("P-42") && first.fields[1].value == .address(AddressValue(city: "Paris")))
        guard case .shared(let second) = try await sharing.fetchShared(grantID) else { Issue.record("shared"); return }
        #expect(second.usesLeft == 0 && service.grantState(grantID) == "used")
        #expect(try await sharing.fetchShared(grantID) == .refused("exhausted"))
        #expect(try await sharing.grants().received.first?.usesLeft == 0)

        // A rate limit says when to come back; a revoked grant is refused; an unknown one is not_found.
        let limited = try service.peerSharesItem(id, ref: "x10", name: "Card")
        service.peerRefusesFetches(of: limited, with: "rate_limited", retryAfter: 720)
        #expect(try await sharing.fetchShared(limited) == .refused("rate_limited", retryAfter: 720))
        service.peerRefusesFetches(of: limited, with: nil)
        try await sharing.revokeGrant(limited)
        let afterRevoke = try await sharing.grants().received
        #expect(service.grantState(limited) == "revoked" && afterRevoke.first { $0.grantID == limited }?.active == false)
        #expect(try await sharing.fetchShared(limited) == .refused("revoked"))
        #expect(await failure { try await sharing.fetchShared("01NOSUCHGRANT") }?.code == "not_found")
        #expect(await failure { try await sharing.revokeGrant("01NOSUCHGRANT") }?.code == "not_found")
    }

    @Test func aCategoryIsAskedForAndAnswered() async throws {
        defer { phone.close() }
        let id = try await connected()
        let request = try await sharing.requestGrant(connectionID: id, category: "insurance", label: "Your insurance card", reason: "For the claim")
        var lists = try await sharing.grants()
        #expect(lists.requested.map(\.requestID) == [request] && lists.requested[0].connectionID == id && lists.requested[0].state == "pending")
        #expect(lists.requested[0].entries == [GrantAskEntry(kind: "category", ref: "insurance", label: "Your insurance card")])
        try service.peerAnswersRequest(request, granted: true)
        lists = try await sharing.grants()
        #expect(lists.requested[0].state == "granted")
        #expect(await failure { try await sharing.requestGrant(connectionID: "nobody", category: "insurance", label: nil, reason: nil) }?.code == "not_found")
    }
}

// swiftlint:enable line_length
