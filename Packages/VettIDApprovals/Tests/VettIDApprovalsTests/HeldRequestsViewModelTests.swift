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

    private func show(_ h: HeldApproval, read: ItemsRead = .read, in list: [ItemSummary]? = nil) -> HeldShow {
        guard case .device(let d) = Self.held(h) else { return .other }
        return DeviceAsks.show(d, items: list ?? items.items, read: read)
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
        #expect(show(Self.get, read: .reading, in: []) == .noItem(use: false, loading: true), "still being read: Loading…")
        #expect(show(Self.get, read: .failed, in: []) == .itemsUnread && !show(Self.get, read: .failed, in: []).approvable, "not read: not said to be gone")
        #expect(show(Self.get, read: .failed) == .itemsUnread, "a failed re-read says why Approve is off")
        #expect(show(.itemUse(itemID: "i1", fieldID: "f1", data: [1]), read: .failed) == .itemsUnread && show(.itemUse(itemID: "i9", fieldID: "f1", data: [1]), read: .failed) == .itemsUnread)
        // A catalog names no item; it keeps its own text, and needs no list (``ApprovalDetailState/canApprove(at:)``).
        #expect(show(.catalog, read: .failed) == .catalog && show(.unshown, read: .failed) == .other && show(.desktopStepUp, read: .failed) == .desktop)
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
        #expect(show(.itemRun(run), read: .reading, in: []) == .later(item: nil, loading: true))
        // A run and a proxy are deny only whatever is read: they keep their own text after a failed read.
        #expect(show(.itemRun(run), read: .failed) == .later(item: "GitHub", loading: false))
        #expect(show(.itemProxy(proxy), read: .failed) == .later(item: "GitHub", loading: false))
        #expect(show(.itemRun(run), read: .failed, in: []) == .laterUnread, "not said to be an item you no longer have")
        #expect(show(.itemProxy(proxy), read: .failed, in: []) == .laterUnread && !HeldShow.laterUnread.approvable)
    }

    @Test func aRevealIsApprovedFromItsScreenAndTheAnswerIsSaidBeforeItCloses() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        #expect(m.state.canApprove() && m.state.heldShow == .get(item: "GitHub", fields: ["Token"]))
        m.approve(held: m.shownHeld())
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
        for (result, outcome) in [("referred", DeviceOutcome.approved(result: "referred")), ("forbidden", .approved(result: "forbidden")), ("way_not_allowed", .approved(result: "way_not_allowed")), ("not_found", .approved(result: "not_found"))] {
            fake.listed = [Self.held(Self.get)]
            fake.deviceResult = result
            let m = await model()
            m.approve(held: m.shownHeld())
            await m.settle()
            #expect(m.state.outcome == outcome, Comment(rawValue: result))
        }
        fake.listed = [Self.held(Self.get)]
        fake.deviceResult = nil
        let m = await model()
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(m.state.outcome == .approved(result: nil), "no result: never read as approved")
    }

    @Test func aRequestTheVaultNoLongerKnowsIsNoLongerWaiting() async {
        fake.listed = [Self.held(Self.get)]
        fake.fail["approveDeviceRequest"] = VaultFailure(.notFound)
        let m = await model()
        m.approve(held: m.shownHeld())
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
        m.approve(held: m.shownHeld())
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
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(fake.calls.isEmpty)
        // A failed read is not a read: never "an item you no longer have", and still no Approve.
        empty.load = .failed
        #expect(m.state.heldShow == .itemsUnread && m.state.itemsRead == .failed && !m.state.canApprove())
        empty.load = .loading
        #expect(m.state.heldShow == .noItem(use: false, loading: true), "not read yet: Loading… again")
        empty.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x")]))
        empty.load = .loaded
        #expect(m.state.canApprove())
        // A later read does not turn it back into Loading… once the list was read.
        empty.load = .loading
        #expect(m.state.canApprove() && m.state.heldShow == .get(item: "GitHub", fields: ["Token"]))
        // A failed re-read switches Approve off.
        empty.load = .failed
        #expect(!m.state.canApprove())
        empty.load = .loaded
        #expect(m.state.canApprove())
    }

    /// A lock drops the item list (`notLoaded`): what was read before it no longer counts.
    @Test func aDroppedItemListIsReadAgainBeforeApproveComesBack() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        #expect(m.state.canApprove() && items.calls.filter { $0 == "refreshQuietly" }.count == 1)
        items.clear()
        #expect(m.state.itemsRead == .reading && !m.state.canApprove() && m.state.heldShow == .noItem(use: false, loading: true))
        // The request held again (the vault opened again, the vault's copy read back): the list is read again with it.
        var again = Self.held(Self.get)
        if case .device(var d) = again { d.deviceName = "Bot again"; again = .device(d) }
        fake.listed = [again]
        await m.settle()
        for _ in 0..<50 where items.calls.filter({ $0 == "refreshQuietly" }).count < 2 { await Task.yield() }
        #expect(items.calls.filter { $0 == "refreshQuietly" }.count == 2 && m.state.canApprove())
    }

    /// A lock clears the list and the read after it starts before any screen state is read (behind the lock screen nothing
    /// renders): the list read before the lock still does not count, on the detail screen or in the list.
    @Test func aListClearedAndBeingReadAgainUnseenIsNotTakenAsRead() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        let list = ApprovalsViewModel(approvals: fake, connections: connections, items: items)
        #expect(m.state.canApprove() && list.state.itemsRead == .read)
        items.clear()
        items.load = .loading
        #expect(m.state.itemsRead == .reading && !m.state.canApprove() && m.state.heldShow == .noItem(use: false, loading: true))
        #expect(list.state.itemsRead == .reading && list.state.heldShow(list.state.approvals[0]) == .noItem(use: false, loading: true))
        items.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x")]))
        items.load = .loaded
        #expect(m.state.canApprove() && list.state.itemsRead == .read)
    }

    /// A re-read that fails after the list was read: Approve is off, and the screen says why.
    @Test func aFailedReReadSaysWhyApproveIsOff() async {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        #expect(m.state.canApprove())
        items.load = .failed
        #expect(!m.state.canApprove() && m.state.heldShow == .itemsUnread && m.state.offersItemsRetry)
        // The list read again after that failure: still not read until it answers, so Approve stays off meanwhile.
        items.load = .loading
        #expect(m.state.itemsRead == .reading && !m.state.canApprove())
        items.load = .loaded
        #expect(m.state.canApprove() && !m.state.offersItemsRetry)
    }

    /// A catalog, a run and a proxy say nothing of the items after a failed read; a catalog's Approve is off until a read.
    /// After a failed read a run and a proxy keep their text, deny only; a catalog, which names no item, is approved without the
    /// list (it is not about one item, so "your items could not be read" would not say why).
    @Test func aFailedReadLeavesACatalogRunAndProxyTheirOwnTexts() async {
        let run = ItemRun(itemID: "i1", fieldID: "f1", program: "/bin/x", sha256: Self.sha, argv: ["x"], cwd: nil, how: .env, name: "T", env: [], flags: [], previousSha256: nil, previousPath: nil, replaces: nil)
        let proxy = ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: "Bearer ", seconds: 900, replaces: nil)
        for (h, show) in [(HeldApproval.itemRun(run), HeldShow.later(item: "GitHub", loading: false)), (.itemProxy(proxy), .later(item: "GitHub", loading: false))] {
            fake.listed = [Self.held(h)]
            items.load = .loaded
            let m = await model()
            items.load = .failed
            #expect(m.state.heldShow == show && !m.state.canApprove() && !m.state.offersItemsRetry, "\(show)")
        }
        fake.listed = [Self.held(.catalog)]
        let m = await model()
        items.load = .failed
        #expect(m.state.heldShow == .catalog && m.state.canApprove() && !m.state.offersItemsRetry)
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"] && m.state.outcome == .approved(result: "ok"))
    }

    /// A list that could not be read is read again when the screen opens, and on Try again; nothing else reads it.
    @Test func aFailedListIsReadAgainOnOpeningAndOnTryAgain() async {
        fake.listed = [Self.held(Self.get)]
        items.load = .failed
        items.fail["refreshQuietly"] = VaultFailure(.network)
        let m = await model()
        #expect(items.calls == ["refreshQuietly"], "read again on opening")
        #expect(m.state.offersItemsRetry && !m.state.canApprove())
        items.fail["refreshQuietly"] = VaultFailure(.network)
        m.retryItems()
        #expect(items.calls == ["refreshQuietly", "refreshQuietly"] && !m.state.canApprove(), "still failed: Approve off")
        m.retryItems()
        #expect(m.state.canApprove() && !m.state.offersItemsRetry, "read: Approve back")
        m.retryItems()
        #expect(items.calls.count == 3, "nothing to retry once read")
    }

    /// A lock while the approval is on its way drops it from this phone: "No longer on this phone", not "no longer waiting".
    @Test func aLockWhileTheApprovalIsOnItsWayIsNoLongerOnThisPhone() async throws {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        let rendered = try #require(m.shownHeld())
        fake.fail["approveDeviceRequest"] = VaultFailure(.notFound)
        fake.duringDeviceApproval = { [fake] in fake.forgetOpenVault() }
        m.approve(held: rendered)
        await m.settle()
        #expect(m.state.outcome == nil && m.state.notHeld && !m.state.busy && m.state.error == nil)
    }

    /// Approve sends what the screen showed when it rendered: a request, or its item's name, that changed since is not approved.
    @Test func approveSendsTheRequestAsRenderedAndNothingThatChangedSince() async throws {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        let rendered = try #require(m.shownHeld())
        #expect(rendered.show == .get(item: "GitHub", fields: ["Token"]) && rendered.generation == fake.forgetCount)
        // The item is renamed between the render and the tap.
        items.add(FakeItems.item("i1", "GitHub (work)", sensitivity: .secret, fields: [("Token", "x"), ("User", "y")]))
        m.approve(held: rendered)
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"] && m.state.error == .requestChanged && m.state.outcome == nil)
        #expect(FailureKind.requestChanged.message == "This request changed while you were reading it. Read it again before you answer.")
        // Rendered again: approved as shown now.
        fake.calls = []
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"] && m.state.outcome == .approved(result: "ok"))
        let sent = try #require(fake.lastDeviceApproval)
        #expect(sent.shown.sameContent(as: rendered.request) && sent.stillShown)
    }

    @Test func approveSendsNothingWithoutTheRenderedRequestOrAcrossALock() async throws {
        fake.listed = [Self.held(Self.get)]
        let m = await model()
        m.approve()
        await m.settle()
        #expect(fake.calls.isEmpty, "no rendered request: nothing")
        let rendered = try #require(m.shownHeld())
        // The vault locked and opened again since the render: the same request, but read again.
        fake.forgetOpenVault()
        fake.listed = [Self.held(Self.get)]
        m.approve(held: rendered)
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"] && m.state.error == .requestChanged)
        // The request itself changed since the render (another field): its own render is needed.
        fake.calls = []
        fake.listed = [Self.held(.itemGet(itemID: "i1", fieldIDs: ["f2"]))]
        m.approve(held: m.shownHeld().map { var x = $0; x.request = rendered.request; x.show = rendered.show; return x })
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"])
    }

    @Test func aRunAndAnUnshownRequestAreNeverApprovedFromTheScreen() async {
        let run = ItemRun(itemID: "i1", fieldID: "f1", program: "/bin/x", sha256: Self.sha, argv: ["x"], cwd: nil, how: .env, name: "T", env: [], flags: [], previousSha256: nil, previousPath: nil, replaces: nil)
        for h in [HeldApproval.itemRun(run), .unshown, .desktopStepUp] {
            fake.listed = [Self.held(h)]
            let m = await model()
            #expect(!m.state.canApprove())
            m.approve(held: m.shownHeld())
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
