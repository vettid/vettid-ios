import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.138 §4 AA8: an agent's run and proxy approvals are read strictly from the vault's own text, through events,
/// the store and pending.list; a listed approval that differs is deny only; one referred again replaces its old one. Mirrors
/// vettid-android `AgentApprovalsFlowTest`.
@MainActor
@Suite struct AgentApprovalsFlowTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)

    init() { ops.pendingSupported = true }

    /// The item list as the app has it: item `i1` with fields `f1` and `f2`.
    static let cache = [ItemSummary(
        itemID: "i1", version: 1, name: "GitHub", category: "login", sensitivity: .secret,
        fieldLabels: [ItemFieldLabel(fieldID: "f1", label: "Token", kind: "password"), ItemFieldLabel(fieldID: "f2", label: "User", kind: "text")]
    )]

    /// [cache] the item list the approval is resolved against; [cwd] answers whether the item's settings allow a run's `cwd`
    /// (told the agent and the item it asked for).
    func manager(
        cache: [ItemSummary] = cache, cwd: @escaping @MainActor (String, String) async -> Bool = { _, _ in false }
    ) -> ApprovalsManager {
        let ops = ops, connOps = connOps, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        return ApprovalsManager(connections: c, ops: { ops }, now: { now }, itemCache: { cache }, runCwdAllowed: cwd)
    }

    func event(_ body: String, ts: Date? = nil) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "approval.pending", ts: ts ?? now, body: Array(body.utf8)))
    }

    var exp: String { Timestamps.formatMillis(now.addingTimeInterval(600)) }

    func held(_ id: String, _ body: String, top: String = "", device: String = "A", name: String = "Bot") -> String {
        #"{"approval_id":"\#(id)","device_id":"\#(device)","role":"agent","name":"\#(name)","type":"agent.request","body":\#(body),"exp":"\#(exp)"\#(top)}"#
    }

    func runBody(_ argv: String = #"["git","status"]"#) -> String {
        #"{"op":"item.run","item_id":"i1","field_id":"f1","program":"/usr/bin/git","sha256":"\#(sha)","argv":\#(argv),"how":"env","name":"GH_TOKEN"}"#
    }

    let use = #"{"op":"item.use","item_id":"i1","field_id":"f1","action":"hmac-sha256","data":"AAEC"}"#

    func listed(_ bodies: String...) {
        ops.pendingAsks = bodies.map { (kind: "approval", body: $0) }
        ops.pendingTs = now
    }

    func request(_ m: ApprovalsManager, _ id: String) throws -> DeviceRequest {
        let key = "device:approval.pending:\(id)"
        guard case .device(let d)? = m.approvals.first(where: { $0.key == key }) else { throw CocoaError(.fileNoSuchFile) }
        return d
    }

    func keys(_ m: ApprovalsManager) -> [String] { m.approvals.map(\.key).sorted() }

    /// The kept events of the approval [id]: what the store holds, whatever the list of approvals shows.
    func stored(_ m: ApprovalsManager, _ id: String) -> [ApprovalsManager.StoredEvent] {
        m.stored.filter { $0.body.contains(#""approval_id":"\#(id)""#) }
    }

    func isRun(_ d: DeviceRequest) -> Bool { if case .itemRun? = d.held { true } else { false } }

    @Test func aRunEventIsReadStrictlyAndKeptAsTheVaultWroteIt() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        // A duplicate member: the lenient reading would keep the last one and look fine.
        m.onEvent(event(held("h2", runBody().replacingOccurrences(of: #""how":"env""#, with: #""how":"stdin","how":"env""#))))
        guard case .itemRun(let run)? = try request(m, "h1").held else { throw CocoaError(.fileNoSuchFile) }
        #expect(run.argv == ["git", "status"])
        #expect(try request(m, "h1").held?.approvable == false, "read in full, deny only until their screens ship")
        // Kept and shown, but deny only: the member can still deny it. Made again from what was stored: still deny only.
        #expect(try request(m, "h2").held == .unshown)
        #expect(m.stored.contains { $0.body.contains(#""how":"stdin""#) } == false, "the unreadable text is not kept")
        let d = try request(m, "h2")
        #expect(d.deviceName == "Bot" && d.deviceID == "A")
    }

    @Test func aDuplicateInAUseOrACatalogIsDenyOnlyToo() throws {
        let m = manager()
        m.onEvent(event(held("h1", use.replacingOccurrences(of: #""action""#, with: #""data":"AAEC","action""#))))
        m.onEvent(event(held("h2", use)))
        #expect(try request(m, "h1").held == .unshown)
        #expect(try request(m, "h2").held?.approvable == true)
    }

    @Test func aListedApprovalThatDiffersFromItsEventIsDenyOnly() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody())))
        listed(held("h1", runBody()), held("h2", runBody(#"["git","push","--force"]"#)))
        try await m.refreshApprovals()
        #expect(try isRun(request(m, "h1")), "the same: still read")
        #expect(try request(m, "h2").held == .unshown, "another argv: deny only")
        // A lock forgets it with the lists.
        m.forgetOpenVault()
        m.onEvent(event(held("h2", runBody())))
        #expect(try isRun(request(m, "h2")))
    }

    /// A lenient reading is never the strict one: a catalog or a reveal with a duplicate member is never approvable.
    @Test func aCatalogOrRevealWithADuplicateIsNeverApprovable() async throws {
        let m = manager()
        let cat = #"{"op":"catalog","op":"catalog"}"#, get = #"{"op":"item.get","item_id":"i1","item_id":"i1"}"#
        m.onEvent(event(held("h3", cat)))
        m.onEvent(event(held("h4", get)))
        #expect(try request(m, "h3").held == .unshown)
        #expect(try request(m, "h4").held == .unshown)
        // As a non-strict list page, also over a strict event kept before.
        let m2 = manager()
        m2.onEvent(event(held("h5", #"{"op":"catalog"}"#)))
        #expect(try request(m2, "h5").held == .catalog)
        ops.pendingRaw = #"{"asks":[{"kind":"approval","body":\#(held("h5", cat))},{"kind":"approval","body":\#(held("h6", get))}]}"#
        try await m2.refreshApprovals()
        #expect(try request(m2, "h5").held == .unshown)
        #expect(try request(m2, "h6").held == .unshown)
    }

    @Test func aReferralKeepsAStoredEventThatDoesNotParse() throws {
        let m = manager()
        m.stored.append(.init(type: "approval.pending", body: "{}", at: now, ts: nil))
        m.onEvent(event(held("h1", runBody())))
        #expect(m.stored.count == 2, "nil is not a key to match")
    }

    @Test func aListedApprovalWithADuplicateIsDenyOnly() async throws {
        let m = manager()
        let dup = held("h1", runBody().replacingOccurrences(of: #""how":"env""#, with: #""how":"stdin","how":"env""#))
        let other = #"{"connection_id":"c1","request_id":"a1","context":"Sign in","exp":"\#(exp)"}"#
        ops.pendingRaw = #"{"asks":[{"kind":"approval","body":\#(dup)},{"kind":"authenticate","body":\#(other)}]}"#
        try await m.refreshApprovals()
        #expect(try request(m, "h1").held == .unshown)
        #expect(keys(m).contains("auth:a1"), "the other kinds still read")
    }

    @Test func aListedUseOrRevealTheSameAsItsEventStaysApprovable() async throws {
        let m = manager()
        let get = held("h2", #"{"op":"item.get","item_id":"i1","fields":["f1"]}"#, top: #","flags":["history"]"#)
        m.onEvent(event(held("h1", use)))
        m.onEvent(event(get))
        listed(held("h1", use), get)
        try await m.refreshApprovals()
        #expect(try request(m, "h1").held?.approvable == true)
        #expect(try request(m, "h2").held?.approvable == true)
    }

    @Test func aRunReferredAgainReplacesTheOneItNamesForGood() async throws {
        let m = manager()
        var read: [String] = []
        m.onDecided = { _, ref in read.append(ref) }
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1","flags":["program_unrecorded"]"#)))
        #expect(keys(m) == ["device:approval.pending:h2"])
        guard case .itemRun(let run)? = try request(m, "h2").held else { throw CocoaError(.fileNoSuchFile) }
        #expect(run.replaces == "h1" && read == ["h1"], "its feed item is read")
        // A late copy of the old one does not bring it back.
        m.onEvent(event(held("h1", runBody())))
        #expect(keys(m) == ["device:approval.pending:h2"] && stored(m, "h1").isEmpty, "not kept either")
        // Nor does a list that still has it, while the new one replaces it there too.
        listed(held("h1", runBody()), held("h3", runBody(), top: #","replaces":"h2""#))
        try await m.refreshApprovals()
        #expect(keys(m) == ["device:approval.pending:h3"] && stored(m, "h1").isEmpty && stored(m, "h2").isEmpty, "nor kept")
    }

    @Test func aReplacedApprovalCannotBeDecidedFromALateCopy() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1""#)))
        m.onEvent(event(held("h1", runBody())))
        await #expect(throws: VaultFailure.self) { try await m.declineDeviceRequest("device:approval.pending:h1") }
        #expect(ops.calls.isEmpty, "nothing sent for it")
    }

    @Test func aListedApprovalReferredAgainReplacesOneTheListStillHas() async throws {
        let m = manager()
        listed(held("h1", runBody()), held("h2", runBody(), top: #","replaces":"h1""#))
        try await m.refreshApprovals()
        #expect(keys(m) == ["device:approval.pending:h2"])
    }

    @Test func aDenyOnlyReferralStillReplacesTheOneItNames() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1","flags":["a_later_flag"]"#)))
        #expect(keys(m) == ["device:approval.pending:h2"])
        #expect(try request(m, "h2").held == .unshown)
        // Also one that does not read strictly at all: its `replaces` and `op` are taken from the lenient reading.
        m.onEvent(event(held("h3", runBody(), top: #","replaces":"h2","replaces":"h2""#)))
        #expect(keys(m) == ["device:approval.pending:h3"])
        #expect(try request(m, "h3").held == .unshown)
    }

    @Test func aListThatStillHasAReplacedApprovalDoesNotBringItBack() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1""#)))
        listed(held("h1", runBody()), held("h2", runBody(), top: #","replaces":"h1""#))
        try await m.refreshApprovals()
        #expect(keys(m) == ["device:approval.pending:h2"])
        await #expect(throws: VaultFailure.self) { try await m.declineDeviceRequest("device:approval.pending:h1") }
    }

    @Test func aListedApprovalWithAnotherNameOrDeviceIsDenyOnly() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody())))
        listed(held("h1", runBody(), name: "Other bot"), held("h2", runBody(), device: "B"))
        try await m.refreshApprovals()
        #expect(try request(m, "h1").held == .unshown)
        #expect(try request(m, "h2").held == .unshown)
    }

    @Test func aListedApprovalWithAnotherReplacesOrFlagsIsDenyOnly() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody(), top: #","flags":["shell"]"#)))
        listed(held("h1", runBody(), top: #","replaces":"h0""#), held("h2", runBody(), top: #","flags":["shell","inline_code"]"#))
        try await m.refreshApprovals()
        #expect(try request(m, "h1").held == .unshown)
        #expect(try request(m, "h2").held == .unshown)
    }

    @Test func aReplayAfterAReferralDoesNotBringBackTheOldApproval() async throws {
        let m = manager()
        listed(held("h1", runBody()))
        try await m.refreshApprovals()
        // Newer than the list, so it is taken in (one not later is already reflected by the list).
        m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1""#), ts: now.addingTimeInterval(1)))
        #expect(keys(m) == ["device:approval.pending:h2"])
        // A read that lists both: the merge reports only what stays.
        var merged: Set<String> = []
        m.onOpenAsksRead = { if case .merged(let keys, _) = $0 { merged = keys } }
        listed(held("h1", runBody()), held("h2", runBody(), top: #","replaces":"h1""#))
        ops.pendingTs = now.addingTimeInterval(2)
        try await m.refreshApprovals()
        #expect(merged == ["device:approval.pending:h2"] && keys(m) == ["device:approval.pending:h2"])
    }

    @Test func aReplacesOnARevealRemovesNothing() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", #"{"op":"item.get","item_id":"i1"}"#, top: #","replaces":"h1""#)))
        #expect(keys(m) == ["device:approval.pending:h1", "device:approval.pending:h2"])
        #expect(try request(m, "h2").held == .unshown)
    }

    // MARK: - The check of one approval against another is by bytes, both ways, and a lock forgets it

    /// "é" as one code point (NFC) and as "e" and a combining acute (NFD): the same to `String ==`, never the same bytes.
    let nfc = "caf\u{00E9}", nfd = "cafe\u{0301}"

    @Test func theHeldRequestsAreComparedAsBytesNotAsCanonicallyEquivalentText() throws {
        #expect(nfc == nfd, "the premise: Swift's String == takes them as one")
        func run(_ arg: String) throws -> HeldApproval {
            let o = try StrictJson.parseObject(Array(held("h1", runBody("[\"git\",\"\(arg)\"]")).utf8))
            return try #require(ApprovalParser.device("approval.pending", o, at: now)?.held)
        }
        #expect(try run(nfc) == run(nfc))
        #expect(try run(nfc) != run(nfd))
        #expect(try run(nfd) == run(nfd))
        let get = { (f: String) in HeldApproval.itemGet(itemID: "i1", fieldIDs: [f]) }
        #expect(get(nfc) != get(nfd))
        #expect(HeldApproval.itemUse(itemID: nfc, fieldID: "f", data: [1]) != HeldApproval.itemUse(itemID: nfd, fieldID: "f", data: [1]))
        let proxy = { (h: String) in HeldApproval.itemProxy(ItemProxy(itemID: "i", fieldID: "f", host: h, header: "A", prefix: "", seconds: 60, replaces: nil)) }
        #expect(proxy(nfc) != proxy(nfd) && proxy(nfc) == proxy(nfc))
        // The device request too: its name, role, device and `replaces`.
        let a = DeviceRequest(type: "approval.pending", id: "h1", deviceName: nfc, role: "agent", receivedAt: now)
        var b = a
        b.deviceName = nfd
        #expect(a != b && !a.asksSame(as: b))
        let x = DeviceRequest(type: "approval.pending", id: "h1", receivedAt: now, deviceID: nfc)
        let y = DeviceRequest(type: "approval.pending", id: "h1", receivedAt: now, deviceID: nfd)
        #expect(a.asksSame(as: a) && !x.asksSame(as: y) && x.asksSame(as: x))
    }

    @Test func aListedApprovalThatDiffersOnlyByCanonicalEquivalenceIsDenyOnly() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody("[\"git\",\"\(nfc)\"]"))))
        m.onEvent(event(held("h2", runBody(), name: nfc)))
        m.onEvent(event(held("h3", runBody("[\"git\",\"\(nfc)\"]"))))
        listed(held("h1", runBody("[\"git\",\"\(nfd)\"]")), held("h2", runBody(), name: nfd), held("h3", runBody("[\"git\",\"\(nfc)\"]")))
        try await m.refreshApprovals()
        #expect(try request(m, "h1").held == .unshown, "another argument as bytes")
        #expect(try request(m, "h2").held == .unshown, "another name as bytes")
        #expect(try isRun(request(m, "h3")), "the same bytes: still read")
    }

    @Test func anApprovalThatArrivesAfterOneWithTheSameIdAndOtherContentIsDenyOnly() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", runBody())))
        m.onEvent(event(held("h3", use)))
        #expect(try isRun(request(m, "h1")))
        // The same text again (a replay, a repeat): still read.
        m.onEvent(event(held("h1", runBody())))
        #expect(try isRun(request(m, "h1")))
        // Another argument, another device, another name, another kind: never taken as the old one.
        m.onEvent(event(held("h1", runBody(#"["git","push","--force"]"#))))
        m.onEvent(event(held("h2", runBody(), device: "B")))
        m.onEvent(event(held("h3", #"{"op":"item.use","item_id":"i1","field_id":"f1","action":"hmac-sha256","data":"AAED"}"#)))
        #expect(try request(m, "h1").held == .unshown)
        #expect(try request(m, "h2").held == .unshown)
        #expect(try request(m, "h3").held == .unshown)
        #expect(m.mismatched == ["device:approval.pending:h1", "device:approval.pending:h2", "device:approval.pending:h3"])
        // And by bytes: only the spelling differs.
        m.onEvent(event(held("h4", runBody("[\"git\",\"\(nfc)\"]"))))
        m.onEvent(event(held("h4", runBody("[\"git\",\"\(nfd)\"]"))))
        #expect(try request(m, "h4").held == .unshown)
    }

    @Test func aLockForgetsWhatWasMarkedDifferentAndWhatWasReplaced() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h1", runBody(#"["git","push"]"#))))
        m.onEvent(event(held("h2", runBody())))
        m.onEvent(event(held("h3", runBody(), top: #","replaces":"h2""#)))
        #expect(m.mismatched == ["device:approval.pending:h1"] && m.replaced == ["device:approval.pending:h2"])
        #expect(keys(m) == ["device:approval.pending:h1", "device:approval.pending:h3"])
        m.forgetOpenVault()
        #expect(m.mismatched.isEmpty && m.replaced.isEmpty && keys(m).isEmpty)
        // After the lock the vault's list is read again: h1 is what the vault holds now (read, not deny only), and a late copy
        // of the old h2 is not held back by a mark from before the lock.
        listed(held("h1", runBody(#"["git","push"]"#)), held("h2", runBody()))
        try await m.refreshApprovals()
        #expect(try isRun(request(m, "h1")) && isRun(request(m, "h2")))
        #expect(m.mismatched.isEmpty && m.replaced.isEmpty)
    }

    // MARK: - Approving: what is looked up, and what is checked again

    /// A run and a proxy, otherwise fully valid and nameable, are read but deny only until their screens ship: the manager
    /// refuses them on its own, whatever the screen offers, and calls neither the vault nor the item's settings.
    @Test func aRunAndAProxyAreRefusedWithoutCallingTheVault() async throws {
        var asked = 0
        let m = manager(cwd: { _, _ in asked += 1; return true })
        let withCwd = runBody().replacingOccurrences(of: #""how":"env""#, with: #""cwd":"/home/me","how":"env""#)
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", #"{"op":"item.proxy","item_id":"i1","field_id":"f1","host":"api.example.com","seconds":3600}"#, top: #","proxy":{"host":"api.example.com","header":"Authorization","prefix":"Bearer "}"#)))
        m.onEvent(event(held("h3", withCwd)))
        for id in ["h1", "h2", "h3"] {
            #expect(try request(m, id).held?.approvable == false && request(m, id).held != .unshown, "read, not approvable")
            do {
                _ = try await m.approveDeviceRequest("device:approval.pending:\(id)")
                Issue.record("\(id) was approved")
            } catch let f as VaultFailure {
                #expect(f.kind == .notSupported, Comment(rawValue: id))
            }
        }
        #expect(ops.calls.isEmpty && asked == 0, "nothing sent, no settings read")
        #expect(keys(m).count == 3, "they stay, to be denied")
    }

    @Test func anItemUseOrRevealIsApprovedWithApprovalDecide() async throws {
        let m = manager()
        m.onEvent(event(held("h1", use)))
        m.onEvent(event(held("h2", #"{"op":"item.get","item_id":"i1","fields":["f1"]}"#)))
        _ = try await m.approveDeviceRequest("device:approval.pending:h1")
        _ = try await m.approveDeviceRequest("device:approval.pending:h2")
        #expect(ops.calls == ["approvalDecide:h1:true", "approvalDecide:h2:true"] && keys(m).isEmpty, "decided: they leave")
    }

    @Test func anItemOrAFieldTheListCannotNameIsNotApproved() async throws {
        let m = manager()
        for (id, body) in [
            ("h1", use.replacingOccurrences(of: #""item_id":"i1""#, with: #""item_id":"i9""#)),
            ("h2", #"{"op":"item.get","item_id":"i9"}"#),
            ("h3", use.replacingOccurrences(of: #""field_id":"f1""#, with: #""field_id":"f9""#)),
            ("h4", #"{"op":"item.get","item_id":"i1","fields":["f1","f9"]}"#),
        ] {
            m.onEvent(event(held(id, body)))
            await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest("device:approval.pending:\(id)") }
        }
        let empty = manager(cache: [])
        empty.onEvent(event(held("h1", use)))
        await #expect(throws: VaultFailure.self) { try await empty.approveDeviceRequest("device:approval.pending:h1") }
        // An item whose name is nothing once cleaned is not named either.
        let blank = manager(cache: [ItemSummary(itemID: "i1", version: 1, name: "\u{200B}", category: "x", sensitivity: .secret, fieldLabels: Self.cache[0].fieldLabels)])
        blank.onEvent(event(held("h1", use)))
        await #expect(throws: VaultFailure.self) { try await blank.approveDeviceRequest("device:approval.pending:h1") }
        #expect(ops.calls.isEmpty)
    }

    @Test func anApprovalThatIsDenyOnlyOrDifferingOrReplacedOrGoneIsNeverApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h1", runBody(#"["git","push"]"#))))
        m.onEvent(event(held("h2", runBody(), top: #","flags":["a_later_flag"]"#)))
        m.onEvent(event(held("h3", runBody())))
        m.onEvent(event(held("h4", runBody(), top: #","replaces":"h3""#)))
        let gone = held("h6", runBody()).replacingOccurrences(of: exp, with: Timestamps.formatMillis(now.addingTimeInterval(-1)))
        m.onEvent(event(gone))
        for (id, kind) in [("h1", FailureKind.notSupported), ("h2", .notSupported), ("h3", .notFound), ("h6", .notFound), ("h9", .notFound)] {
            do {
                _ = try await m.approveDeviceRequest("device:approval.pending:\(id)")
                Issue.record("\(id) was approved")
            } catch let f as VaultFailure {
                #expect(f.kind == kind, Comment(rawValue: id))
            }
        }
        #expect(ops.calls.isEmpty, "nothing sent")
    }

    @Test func aDesktopsStepUpAndAnOtherOpAreNotApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", #"{"op":"item.put"}"#)))
        m.onEvent(event(held("h2", #"{"op":"catalog"}"#).replacingOccurrences(of: #""role":"agent""#, with: #""role":"desktop""#)))
        for id in ["h1", "h2"] {
            await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest("device:approval.pending:\(id)") }
        }
        #expect(ops.calls.isEmpty)
    }

    @Test func aSessionRequestIsNotApprovedHere() async throws {
        let m = manager()
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "device.session.pending", ts: now, body: Array(#"{"request_id":"s1","device_id":"A","role":"agent","name":"Bot","seconds":900,"exp":"\#(exp)"}"#.utf8))))
        await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest("device:device.session.pending:s1") }
        #expect(ops.calls.isEmpty)
    }

    /// The settings are read while approving: what changed during that read (the same approval, asked otherwise) is not approved.
    @Test func approvalDecideAnswersAreHanded() async throws {
        ops.decideResult = "referred"
        let m = manager()
        m.onEvent(event(held("h1", use)))
        let d = try await m.approveDeviceRequest("device:approval.pending:h1")
        #expect(d.result == "referred")
        // `not_found` from the vault: the approval leaves, the failure is thrown.
        m.onEvent(event(held("h2", use)))
        ops.errors["approvalDecide"] = FakeApprovalOps.error("not_found")
        await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest("device:approval.pending:h2") }
        #expect(keys(m).isEmpty)
    }

    /// Whatever the store still holds, a replaced approval is not shown (defence in depth: the store drops it as well).
    @Test func aReplacedApprovalIsNeverShown() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.replaced.insert("device:approval.pending:h1")
        #expect(m.stored.count == 1 && keys(m).isEmpty)
        m.forgetOpenVault()
        #expect(m.replaced.isEmpty && m.mismatched.isEmpty, "dropped with the lists")
    }

    @Test func aReferralWithTheOwnIdReplacesNothing() throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody(), top: #","replaces":"h1""#)))
        #expect(keys(m) == ["device:approval.pending:h1"])
    }
}

// swiftlint:enable line_length
