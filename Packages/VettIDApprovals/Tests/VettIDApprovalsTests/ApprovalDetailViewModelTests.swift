import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// One approval's decision (ANDROID-PLAN §4 Approvals; VAULT-MESSAGING §6.4, §10.4, §10.12, §10.13, §6.8): each kind
/// approved and denied on its own call, what approving needs, the password cleared after every decision, a request that
/// left the list meanwhile, the critical use's result, a backoff and a named limit. Mirrors vettid-android
/// `ApprovalsViewModelsTest`'s decision part.
@MainActor
@Suite struct ApprovalDetailViewModelTests {
    let connections = FakeConnections()
    let fake: FakeApprovals

    init() { fake = FakeApprovals(connections: connections) }

    func model(_ key: String, items: [AnswerItem] = []) async -> ApprovalDetailViewModel {
        let m = ApprovalDetailViewModel(key: key, approvals: fake, connections: connections, items: items)
        await m.settle()
        return m
    }

    /// Incoming requests go to the inviter's calls, outgoing ones to the accepter's; only a pending one with its code can be
    /// approved.
    @Test func connectionRequestsAreDecidedOnTheirSide() async {
        connections.requests = [Samples.incoming("p1"), Samples.outgoing("o1"), Samples.outgoing("o2", sas: nil)]
        let p = await model("connection:p1")
        #expect(p.state.canApprove() && p.state.needs == .nothing)
        p.approve()
        #expect(p.state.busy)
        await p.settle()
        #expect(connections.calls.last == "approveConnection" && p.state.done && !p.state.gone)
        let o = await model("outgoing:o1")
        o.deny()
        await o.settle()
        #expect(connections.calls.last == "declineOutgoing" && o.state.done)
        let waiting = await model("outgoing:o2")
        #expect(!waiting.state.canApprove())
        connections.requests = [Samples.incoming("p2", state: .approved)]
        let approved = await model("connection:p2")
        #expect(!approved.state.canApprove())
        approved.deny()
        await approved.settle()
        #expect(connections.calls.last == "declineConnection")
    }

    @Test func anOutgoingRequestIsApprovedAndAnIncomingOneBlockedOnceConfirmed() async {
        connections.requests = [Samples.incoming("p1"), Samples.outgoing("o1")]
        let o = await model("outgoing:o1")
        o.approve()
        await o.settle()
        #expect(connections.calls.last == "approveOutgoing")
        let p = await model("connection:p1")
        p.askBlock(true)
        #expect(p.state.confirmBlock)
        p.askBlock(false)
        #expect(!p.state.confirmBlock)
        p.askBlock(true)
        p.block()
        #expect(!p.state.confirmBlock)
        await p.settle()
        #expect(connections.calls.last == "blockConnectionRequest" && p.state.done)
    }

    /// A request the vault no longer has (decided on another device, or expired): "Already decided", not a failure screen.
    @Test func aRequestThatLeftMeanwhileIsGone() async {
        connections.goneOnNotFound = true
        connections.requests = [Samples.incoming("p1")]
        let m = await model("connection:p1")
        connections.fail["approveConnection"] = VaultFailure(.notFound)
        m.approve()
        await m.settle()
        #expect(m.state.gone && !m.state.done)
        // One that leaves while the screen is open, too; one never there is gone at once.
        fake.listed = [Samples.auth()]
        let a = await model("auth:a1")
        #expect(!a.state.gone)
        fake.listed = []
        #expect(a.state.gone && a.state.approval != nil)
        let none = await model("auth:none")
        #expect(none.state.approval == nil && !none.state.canApprove() && none.state.notHeld && !none.state.gone)
    }

    /// After a lock or a restart, an approval that arrived only as an event is not held (IOS-PLAN §6.9), and the vault
    /// never said it was decided or expired: its feed item opens "No longer on this phone", never "Already decided"
    /// (chosen; not in the spec). One that a read brings meanwhile is shown, and only one that then leaves is gone.
    @Test func anApprovalNotHeldIsNotSaidToBeDecided() async {
        let m = await model("auth:a1")
        #expect(m.state.notHeld && !m.state.gone && m.state.approval == nil && !m.state.canApprove())
        fake.listed = [Samples.auth()]
        await m.settle()
        #expect(!m.state.notHeld && !m.state.gone && m.state.approval?.key == "auth:a1")
        // The screen follows the list (``follow``) and keeps what it showed.
        try? await Task.sleep(for: .milliseconds(50))
        fake.listed = []
        for _ in 0..<200 where !m.state.gone { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.state.gone && !m.state.notHeld)
    }

    /// An ask decided on another device before the screen opened, while this phone held it, is "Already decided"; so is a
    /// request a vault list names, which is read again after a lock and so is never only dropped.
    @Test func anApprovalThatEndedThisSessionIsDecidedNotDropped() async {
        fake.listed = [Samples.auth()]
        fake.listed = []
        let m = await model("auth:a1")
        #expect(!m.state.notHeld && m.state.approval == nil && !m.state.canApprove())
        let grant = await model("grant:g9")
        #expect(!grant.state.notHeld && grant.state.approval == nil)
    }

    /// A hold or a lock that drops an open approval (IOS-PLAN §6.9) leaves it "No longer on this phone", never "Already
    /// decided": the vault did not say it was decided (chosen; not in the spec).
    @Test func anApprovalDroppedWhileOpenIsNotSaidToBeDecided() async {
        fake.listed = [Samples.auth()]
        let m = await model("auth:a1")
        #expect(!m.state.notHeld && !m.state.gone && m.state.approval?.key == "auth:a1")
        fake.forgetOpenVault()
        #expect(m.state.notHeld && !m.state.gone && m.state.approval == nil && !m.state.canApprove())
    }

    @Test func authenticationTakesThePasswordAndClearsIt() async {
        fake.listed = [Samples.auth()]
        connections.connections = [Samples.connection("c1")]
        let m = await model("auth:a1")
        #expect(m.state.needs == .password && !m.state.canApprove() && m.state.connectionName == "Sam Lee")
        m.setPassword("correct horse")
        #expect(m.state.canApprove())
        fake.fail["approveAuthentication"] = VaultFailure(.badPassword)
        m.approve()
        await m.settle()
        #expect(m.state.error == .badPassword && m.state.password.isEmpty && !m.state.busy && !m.state.done)
        m.setPassword("correct horse battery")
        #expect(m.state.error == nil)
        m.approve()
        await m.settle()
        #expect(fake.lastPassword == "correct horse battery" && m.state.done && m.state.password.isEmpty)
        fake.listed = [Samples.auth("a2")]
        let d = await model("auth:a2")
        d.deny()
        await d.settle()
        #expect(fake.calls.last == "denyAuthentication:a2" && d.state.done)
    }

    /// §10.4 (0.65.0): a sign-in's "Not me" and an approval's "Deny" are both `connection.authenticate.deny`; approving
    /// either still needs the credential password.
    @Test func aChallengeWithAPurposeIsDecidedAsBefore() async {
        fake.listed = [Samples.auth("s1", purpose: .signin), Samples.auth("p1", purpose: .approval)]
        let signin = await model("auth:s1")
        #expect(signin.state.needs == .password && !signin.state.canApprove())
        signin.deny()
        await signin.settle()
        #expect(fake.calls.last == "denyAuthentication:s1" && signin.state.done)
        let approval = await model("auth:p1")
        approval.setPassword("correct horse")
        approval.approve()
        await approval.settle()
        #expect(fake.calls.last == "approveAuthentication:p1" && approval.state.done)
    }

    /// §10.12: the named items that exist by default; a category entry once answered; uses and lifetime the member set.
    @Test func aGrantIsDecidedEntryByEntry() async {
        fake.listed = [Samples.grant()]
        let items = [AnswerItem(id: "x9", name: "Zeta card", category: "insurance"), AnswerItem(id: "x1", name: "Key", category: "x", critical: true)]
        let m = await model("grant:g1", items: items)
        #expect(m.state.grantIndexes == [0] && m.state.canApprove() && m.state.answerable.map(\.id) == ["x9"])
        m.toggleGrantEntry(0)
        #expect(m.state.grantIndexes.isEmpty && !m.state.canApprove())
        // The missing item cannot be granted even when ticked.
        m.toggleGrantEntry(1)
        #expect(m.state.grantIndexes.isEmpty)
        m.answerGrantEntry(2, itemID: "x9")
        m.toggleGrantEntry(0)
        #expect(m.state.grantIndexes == [0, 2])
        m.setGrantUses(10)
        m.setGrantExpiresIn(2_592_000)
        m.approve()
        await m.settle()
        #expect(fake.lastGrantDecision == GrantDecision(items: [0, 2], answers: [2: "x9"], uses: 10, expiresInSeconds: 2_592_000))
        #expect(m.state.done)
        fake.listed = [Samples.grant("g2")]
        let d = await model("grant:g2")
        d.deny()
        await d.settle()
        #expect(fake.calls.last == "denyGrant:g2")
    }

    @Test func aGrantWithNothingToGrantCannotBeApproved() async {
        fake.listed = [Samples.grant(entries: [Samples.entry("i1", available: false), Samples.entry("c", kind: "category", name: nil)])]
        let m = await model("grant:g1")
        #expect(!m.state.canApprove())
        m.approve()
        await m.settle()
        #expect(!fake.calls.contains { $0.hasPrefix("decideGrant") })
    }

    /// §10.13: only a payload that matches its hash, with the password, and outside a backoff; the result stays on screen.
    @Test func aCriticalUseNeedsAVerifiedPayloadAndThePassword() async {
        fake.listed = [Samples.critical()]
        let m = await model("critical:k1")
        #expect(!m.state.canApprove())
        m.setPassword("pw")
        #expect(m.state.canApprove())
        m.approve()
        await m.settle()
        #expect(m.state.criticalResult == "ok" && !m.state.done && !m.state.gone && m.state.password.isEmpty)
        m.finish()
        #expect(m.state.done)
    }

    @Test func aCriticalUseReportsTheConnectionsStatus() async {
        fake.listed = [Samples.critical()]
        fake.criticalStatus = "unsuitable"
        let m = await model("critical:k1")
        m.setPassword("pw")
        m.approve()
        await m.settle()
        #expect(m.state.criticalResult == "unsuitable")
        fake.listed = [Samples.critical("k2")]
        fake.criticalStatus = nil
        let n = await model("critical:k2")
        n.setPassword("pw")
        n.approve()
        await n.settle()
        #expect(n.state.criticalResult == "ok")
    }

    @Test func aCriticalUseFromTheListFetchesItsPayload() async {
        fake.listed = [Samples.critical(payload: "")]
        fake.criticalPayload = Samples.payload
        let m = await model("critical:k1")
        #expect(fake.calls.contains("loadCriticalUse:k1"))
        guard case .critical(let c)? = m.state.approval else { Issue.record("no use"); return }
        #expect(c.payloadVerified)
        fake.listed = [Samples.critical("k2", payload: "")]
        fake.fail["loadCriticalUse"] = VaultFailure(.network)
        let f = await model("critical:k2")
        #expect(f.state.error == .network)
    }

    @Test func aMismatchedPayloadOrAnUnsuitableFieldIsOnlyDenied() async {
        fake.listed = [Samples.critical(payload: "b3RoZXI="), Samples.critical("k2", kind: "number")]
        let mismatch = await model("critical:k1")
        mismatch.setPassword("pw")
        #expect(!mismatch.state.canApprove())
        let unsuitable = await model("critical:k2")
        unsuitable.setPassword("pw")
        #expect(!unsuitable.state.canApprove())
        unsuitable.deny()
        await unsuitable.settle()
        #expect(fake.calls.last == "denyCriticalUse:k2")
    }

    /// A password backoff (`retry_after`) holds the approve button until it ends; a named limit is kept for its text.
    @Test func aBackoffAndALimitAreKept() async {
        fake.listed = [Samples.critical()]
        let m = await model("critical:k1")
        m.setPassword("pw")
        fake.fail["approveCriticalUse"] = VaultFailure(.backoff, retryAfterSeconds: 30)
        m.approve()
        await m.settle()
        let until = try? #require(m.state.retryUntil)
        #expect(m.state.error == .backoff && until != nil)
        m.setPassword("pw")
        #expect(!m.state.canApprove(at: Date()) && m.state.canApprove(at: Date().addingTimeInterval(31)))
        fake.listed = [Samples.grant()]
        let g = await model("grant:g1")
        fake.fail["decideGrant"] = VaultFailure(.limit, limit: VaultLimit("grants_given", max: 3))
        g.approve()
        await g.settle()
        #expect(g.state.error == .limit && g.state.limit?.name == "grants_given" && g.state.retryUntil == nil)
    }

    /// §10.12: a tap decides only the share items the screen showed, not one a batch added just before it. Mirrors
    /// vettid-android `aShareDecisionDecidesOnlyTheItemsShown`.
    @Test func aShareDecisionDecidesOnlyTheItemsShown() async {
        fake.listed = [Samples.share()]
        let m = await model("share:r1")
        m.toggleShareItem("s2")
        // A batch lands before the tap: s3 is in the live question but was never on screen.
        guard case .share(var d) = Samples.share() else { return }
        d.items.append(ShareItem(itemID: "s3", name: "Vaccines", category: "medical", sensitivity: "data", askRuleID: nil, shared: false))
        fake.listed = [.share(d)]
        m.approve(shown: ["s1", "s2"])
        await m.settle()
        #expect(fake.lastShare?.include == ["s1"] && fake.lastShare?.decline == ["s2"])
        fake.listed = [.share(d)]
        let other = await model("share:r1")
        other.deny(shown: ["s1", "s2"])
        await other.settle()
        #expect(fake.lastShare?.include == [] && fake.lastShare?.decline == ["s1", "s2"])
    }

    /// §10.12: ticked items are shared, unticked ones declined; "Do not share" declines them all.
    @Test func aShareQuestionSharesTheTickedItems() async {
        fake.listed = [Samples.share()]
        let m = await model("share:r1")
        #expect(m.state.canApprove())
        m.toggleShareItem("s2")
        #expect(m.state.shareExcluded == ["s2"])
        m.approve()
        await m.settle()
        #expect(fake.lastShare?.include == ["s1"] && fake.lastShare?.decline == ["s2"])
        fake.listed = [Samples.share("r2")]
        let all = await model("share:r2")
        all.toggleShareItem("s1")
        all.toggleShareItem("s2")
        #expect(!all.state.canApprove())
        all.toggleShareItem("s1")
        #expect(all.state.shareExcluded == ["s2"])
        all.deny()
        await all.settle()
        #expect(fake.lastShare?.include == [] && fake.lastShare?.decline == ["s1", "s2"])
    }

    @Test func aDevicesRequestCanOnlyBeDeclined() async {
        fake.listed = [Samples.device()]
        let m = await model("device:approval.pending:d1")
        #expect(!m.state.canApprove())
        m.approve()
        await m.settle()
        #expect(fake.calls.isEmpty)
        m.deny()
        await m.settle()
        #expect(fake.calls == ["declineDeviceRequest:device:approval.pending:d1"] && m.state.done)
    }

    @Test func thePasswordGoesWithTheScreenAndIsNeverPrinted() async {
        fake.listed = [Samples.auth()]
        let m = await model("auth:a1")
        m.setPassword("hunter2-secret")
        for text in [String(describing: m.state), String(reflecting: m.state), "\(Mirror(reflecting: m.state).children.count)"] {
            #expect(!text.contains("hunter2") && !text.contains("Sign-in"))
        }
        m.forgetSecrets()
        #expect(m.state.password.isEmpty)
    }

    /// A second tap while a decision runs sends nothing more.
    @Test func oneDecisionAtATime() async {
        fake.listed = [Samples.share()]
        let m = await model("share:r1")
        m.approve()
        m.deny()
        await m.settle()
        #expect(fake.calls == ["decideShare:r1"])
    }

    /// A request past its `exp` is no longer approvable; member authentication respects the password backoff as a critical
    /// use does.
    @Test func anExpiredRequestOrABackoffRefusesTheApproval() async {
        let t = Date()
        guard case .authentication(var a) = Samples.auth() else { return }
        a.exp = t.addingTimeInterval(60)
        fake.listed = [.authentication(a)]
        let m = await model("auth:a1")
        m.setPassword("correct horse")
        #expect(m.state.canApprove(at: t) && !m.state.expired(at: t))
        #expect(m.state.expired(at: t.addingTimeInterval(60)) && !m.state.canApprove(at: t.addingTimeInterval(61)))
        var s = m.state
        s.retryUntil = t.addingTimeInterval(30)
        #expect(!s.canApprove(at: t.addingTimeInterval(10)) && s.canApprove(at: t.addingTimeInterval(31)))
        // A request without `exp` never expires here.
        fake.listed = [Samples.auth("a2")]
        let other = await model("auth:a2")
        #expect(!other.state.expired(at: .distantFuture))
    }

    /// The items a category entry can be answered with come from the Vault list: read quietly when it has not been read,
    /// followed as it changes, by name; a critical item is not offered.
    @Test func theAnswersFollowTheVaultList() async throws {
        let items = FakeItems()
        items.add(FakeItems.item("i9", "Travel insurance", category: "insurance"))
        items.add(FakeItems.item("i8", "Seed", sensitivity: .critical, category: "crypto_wallet"))
        let m = ApprovalDetailViewModel(key: "grant:g1", approvals: fake, connections: connections, vault: items)
        await m.settle()
        #expect(items.calls == ["refreshQuietly"])
        #expect(m.state.items.map(\.id) == ["i8", "i9"] && m.state.answerable.map(\.id) == ["i9"])
        items.add(FakeItems.item("i7", "Home insurance", category: "insurance"))
        #expect(m.state.answerable.map(\.id) == ["i7", "i9"])
    }
}

// swiftlint:enable line_length
