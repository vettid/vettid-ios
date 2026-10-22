import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``ApprovalsManager``, answered from fixtures; every call recorded.
final class FakeApprovalOps: ApprovalOps, @unchecked Sendable {
    var calls: [String] = []
    var errors: [String: VaultOpError] = [:]
    var grants = #"{"pending":[]}"#
    var critical = #"{"incoming":[]}"#
    var criticalBody = "{}"
    var listsFail = false
    var getGate: TestDeferred<Void>?
    /// The pages `share.pending.list` and `share.rule.list` answer, in order; none: `unsupported_type`. Their calls are in
    /// ``shareCalls``, not in ``calls``.
    var pendingPages: [String] = []
    var rulePages: [String] = []
    var shareCalls: [String] = []
    /// What `share.decide` answers.
    var shareAnswer = "{}"
    /// When set, `share.pending.list` waits for it once it has its page (a read on its way).
    var pendingGate: TestDeferred<Void>?

    private func call(_ name: String) throws {
        calls.append(name)
        if let e = errors.removeValue(forKey: name.components(separatedBy: ":")[0]) { throw e }
    }

    static func error(_ code: String) -> VaultOpError { VaultOpError(type: "x", code: code, detail: "", body: nil) }

    func authenticateApprove(_ requestID: String) async throws { try call("authApprove:\(requestID)") }
    func authenticateDeny(_ requestID: String) async throws { try call("authDeny:\(requestID)") }
    func grantList() async throws -> JsonObject {
        try call("grantList")
        if listsFail { throw Self.error("unsupported_type") }
        return try StrictJson.parseObject(grants)
    }
    func grantDecide(_ requestID: String, approve: Bool, choice: GrantChoice) async throws -> JsonObject {
        try call("grantDecide:\(requestID):\(approve):\(choice.items ?? []):\(choice.answers?.map(\.itemID) ?? [])")
        return try StrictJson.parseObject(#"{"grants":[]}"#)
    }
    func criticalUseList() async throws -> JsonObject {
        try call("criticalList")
        return try StrictJson.parseObject(critical)
    }
    func criticalUseGet(_ requestID: String) async throws -> JsonObject {
        try call("criticalGet:\(requestID)")
        if let g = getGate { try await g.value() }
        return try StrictJson.parseObject(criticalBody)
    }
    func criticalUseApprove(_ requestID: String, password: String, payloadSha256: [UInt8]) async throws -> String? {
        try call("criticalApprove:\(requestID):\(Base64s.encodeStd(payloadSha256))")
        return "ok"
    }
    func criticalUseDeny(_ requestID: String) async throws { try call("criticalDeny:\(requestID)") }
    func shareDecide(_ ruleID: String, include: [String], decline: [String]) async throws -> JsonObject {
        try call("shareBoth:\(ruleID):\(include):\(decline)")
        return try StrictJson.parseObject(shareAnswer)
    }
    func shareDecide(_ ruleID: String, items: [String], approve: Bool) async throws -> JsonObject {
        try call("shareOne:\(ruleID):\(items):\(approve)")
        return try StrictJson.parseObject(shareAnswer)
    }
    func sharePendingPage(after: String?, limit: Int?) async throws -> JsonObject {
        shareCalls.append("pending:\(after ?? "nil"):\(limit ?? 0)")
        guard !pendingPages.isEmpty else { throw Self.error("unsupported_type") }
        let page = pendingPages.removeFirst()
        if let g = pendingGate { try await g.value() }
        return try StrictJson.parseObject(page)
    }
    func shareRulePage(after: String?) async throws -> JsonObject {
        shareCalls.append("rules:\(after ?? "nil")")
        guard !rulePages.isEmpty else { throw Self.error("unsupported_type") }
        return try StrictJson.parseObject(rulePages.removeFirst())
    }
    func sessionDeny(_ requestID: String) async throws { try call("sessionDeny:\(requestID)") }
    func approvalDecide(_ approvalID: String, approve: Bool) async throws -> String? {
        try call("approvalDecide:\(approvalID):\(approve)")
        return nil
    }
}

/// The approvals over their vault calls (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8; ANDROID-PLAN §4 Approvals): the
/// events kept in their file, the lists, each decision and its feed item, and the connection requests listed with them.
/// Mirrors the approval parts of vettid-android `SocialManager`'s tests and `ApprovalParserTest`.
@MainActor
@Suite struct ApprovalsManagerTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let file = MemoryFile()
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    static let payload = Base64s.encodeStd(Array("sign me".utf8))
    static let sha = Base64s.encodeStd(Bytes.sha256(Array("sign me".utf8)))

    func manager(unlocked: @escaping @MainActor (String) async throws -> Void = { _ in }) -> ApprovalsManager {
        let ops = ops, connOps = connOps, file = file, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        let m = ApprovalsManager(connections: c, ops: { ops }, openUnlockWindow: unlocked, load: { file.bytes }, persist: { file.bytes = $0.isEmpty ? nil : $0 }, now: { now })
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    var exp: String { Timestamps.formatMillis(now.addingTimeInterval(600)) }

    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    @Test func eventsAreParsedKeptAndDroppedWhenAnotherDeviceDecides() throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", #"{"request_id":"a1","connection_id":"c1","context":"Sign in","exp":"\#(exp)"}"#))
        m.onEvent(event("approval.pending", #"{"approval_id":"d1","name":"Laptop","role":"desktop","type":"item.reveal","exp":"\#(exp)"}"#))
        m.onEvent(event("device.session.pending", #"{"request_id":"s1","name":"Laptop","exp":"\#(exp)"}"#))
        m.onEvent(event("grant.pending", #"{"request_id":"g1","connection_id":"c1","items":[{"kind":"item","ref":"i1","label":"Passport","available":true,"name":"Passport","category":"identity","labels":[{"field_id":"f1","label":"Number","kind":"text"}]},{"kind":"category","ref":"insurance","available":false}],"uses":1,"expires_in":3600,"exp":"\#(exp)"}"#))
        m.onEvent(event("grant.pending", #"{"connection_id":"c1"}"#))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "device:approval.pending:d1", "device:device.session.pending:s1", "grant:g1"])
        guard case .grant(let g)? = m.approvals.first(where: { $0.key == "grant:g1" }) else { throw CocoaError(.featureUnsupported) }
        #expect(g.grantable == [0] && g.entries[0].labels?.first?.fieldID == "f1" && g.entries[1].labels == nil && g.uses == 1)

        // Kept in the file: a new manager reads them back.
        #expect(manager().approvals.count == 4)
        m.onEvent(event("sync.event", #"{"kind":"grant.request.decided","request_id":"g1","approved":true}"#))
        m.onEvent(event("sync.event", #"{"kind":"approval.decided","approval_id":"d1"}"#))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1"}"#))
        #expect(m.approvals.map(\.key) == ["device:device.session.pending:s1"])
        m.clear()
        #expect(m.approvals.isEmpty && file.bytes == nil)
    }

    @Test func shareQuestionsAddUpAndLeaveAsTheyAreDecided() throws {
        let m = manager()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1","name":"A","category":"other","sensitivity":"data"}]}"#))
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i2","name":"B","category":"other","sensitivity":"secret","ask_rule_id":"r0","shared":true}]}"#))
        guard case .share(let s)? = m.approvals.first else { throw CocoaError(.featureUnsupported) }
        #expect(s.items.map(\.itemID) == ["i1", "i2"] && s.items[1].askRuleID == "r0" && s.items[1].shared && s.subjectConnectionID == "c1")
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["i1"],"declined":[]}"#))
        guard case .share(let left)? = m.approvals.first else { throw CocoaError(.featureUnsupported) }
        #expect(left.items.map(\.itemID) == ["i2"])
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":[],"declined":["i2"]}"#))
        #expect(m.approvals.isEmpty)
    }

    @Test func theListsAreReadAndDropWhatTheyNoLongerHold() async throws {
        let m = manager()
        m.onEvent(event("grant.pending", #"{"request_id":"g-old","connection_id":"c1","items":[],"exp":"\#(exp)"}"#))
        m.onEvent(event("connection.authenticate.pending", #"{"request_id":"a1","connection_id":"c1","exp":"\#(Timestamps.formatMillis(now.addingTimeInterval(-1)))"}"#))
        ops.grants = #"{"pending":[{"request_id":"g2","connection_id":"c2","items":[{"kind":"item","ref":"i9","available":true}],"uses":2,"expires_in":60,"exp":"\#(exp)"}]}"#
        ops.critical = #"{"incoming":[{"request_id":"k1","connection_id":"c1","name":"Key","label":"Seed","operation":"sign","payload_sha256":"\#(Self.sha)","exp":"\#(exp)","kind":"password"}]}"#
        try await m.refreshApprovals()
        #expect(Set(m.approvals.map(\.key)) == ["grant:g2", "critical:k1"])
        #expect(connOps.calls.contains("requestList"), "the connection requests are read with them")
        guard case .critical(let c)? = m.approvals.first(where: { $0.key == "critical:k1" }) else { throw CocoaError(.featureUnsupported) }
        #expect(!c.payloadVerified && c.suitable == true, "a list entry has no payload")

        // An older vault without the lists: nothing dropped by them.
        m.onEvent(event("grant.pending", #"{"request_id":"g3","connection_id":"c1","items":[],"exp":"\#(exp)"}"#))
        ops.listsFail = true
        try await m.refreshApprovals()
        #expect(m.approvals.contains { $0.key == "grant:g3" })
    }

    @Test func aCriticalUseIsApprovedOnlyForAPayloadThatMatches() async throws {
        let m = manager()
        var read: [String] = []
        m.onDecided = { _, ref in read.append(ref) }
        ops.critical = #"{"incoming":[{"request_id":"k1","connection_id":"c1","name":"Key","label":"Seed","operation":"sign","payload_sha256":"\#(Self.sha)","exp":"\#(exp)"}]}"#
        try await m.refreshApprovals()
        #expect(await kind { try await m.approveCriticalUse("k1", password: "pw") } == .other, "no payload yet")
        ops.criticalBody = #"{"request_id":"k1","connection_id":"c1","name":"Key","label":"Seed","operation":"sign","payload":"\#(Base64s.encodeStd(Array("other".utf8)))","payload_sha256":"\#(Self.sha)","exp":"\#(exp)"}"#
        try await m.loadCriticalUse("k1")
        #expect(await kind { try await m.approveCriticalUse("k1", password: "pw") } == .other, "a payload that does not match")
        ops.criticalBody = #"{"request_id":"k1","connection_id":"c1","name":"Key","label":"Seed","operation":"sign","payload":"\#(Self.payload)","payload_sha256":"\#(Self.sha)","exp":"\#(exp)"}"#
        try await m.loadCriticalUse("k1")
        #expect(try await m.approveCriticalUse("k1", password: "pw") == "ok")
        #expect(ops.calls.last == "criticalApprove:k1:\(Self.sha)" && m.approvals.isEmpty && read == ["k1"])
    }

    @Test func decisionsAndTheirFeedItems() async throws {
        var unlocked: [String] = []
        let m = manager { unlocked.append($0) }
        var read: [String] = []
        m.onDecided = { kinds, ref in read.append("\(kinds.first ?? ""):\(ref)") }
        m.onEvent(event("connection.authenticate.pending", #"{"request_id":"a1","connection_id":"c1","exp":"\#(exp)"}"#))
        m.onEvent(event("grant.pending", #"{"request_id":"g1","connection_id":"c1","items":[{"kind":"item","ref":"i1","available":true},{"kind":"item","ref":"i2","available":false}],"exp":"\#(exp)"}"#))
        m.onEvent(event("grant.pending", #"{"request_id":"g2","connection_id":"c1","items":[{"kind":"category","ref":"insurance","available":false}],"exp":"\#(exp)"}"#))
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1"}]}"#))
        m.onEvent(event("device.session.pending", #"{"request_id":"s1","exp":"\#(exp)"}"#))

        try await m.approveAuthentication("a1", password: "pw")
        #expect(unlocked == ["pw"] && ops.calls == ["authApprove:a1"])
        try await m.decideGrant("g1", approve: true)
        #expect(ops.calls.last == "grantDecide:g1:true:[0]:[]")
        #expect(await kind { try await m.decideGrant("g2", approve: true) } == .notSupported, "a category needs an answer")
        try await m.decideGrant("g2", decision: GrantDecision(items: [0], answers: [0: "i7", 3: "ignored"], uses: 2))
        #expect(ops.calls.last == "grantDecide:g2:true:[0]:[\"i7\"]")
        ops.errors["shareBoth"] = FakeApprovalOps.error("bad_request")
        try await m.decideShare("r1", include: ["i1"], decline: [])
        #expect(ops.calls.suffix(2) == ["shareBoth:r1:[\"i1\"]:[]", "shareOne:r1:[\"i1\"]:true"], "a vault before 0.21.0")
        try await m.declineDeviceRequest("device:device.session.pending:s1")
        #expect(ops.calls.last == "sessionDeny:s1" && m.approvals.isEmpty)
        #expect(read == ["connection.authenticate.requested:a1", "grant.request:g1", "grant.request:g2", "share.pending:r1", "device.session.pending:s1"])
    }

    @Test func aRequestTheVaultNoLongerKnowsLeaves() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", #"{"request_id":"a1","connection_id":"c1","exp":"\#(exp)"}"#))
        ops.errors["authDeny"] = FakeApprovalOps.error("not_found")
        #expect(await kind { try await m.denyAuthentication("a1") } == .notFound)
        #expect(m.approvals.isEmpty)
        #expect(await kind { try await m.declineDeviceRequest("device:approval.pending:x") } == .notFound)
    }

    /// A list read before an ask arrived, or before one was decided, neither drops the one nor brings back the other
    /// (chosen; not in the spec).
    @Test func aListFromBeforeAChangeDoesNotUndoIt() async throws {
        let m = manager()
        m.onEvent(event("grant.pending", #"{"request_id":"g1","connection_id":"c1","items":[{"kind":"item","ref":"i1","available":true}],"exp":"\#(exp)"}"#))
        ops.grants = #"{"pending":[{"request_id":"g1","connection_id":"c1","items":[{"kind":"item","ref":"i1","available":true}],"exp":"\#(exp)"}]}"#
        let gate = TestDeferred<Void>()
        connOps.requestGate = gate
        let read = Task { try await m.refreshApprovals() }
        try await Task.sleep(for: .milliseconds(50))
        try await m.decideGrant("g1", approve: false)
        m.onEvent(event("grant.pending", #"{"request_id":"g2","connection_id":"c1","items":[],"exp":"\#(exp)"}"#))
        gate.complete(())
        try await read.value
        #expect(m.approvals.map(\.key) == ["grant:g2"])
    }

    /// A payload fetched before a wipe is not written to the file after it.
    @Test func aPayloadFromBeforeAWipeIsNotKept() async throws {
        let m = manager()
        ops.criticalBody = #"{"request_id":"k1","connection_id":"c1","payload":"\#(Self.payload)","payload_sha256":"\#(Self.sha)","exp":"\#(exp)"}"#
        let gate = TestDeferred<Void>()
        ops.getGate = gate
        let load = Task { try await m.loadCriticalUse("k1") }
        try await Task.sleep(for: .milliseconds(50))
        m.clear()
        gate.complete(())
        try await load.value
        #expect(m.approvals.isEmpty && file.bytes == nil)
    }

    /// `share.decide` falls back to the old form only for a request the new form would accept; one that is malformed in
    /// either form is never split.
    @Test func theShareFallbackNeverSplitsAMalformedRequest() async throws {
        let m = manager()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1"},{"item_id":"i2"}]}"#))
        #expect(await kind { try await m.decideShare("r1", include: ["i1"], decline: ["i1"]) } == .other)
        #expect(await kind { try await m.decideShare("r1", include: (0...500).map { "x\($0)" }, decline: []) } == .other)
        #expect(await kind { try await m.decideShare("r1", include: ["i1", "i1"], decline: []) } == .other)
        #expect(ops.calls.isEmpty, "nothing sent")
        ops.errors["shareBoth"] = FakeApprovalOps.error("unsupported_type")
        try await m.decideShare("r1", include: ["i1"], decline: ["i2"])
        #expect(ops.calls == ["shareBoth:r1:[\"i1\"]:[\"i2\"]", "shareOne:r1:[\"i1\"]:true", "shareOne:r1:[\"i2\"]:false"])
    }

    /// The connection requests are listed here and decided through the connections (IOS-PLAN §8 I2.3).
    @Test func connectionRequestsAreApprovals() async throws {
        let m = manager()
        var read: [String] = []
        m.onDecided = { _, ref in read.append(ref) }
        connOps.requests = #"{"incoming":[{"pending_id":"p1","sas":"123456","created_at":"\#(Timestamps.formatMillis(now))","exp":"\#(exp)","state":"pending"}],"outgoing":[]}"#
        try await m.refreshApprovals()
        #expect(m.approvals.map(\.key) == ["connection:p1"] && m.approvals.first?.needsDecision == true && m.requests.count == 1)
        try await m.approveConnection("p1")
        #expect(connOps.calls.contains("approve:p1") && read == ["p1"] && m.approvals.first?.needsDecision == false)
    }
}

// swiftlint:enable line_length
