import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.116 AA5 and 0.1.137 AA8: what a request an agent holds for approval shows (from the member's item list, never
/// from the agent's words), when Approve is offered, and how a decision ends. Mirrors vettid-android `DeviceApprovalsViewModelTest`
/// and `DeviceAsksTest`.
@MainActor
@Suite struct HeldRequestsViewModelTests {
    let connections = FakeConnections()
    let fake: FakeApprovals
    let items = FakeItems()

    init() {
        fake = FakeApprovals(connections: connections)
        items.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x"), ("User", "y")]))
    }

    static let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)

    static func held(_ h: HeldApproval, id: String = "h1", role: String = "agent") -> PendingApproval {
        .device(DeviceRequest(
            type: "approval.pending", id: id, deviceName: "Bot", role: role, requestType: "agent.request",
            receivedAt: Samples.t0, exp: Date().addingTimeInterval(300), deviceID: "A", held: h
        ))
    }

    static let get = HeldApproval.itemGet(itemID: "i1", fieldIDs: ["f1"])
    static let key = "device:approval.pending:h1"

    func model(_ items: (any ItemsRepository)? = nil) async -> ApprovalDetailViewModel {
        let m = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items ?? self.items)
        await m.settle()
        return m
    }

    private func show(_ h: HeldApproval, loaded: Bool = true, in list: [ItemSummary]? = nil) -> HeldShow {
        guard case .device(let d) = Self.held(h) else { return .other }
        return DeviceAsks.show(d, items: list ?? items.items, loaded: loaded)
    }

    @Test func eachHeldRequestShowsWhatTheItemListNames() {
        #expect(show(.itemUse(itemID: "i1", fieldID: "f2", data: Array("hello".utf8))) == .use(item: "GitHub", field: "User", data: .text("hello"), bytes: 5))
        #expect(show(.itemUse(itemID: "i1", fieldID: "f2", data: [0xFF, 0x00])) == .use(item: "GitHub", field: "User", data: .hex("ff 00"), bytes: 2))
        #expect(show(Self.get) == .get(item: "GitHub", fields: ["Token"]))
        #expect(show(.itemGet(itemID: "i1", fieldIDs: nil)) == .get(item: "GitHub", fields: nil))
        #expect(show(.catalog) == .catalog)
        #expect(show(.desktopStepUp) == .desktop && show(.unshown) == .other)
        for h in [HeldApproval.itemUse(itemID: "i1", fieldID: "f2", data: [1]), Self.get, .catalog] { #expect(show(h).approvable) }
        for h in [HeldApproval.desktopStepUp, .unshown] { #expect(!show(h).approvable) }
    }

    @Test func anItemOrFieldTheListCannotNameIsAnItemYouNoLongerHave() {
        #expect(show(.itemUse(itemID: "i9", fieldID: "f1", data: [1])) == .noItem(use: true, loading: false))
        #expect(show(.itemUse(itemID: "i1", fieldID: "f9", data: [1])) == .noItem(use: true, loading: false))
        #expect(show(.itemGet(itemID: "i1", fieldIDs: ["f1", "f9"])) == .noItem(use: false, loading: false), "a field this phone cannot name is not shown unseen")
        #expect(show(Self.get, in: []) == .noItem(use: false, loading: false))
        #expect(show(Self.get, loaded: false, in: []) == .noItem(use: false, loading: true), "still being read: Loading…")
        #expect(!show(Self.get, in: []).approvable)
        // An item whose name cleans to nothing is not named.
        let blank = [ItemSummary(itemID: "i1", version: 1, name: "\u{200B}", category: "x", sensitivity: .secret, fieldLabels: [ItemFieldLabel(fieldID: "f1", label: "T", kind: "text")])]
        #expect(show(Self.get, in: blank) == .noItem(use: false, loading: false))
    }

    /// Until AA8's screens (the next step), a run and a proxy are shown by "a way this version can't show": deny only.
    @Test func aRunAndAProxyAreNotYetApprovedHere() {
        let run = ItemRun(itemID: "i1", fieldID: "f1", program: "/bin/x", sha256: Self.sha, argv: ["x"], cwd: nil, how: .env, name: "T", env: [], flags: [], previousSha256: nil, previousPath: nil, replaces: nil)
        let proxy = ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: "Bearer ", seconds: 900, replaces: nil)
        #expect(show(.itemRun(run)) == .later(item: "GitHub", loading: false) && !show(.itemRun(run)).approvable)
        #expect(show(.itemProxy(proxy)) == .later(item: "GitHub", loading: false))
        #expect(show(.itemRun(run), loaded: false, in: []) == .later(item: nil, loading: true))
    }

    @Test func aRevealIsApprovedFromItsScreenAndTheAnswerIsSaidBeforeItCloses() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        #expect(m.state.canApprove() && m.state.heldShow == .get(item: "GitHub", fields: ["Token"]))
        m.approve()
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"])
        // The approval left the list; the screen stays with the answer, not "Already decided".
        #expect(m.state.outcome == .approved(result: "ok") && !m.state.done && !m.state.gone && m.state.approval != nil)
        m.finish()
        #expect(m.state.done)
    }

    @Test func theVaultsAnswersAreKeptAsTheyCame() async {
        // Only a run or a proxy is referred again; for a reveal `referred` is a result like another (AA5's "Approved, but your vault
        // answered: referred.").
        for (result, outcome) in [("referred", DeviceOutcome.approved(result: "referred")), ("forbidden", .approved(result: "forbidden")), ("way_not_allowed", .approved(result: "way_not_allowed"))] {
            fake.listed = [Self.held(Self.get)]
            fake.deviceResult = result
            let m = await model()
            m.approve()
            await m.settle()
            #expect(m.state.outcome == outcome, Comment(rawValue: result))
        }
        fake.listed = [Self.held(Self.get)]
        fake.deviceResult = nil
        let m = await model()
        m.approve()
        await m.settle()
        #expect(m.state.outcome == .approved(result: nil), "no result: never read as approved")
    }

    @Test func aRequestTheVaultNoLongerKnowsIsNoLongerWaiting() async {
        fake.listed = [Self.held(Self.get)]
        fake.fail["approveDeviceRequest"] = VaultFailure(.notFound)
        let m = await model()
        m.approve()
        await m.settle()
        #expect(m.state.outcome == .noLongerWaiting && m.state.error == nil)
        fake.listed = [Self.held(Self.get)]
        fake.fail["declineDeviceRequest"] = VaultFailure(.notFound)
        let d = await model()
        d.deny()
        await d.settle()
        #expect(d.state.outcome == .noLongerWaiting)
    }

    @Test func anotherFailureKeepsTheRequestAndSaysWhy() async {
        fake.listed = [Self.held(Self.get)]
        fake.fail["approveDeviceRequest"] = VaultFailure(.notSupported)
        let m = await model()
        m.approve()
        await m.settle()
        #expect(m.state.error == .notSupported && m.state.outcome == nil && !m.state.busy && m.state.approval != nil)
    }

    @Test func denyingSaysDeniedBeforeItCloses() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        m.deny()
        await m.settle()
        #expect(fake.calls == ["declineDeviceRequest:\(Self.key)"] && m.state.outcome == .denied && !m.state.gone)
    }

    @Test func approveIsOfferedOnlyOnceTheItemListWasRead() async {
        fake.listed = [Self.held(Self.get)]
        let empty = FakeItems()
        empty.load = .loading
        let m = await model(empty)
        #expect(m.state.heldShow == .noItem(use: false, loading: true) && !m.state.canApprove(), "still being read: Loading…, no Approve")
        m.approve()
        await m.settle()
        #expect(fake.calls.isEmpty)
        empty.load = .failed
        #expect(m.state.heldShow == .noItem(use: false, loading: false) && !m.state.canApprove(), "failed: an item you no longer have, deny only")
        // A later read does not turn it back into Loading… once the list was read.
        empty.load = .loading
        #expect(m.state.heldShow == .noItem(use: false, loading: false))
        empty.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x")]))
        empty.load = .loaded
        #expect(m.state.canApprove())
    }

    @Test func aRunAndAnUnshownRequestAreNeverApprovedFromTheScreen() async {
        let run = ItemRun(itemID: "i1", fieldID: "f1", program: "/bin/x", sha256: Self.sha, argv: ["x"], cwd: nil, how: .env, name: "T", env: [], flags: [], previousSha256: nil, previousPath: nil, replaces: nil)
        for h in [HeldApproval.itemRun(run), .unshown, .desktopStepUp] {
            fake.listed = [Self.held(h)]
            let m = await model()
            #expect(!m.state.canApprove())
            m.approve()
            await m.settle()
            #expect(fake.calls.isEmpty && m.state.outcome == nil)
        }
    }

    @Test func aSessionRequestIsNotAHeldRequest() async {
        fake.listed = [Samples.device("device.session.pending")]
        let m = ApprovalDetailViewModel(key: "device:device.session.pending:d1", approvals: fake, connections: connections, vault: items)
        #expect(m.state.heldShow == nil && !m.state.canApprove())
    }
}

// swiftlint:enable line_length
