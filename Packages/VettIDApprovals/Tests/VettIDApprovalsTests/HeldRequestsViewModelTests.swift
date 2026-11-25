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
        let m = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items ?? self.items, cwdWaits: Self.quick)
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

    static func run(
        argv: [String] = ["x"], flags: Set<RunFlag> = [], cwd: String? = nil, previous: (String, String)? = nil, replaces: String? = nil
    ) -> ItemRun {
        ItemRun(
            itemID: "i1", fieldID: "f1", program: "/bin/x", sha256: sha, argv: argv, cwd: cwd, how: .env, name: "T", env: [], flags: flags,
            previousSha256: previous?.0, previousPath: previous?.1, replaces: replaces
        )
    }

    static let proxy = ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: "Bearer ", seconds: 900, replaces: nil)

    /// AA8: a run and a proxy are shown from the item list on their own screens, and approvable.
    @Test func aRunAndAProxyAreShownAndApprovable() {
        let run = Self.run()
        #expect(show(.itemRun(run)) == .run(run, item: "GitHub", field: "Token") && show(.itemRun(run)).approvable)
        #expect(show(.itemProxy(Self.proxy)) == .proxy(Self.proxy, item: "GitHub", field: "Token") && show(.itemProxy(Self.proxy)).approvable)
        #expect(show(.itemRun(run), in: []) == .noItem(use: true, loading: false), "an item you no longer have")
        #expect(show(.itemProxy(Self.proxy), read: .reading, in: []) == .noItem(use: true, loading: true))
        var other = run
        other.fieldID = "f9"
        #expect(show(.itemRun(other)) == .noItem(use: true, loading: false), "a field the list cannot name")
        // After a failed read a run and a proxy name an item they cannot name now: the items could not be read, deny only.
        #expect(show(.itemRun(run), read: .failed) == .itemsUnread && show(.itemProxy(Self.proxy), read: .failed) == .itemsUnread)
        #expect(show(.itemRun(run), read: .failed, in: []) == .itemsUnread && !HeldShow.itemsUnread.approvable)
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

    /// After a failed read a run and a proxy, which name an item and its field (AA8), say the items could not be read and offer
    /// Try again, deny only meanwhile; a catalog, which names no item, is approved without the list (it is not about one item,
    /// so "your items could not be read" would not say why).
    @Test func aFailedReadLeavesACatalogApprovableAndARunOrProxyUnread() async {
        for h in [HeldApproval.itemRun(Self.run()), .itemProxy(Self.proxy)] {
            fake.listed = [Self.held(h)]
            items.load = .loaded
            let m = await model()
            items.load = .failed
            #expect(m.state.heldShow == .itemsUnread && !m.state.canApprove() && m.state.offersItemsRetry, "\(h)")
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

    @Test func anUnshownRequestAndADesktopsAreNeverApprovedFromTheScreen() async {
        for h in [HeldApproval.unshown, .desktopStepUp] {
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

    // MARK: - A run and a proxy (AA8)

    /// Two waits: three reads.
    static let quick: [Duration] = [.milliseconds(1), .milliseconds(1)]

    @Test func aRunIsApprovedFromItsScreenAndSaysWhatTheVaultAnswered() async {
        fake.listed = [Self.held(.itemRun(Self.run(flags: [.programUnrecorded])))]
        fake.recorded = true
        let m = await model()
        #expect(m.state.canApprove() && m.state.heldShow == .run(Self.run(flags: [.programUnrecorded]), item: "GitHub", field: "Token"))
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(m.state.outcome == .approved(result: "ok", way: .run, pinRecorded: true, item: "GitHub"))
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"])
    }

    @Test func aFingerprintIsSaidRecordedOnlyWhenTheSettingsShowItAndOnlyForTheFlagsThatRecordOne() async {
        for (flags, recorded, said) in [(Set<RunFlag>([.programUnrecorded]), false, false), ([.programChanged], true, true), ([.shell], true, false)] {
            fake.listed = [Self.held(.itemRun(Self.run(flags: flags, previous: flags.contains(.programChanged) ? (Self.sha, "/bin/x") : nil)))]
            fake.recorded = recorded
            let m = await model()
            m.approve(held: m.shownHeld())
            await m.settle()
            guard case .approved(_, _, let pin, _)? = m.state.outcome else { Issue.record("no outcome"); return }
            #expect(pin == said, Comment(rawValue: "\(flags) \(recorded)"))
        }
    }

    @Test func aProxyIsApprovedAndAnAnswerOfNotFoundIsItsOwn() async {
        fake.listed = [Self.held(.itemProxy(Self.proxy))]
        fake.deviceResult = "not_found"
        let m = await model()
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(m.state.outcome == .approved(result: "not_found", way: .proxy, pinRecorded: false, item: "GitHub"))
    }

    @Test func aRunOrProxyReferredAgainClosesWithItsText() async {
        for h in [HeldApproval.itemRun(Self.run()), .itemProxy(Self.proxy)] {
            fake.listed = [Self.held(h)]
            fake.deviceResult = "referred"
            let m = await model()
            m.approve(held: m.shownHeld())
            await m.settle()
            #expect(m.state.outcome == .referred)
        }
    }

    /// AA8 "Fail closed": a `cwd` without `member_folder` is Deny only until the item's settings, read for the run's own agent and
    /// item, allow it; the run's own screen shows meanwhile, saying its rule is being checked.
    @Test func aRunWithACwdIsDenyOnlyUntilTheSettingsAllowIt() async {
        let run = Self.run(cwd: "/home/me")
        fake.listed = [Self.held(.itemRun(run))]
        fake.cwdRuleQueue = [nil, nil, true]
        let m = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items, cwdWaits: Self.quick)
        #expect(m.state.heldShow == .run(run, item: "GitHub", field: "Token") && m.state.cwdCheck == .checking && !m.state.canApprove(), "its own screen, deny only")
        for _ in 0..<200 where m.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.state.cwdAllowed == true && m.state.cwdCheck == nil && m.state.canApprove() && fake.cwdReads == 3)
    }

    /// Three failed reads: the run's screen says it cannot be checked yet, with Try again, and no wait after the last read; Try
    /// again and an unlock read again. With `folders` it is Deny only, on its own screen.
    @Test func aRunWithACwdWhoseRuleCannotBeReadOffersTryAgain() async {
        let run = Self.run(cwd: "/home/me")
        fake.listed = [Self.held(.itemRun(run))]
        fake.cwdRule = nil
        let waits: [Duration] = [.milliseconds(1), .milliseconds(1)]
        let failing = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items, cwdWaits: waits)
        for _ in 0..<200 where !failing.state.cwdFailed { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(failing.state.cwdCheck == .failed && !failing.state.canApprove() && fake.cwdReads == 3 && failing.state.heldShow == .run(run, item: "GitHub", field: "Token"))
        // Try again.
        fake.cwdRuleQueue = [true]
        failing.retryCwdRule()
        for _ in 0..<200 where failing.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(failing.state.cwdCheck == nil && failing.state.canApprove() && fake.cwdReads == 4)
        failing.retryCwdRule()
        #expect(fake.cwdReads == 4, "nothing to retry once read")
        // An unlock: the approval held again reads a failed rule again.
        let locked = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items, cwdWaits: waits)
        for _ in 0..<200 where !locked.state.cwdFailed { try? await Task.sleep(for: .milliseconds(10)) }
        let before = fake.cwdReads
        fake.cwdRule = true
        fake.forgetOpenVault()
        fake.listed = [Self.held(.itemRun(run))]
        for _ in 0..<200 where locked.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(locked.state.cwdAllowed == true && fake.cwdReads == before + 1)
        // Folders: Deny only, on its own screen.
        fake.cwdRule = false
        let folders = await model()
        for _ in 0..<200 where folders.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(folders.state.cwdCheck == .notAllowed && !folders.state.canApprove() && folders.state.heldShow == .run(run, item: "GitHub", field: "Token"))
        // A run without a cwd never reads.
        let reads = fake.cwdReads
        fake.listed = [Self.held(.itemRun(Self.run()))]
        let plain = await model()
        #expect(plain.state.canApprove() && plain.state.cwdCheck == nil && fake.cwdReads == reads)
    }

    /// The rule holds only for the agent and the item it was read for.
    @Test func aCwdRuleReadForAnotherAgentOrItemIsNotTheRunsRule() async {
        fake.listed = [Self.held(.itemRun(Self.run(cwd: "/home/me")))]
        let m = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: connections, vault: items, cwdWaits: Self.quick)
        for _ in 0..<200 where m.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.state.canApprove() && m.state.cwdReadFor == CwdReadFor(agentID: "A", itemID: "i1"))
        for other in [CwdReadFor(agentID: "B", itemID: "i1"), CwdReadFor(agentID: "A", itemID: "i2")] {
            m.local.cwdReadFor = other
            #expect(m.state.cwdCheck != nil && !m.state.canApprove(), "\(other)")
        }
    }

    /// "Already decided" stays so after `exp` passes: only a request still held at its `exp` expired (AA8 "Refused or expired").
    @Test func aRequestDecidedElsewhereBeforeItsExpDidNotExpire() async {
        let exp = Date().addingTimeInterval(300)
        var d = DeviceRequest(type: "approval.pending", id: "h1", deviceName: "Bot", role: "agent", requestType: "agent.request", receivedAt: Samples.t0, exp: exp, deviceID: "A", held: .itemRun(Self.run()))
        fake.listed = [.device(d)]
        let m = await model()
        #expect(m.state.leftAt == nil && m.state.endedByExpiry(at: exp.addingTimeInterval(1)), "held at its exp: it expires")
        fake.listed = []
        await m.settle()
        #expect(m.state.gone && m.state.leftAt != nil && !m.state.endedByExpiry(at: exp.addingTimeInterval(60)), "gone before exp: not expired")
        // Held until its `exp`: expired.
        d.id = "h2"
        let held = ApprovalDetailState(key: "device:approval.pending:h2")
        var s = held
        s.approval = .device(d)
        #expect(s.endedByExpiry(at: exp.addingTimeInterval(1)) && !s.endedByExpiry(at: exp.addingTimeInterval(-1)))
        s.leftAt = exp.addingTimeInterval(5)
        #expect(s.endedByExpiry(at: exp.addingTimeInterval(10)), "dropped after its exp")
    }

    /// "Approved" is said at once; that the fingerprint is recorded comes when the read answers.
    @Test func approvedIsSaidBeforeThePinIsRead() async {
        fake.listed = [Self.held(.itemRun(Self.run(flags: [.programUnrecorded])))]
        fake.recorded = true
        fake.pinHold = TestDeferred<Void>()
        let m = await model()
        m.approve(held: m.shownHeld())
        for _ in 0..<200 where m.state.outcome == nil { await Task.yield() }
        #expect(m.state.outcome == .approved(result: "ok", way: .run, pinRecorded: false, item: "GitHub"), "at once")
        fake.pinHold?.complete(())
        await m.settle()
        #expect(m.state.outcome == .approved(result: "ok", way: .run, pinRecorded: true, item: "GitHub"))
    }

    @Test func aRunListedAfterTheScreenOpenedReadsItsRuleThen() async {
        let m = await model()
        #expect(m.state.approval == nil)
        fake.listed = [Self.held(.itemRun(Self.run(cwd: "/home/me")))]
        for _ in 0..<200 where m.state.cwdAllowed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.state.cwdAllowed == true)
    }

    /// A run and a proxy go through the same render-time capture as a use: renamed since the render, or across a lock, nothing is
    /// approved; rendered again, the request is sent as shown now.
    @Test func aRunOrProxyIsApprovedOnlyAsRendered() async throws {
        for h in [HeldApproval.itemRun(Self.run()), .itemProxy(Self.proxy)] {
            fake.calls = []
            fake.listed = [Self.held(h)]
            items.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x"), ("User", "y")]))
            let m = await model()
            let rendered = try #require(m.shownHeld())
            items.add(FakeItems.item("i1", "GitHub (work)", sensitivity: .secret, fields: [("Token", "x"), ("User", "y")]))
            m.approve(held: rendered)
            await m.settle()
            #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"] && m.state.error == .requestChanged, "renamed: \(h)")
            let again = try #require(m.shownHeld())
            fake.forgetOpenVault()
            fake.listed = [Self.held(h)]
            m.approve(held: again)
            await m.settle()
            #expect(fake.calls.last == "approveDeviceRequest:changed:\(Self.key)", "across a lock: \(h)")
            m.approve(held: m.shownHeld())
            await m.settle()
            #expect(fake.calls.last == "approveDeviceRequest:\(Self.key)", "rendered again: \(h)")
        }
    }
}

// swiftlint:enable line_length
