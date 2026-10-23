import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// A connection's detail (ANDROID-PLAN §4; VAULT-MESSAGING §10.4, §10.4.1): loading, an unknown connection, the
/// favourite, removing once confirmed, muting and resuming the asks, sharing both ways (VAULT-MESSAGING §10.12) and the
/// failures. Mirrors vettid-android `ConnectionsViewModelsTest`'s detail part and `ConnectionSharingCardsTest`'s view-model
/// cases.
@MainActor
@Suite struct ConnectionDetailViewModelTests {
    let fake = FakeConnections()
    let sharing = FakeSharing()

    func model(_ id: String = "c1") async -> ConnectionDetailViewModel {
        let m = ConnectionDetailViewModel(connectionID: id, connections: fake, sharing: sharing)
        await m.settle()
        return m
    }

    private let rule1 = ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"], mode: .auto, uses: 5, included: ["i1"])
    private let rule2 = ShareRule(ruleID: "r2", connectionID: "c1", tags: ["drivers-license"], uses: 5, included: ["i2"], pending: ["i3"])
    private let outGrant = GrantView(
        grantID: "g1", connectionID: "c1", direction: .given, itemRef: "i1", name: "Allergies", category: "medical", ruleID: "r1"
    )
    private let inGrant = GrantView(
        grantID: "g3", connectionID: "c1", direction: .received, itemRef: "x1", name: "Home address", category: "contact"
    )

    @Test func itLoadsTheConnection() async {
        fake.connections = [Samples.active("c1")]
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.connection?.displayName == "Ada Lovelace" && !m.state.gone)
        #expect(fake.calls == ["connection"])
    }

    /// The vault does not know it (removed on another device): the screen closes.
    @Test func anUnknownConnectionCloses() async {
        let m = await model("nope")
        #expect(m.state.gone && m.state.error == .notFound && m.state.connection == nil)
    }

    /// A failed read keeps the screen, saying why.
    @Test func aFailedReadSaysWhyAndTriesAgain() async {
        fake.connections = [Samples.active("c1")]
        fake.fail["connection"] = VaultFailure(.network)
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        await m.settle()
        #expect(!m.state.gone && m.state.error == .network && !m.state.loading)
        m.load()
        #expect(m.state.loading && m.state.error == nil)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && m.state.connection?.id == "c1")
    }

    /// The list's copy wins: a change made elsewhere shows at once.
    @Test func theFavouriteToggles() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        m.toggleFavorite()
        #expect(m.state.busy)
        await m.settle()
        #expect(m.state.connection?.favorite == true && !m.state.busy && fake.calls.last == "setFavorite")
        m.toggleFavorite()
        await m.settle()
        #expect(m.state.connection?.favorite == false)
        // Another device changed it first and the retry failed too (`conflict`, §10.4): said, nothing changed.
        fake.fail["setFavorite"] = VaultFailure(.conflict)
        m.toggleFavorite()
        await m.settle()
        #expect(m.state.error == .conflict && m.state.connection?.favorite == false && !m.state.busy)
        m.dismissNotice()
        #expect(m.state.error == nil)
    }

    @Test func removingIsConfirmedFirst() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        m.confirm()
        await m.settle()
        #expect(!fake.calls.contains("remove"))
        m.ask(.remove)
        #expect(m.state.confirm == .remove)
        m.ask(nil)
        #expect(m.state.confirm == nil)
        m.ask(.remove)
        fake.fail["remove"] = VaultFailure(.network)
        m.confirm()
        await m.settle()
        #expect(m.state.error == .network && !m.state.gone && m.state.confirm == nil)
        m.ask(.remove)
        m.confirm()
        await m.settle()
        // Closed, and nothing of it stays on screen.
        #expect(m.state.gone && fake.connections.isEmpty && m.state.connection == nil)
    }

    /// Removed on another device, or the vault locked and the lists were emptied: the screen closes and drops the names
    /// and the profile it showed.
    @Test func aConnectionThatLeavesTheListCloses() async {
        fake.connections = [Samples.active("c1"), Samples.active("c2")]
        let m = await model()
        fake.connections.removeAll { $0.id == "c2" }
        #expect(await until { !m.state.gone && m.state.connection != nil })
        fake.connections = []
        await m.settle()
        #expect(m.state.gone && m.state.connection == nil)
        // It does not come back with the list.
        fake.connections = [Samples.active("c1")]
        #expect(await until { m.state.connection == nil })
    }

    /// Mute and unmute; resume a pause or the cooldowns (0.23.0 §10.4.1). Unmuting does not resume, resuming does not
    /// unmute.
    @Test func theAsksAreMutedAndResumed() async {
        var c = Samples.active("c1")
        c.asks = AskState(muted: false, paused: true, pausedAt: Date(), cooldowns: 2)
        fake.connections = [c]
        let m = await model()
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.resume, .mute])
        m.muteAsks(true)
        await m.settle()
        #expect(fake.calls.last == "asksMute:c1:true")
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.resume, .unmute])
        m.resumeAsks()
        await m.settle()
        #expect(fake.calls.last == "asksResume:c1" && m.state.connection?.asks == AskState(muted: true))
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.unmute])
        fake.fail["asksMute:c1:false"] = VaultFailure(.network)
        m.muteAsks(false)
        await m.settle()
        #expect(m.state.error == .network && m.state.connection?.asks?.muted == true)
    }

    /// vettid-android `AsksView`: nothing from an older vault; allow-again for cooldowns without a pause; prominent when
    /// muted or paused.
    @Test func theAsksView() {
        #expect(AsksView.of(nil) == nil)
        let normal = AsksView.of(AskState())
        #expect(normal?.actions == [.mute] && normal?.prominent == false)
        let cooled = AsksView.of(AskState(cooldowns: 1))
        #expect(cooled?.actions == [.allowAgain, .mute] && cooled?.prominent == false)
        #expect(AsksView.of(AskState(muted: true))?.prominent == true)
        #expect(AsksView.of(AskState(paused: true))?.prominent == true)
    }

    @Test func theSharingName() {
        #expect(Samples.active("c", first: " Ada ", last: "Lovelace").sharingName == "Ada")
        #expect(Samples.active("c", first: nil, last: nil).sharingName == nil)
    }

    @Test func theStateDoesNotPrintNames() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        #expect(!"\(m.state)".contains("Ada") && !String(reflecting: m.state).contains("Ada"))
    }

    // MARK: - Sharing both ways (§10.12)

    /// Only this connection's sharing in force: its rules, the grants given and received that are active (by name), the asks
    /// still waiting.
    @Test func theDetailReadsOnlyThisConnectionsSharingInForce() async {
        fake.connections = [Samples.active("c1")]
        var revoked = outGrant
        revoked.grantID = "g8"
        revoked.state = "revoked"
        var other = outGrant
        other.grantID = "g9"
        other.connectionID = "c9"
        var expired = inGrant
        expired.grantID = "g7"
        expired.state = "expired"
        sharing.rulesStored = [rule1, ShareRule(ruleID: "r9", connectionID: "c9", tags: ["x"])]
        sharing.given = [outGrant, revoked, other]
        sharing.received = [inGrant, expired]
        sharing.requested = [
            GrantAsk(requestID: "q1", connectionID: "c1", entries: [GrantAskEntry(kind: "category", ref: "insurance")], state: "pending"),
            GrantAsk(requestID: "q2", connectionID: "c1", entries: [GrantAskEntry(kind: "category", ref: "medical")], state: "denied"),
        ]
        let m = await model()
        let s = m.state.sharing
        #expect(s.loaded && !s.failed)
        #expect(s.rules.map(\.ruleID) == ["r1"] && s.given.map(\.grantID) == ["g1"] && s.received.map(\.grantID) == ["g3"])
        #expect(s.asked.map(\.requestID) == ["q1"])
        #expect(s.outgoingCount == 1 && s.incomingCount == 1)
        // Back from the rule editor: read again.
        sharing.received = []
        m.loadSharing()
        await m.settle()
        #expect(m.state.sharing.incomingEmpty)
    }

    /// Each item once, however many grants name it; the rules at 64 name the limit.
    @Test func theCountsAndTheLimit() {
        var second = outGrant
        second.grantID = "g2"
        let full = (1...64).map { ShareRule(ruleID: "f\($0)", connectionID: "c1", tags: ["t\($0)"]) }
        let s = DetailSharing(rules: full, given: [outGrant, second], loaded: true)
        #expect(s.outgoingCount == 1 && s.atRuleLimit && !s.outgoingEmpty && s.incomingEmpty)
        #expect(!DetailSharing(rules: [rule1]).atRuleLimit && DetailSharing().outgoingEmpty)
        // Rules that cover the same tag and item name each other (§10.12).
        let twin = ShareRule(ruleID: "r3", connectionID: "c1", tags: ["medical"], included: ["i1"])
        #expect(DetailSharing(rules: [rule1, twin, rule2]).overlaps["r1"]?.map(\.ruleID) == ["r3"])
    }

    /// A rule is deleted only once confirmed, the card is read again, and a refusal shows on the detail.
    @Test func aRuleIsDeletedOnlyOnceConfirmedAndTheCardIsReadAgain() async {
        fake.connections = [Samples.active("c1")]
        sharing.rulesStored = [rule1, rule2]
        let m = await model()
        m.askDeleteRule(rule2)
        #expect(m.state.deleteRule?.ruleID == "r2")
        m.askDeleteRule(nil)
        m.deleteRule()
        await m.settle()
        #expect(!sharing.calls.contains("deleteRule"))
        m.askDeleteRule(rule2)
        m.deleteRule()
        await m.settle()
        #expect(sharing.calls.contains("deleteRule") && m.state.deleteRule == nil)
        #expect(m.state.sharing.rules.map(\.ruleID) == ["r1"])
        sharing.fail["deleteRule"] = VaultFailure(.network)
        m.askDeleteRule(rule1)
        m.deleteRule()
        await m.settle()
        #expect(m.state.error == .network)
    }

    /// The vault cannot say what is shared: the card says so and the rest of the detail stays.
    @Test func aSharingFailureLeavesTheRestOfTheDetail() async {
        fake.connections = [Samples.active("c1")]
        sharing.fail["rules"] = VaultFailure(.network)
        let m = await model()
        #expect(m.state.sharing.failed && m.state.sharing.loaded && m.state.error == nil && m.state.connection?.id == "c1")
    }

    /// Without a sharing repository (an app without the Vault) nothing is read or deleted.
    @Test func withoutSharingNothingIsRead() async {
        fake.connections = [Samples.active("c1")]
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        await m.settle()
        m.askDeleteRule(rule1)
        m.deleteRule()
        await m.settle()
        #expect(!m.state.sharing.loaded && sharing.calls.isEmpty)
    }

    @Test func theSharingDoesNotPrintNames() async {
        fake.connections = [Samples.active("c1")]
        sharing.given = [outGrant]
        let m = await model()
        #expect(!"\(m.state.sharing)".contains("Allergies") && !String(reflecting: m.state.sharing).contains("Allergies"))
    }

    /// Once the vault no longer lists the connection nothing of its sharing stays: the cards, a rule waiting to be deleted,
    /// and an answer still on its way.
    @Test func theSharingGoesWithTheConnection() async {
        fake.connections = [Samples.active("c1"), Samples.active("c2")]
        sharing.rulesStored = [rule1]
        sharing.given = [outGrant]
        let m = await model()
        #expect(m.state.sharing.loaded && !m.state.sharing.rules.isEmpty)
        m.askDeleteRule(rule1)
        fake.connections = []
        await m.settle()
        #expect(m.state.gone && m.state.deleteRule == nil)
        #expect(m.state.sharing == DetailSharing())
        // A read that lands after that is dropped.
        m.loadSharing()
        await m.settle()
        #expect(m.state.sharing == DetailSharing())
    }
}
