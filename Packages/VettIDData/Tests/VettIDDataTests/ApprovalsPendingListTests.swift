import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// The asks that arrive only as events, read back with `pending.list` (VAULT-MESSAGING 0.70.0 §10.4.2): the read of every page,
/// the merge with what is kept, the vault's time against the events' (§8.4), `unsupported_type`, and what the screens are told.
@MainActor
@Suite struct ApprovalsPendingListTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    init() { ops.pendingSupported = true }

    func manager() -> ApprovalsManager {
        let ops = ops, connOps = connOps, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        return ApprovalsManager(connections: c, ops: { ops }, now: { now })
    }

    func event(_ type: String, _ body: String, ts: Date? = nil) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: ts ?? now, body: Array(body.utf8)))
    }

    var exp: String { Timestamps.formatMillis(now.addingTimeInterval(600)) }

    func auth(_ id: String) -> String { #"{"connection_id":"c1","request_id":"\#(id)","context":"Sign in","exp":"\#(exp)"}"# }
    func approval(_ id: String) -> String { #"{"approval_id":"\#(id)","device_id":"dev-\#(id)","role":"desktop","name":"Laptop","type":"item.reveal","body":{},"exp":"\#(exp)"}"# }
    func session(_ id: String, device: String) -> String { #"{"request_id":"\#(id)","device_id":"\#(device)","role":"desktop","name":"Laptop","seconds":3600,"exp":"\#(exp)"}"# }

    /// The vault holds [asks] (kind, body); its time is [ts] seconds from the events'.
    func listed(_ asks: [(String, String)], ts: TimeInterval = 0) {
        ops.pendingAsks = asks.map { (kind: $0.0, body: $0.1) }
        ops.pendingTs = now.addingTimeInterval(ts)
    }

    func later(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// The asks lost at a lock or a hold come back with the next read, as the vault sent them.
    @Test func asksAreRestoredAfterAForgetAndARefresh() async throws {
        let m = manager()
        let spaced = #"{ "request_id" : "a1", "connection_id": "c1", "exp": "\#(exp)" }"#
        listed([("authenticate", spaced), ("approval", approval("d1")), ("session", session("s1", device: "dev-9"))])
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        m.forgetOpenVault()
        #expect(m.approvals.isEmpty && m.mayHaveBeenDropped("auth:a1"))
        try await m.refreshApprovals()
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "device:approval.pending:d1", "device:device.session.pending:s1"])
        #expect(m.stored.first { $0.type == "connection.authenticate.pending" }?.body == spaced, "the body as received")
        #expect(!m.mayHaveBeenDropped("auth:a1") && !m.mayHaveBeenDropped("device:approval.pending:gone"))
        guard case .device(let d)? = m.approvals.first(where: { $0.key == "device:device.session.pending:s1" }) else { throw CocoaError(.featureUnsupported) }
        #expect(d.deviceID == "dev-9" && d.deviceName == "Laptop")
    }

    /// The list is authoritative for its kinds: an ask decided elsewhere is not in it and is gone; the other lists' kinds stay.
    @Test func anAskDecidedElsewhereIsGone() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        m.onEvent(event("connection.authenticate.pending", auth("a2")))
        m.onEvent(event("approval.pending", approval("d1")))
        m.onEvent(event("grant.pending", #"{"request_id":"g1","connection_id":"c1","items":[],"exp":"\#(exp)"}"#))
        listed([("authenticate", auth("a1"))])
        ops.grants = #"{"pending":[{"request_id":"g1","connection_id":"c1","items":[],"exp":"\#(exp)"}]}"#
        try await m.refreshApprovals()
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "grant:g1"])
        #expect(!m.mayHaveBeenDropped("auth:a2") && !m.mayHaveBeenDropped("device:approval.pending:d1"), "decided, not lost")
    }

    @Test func everyPageIsRead() async throws {
        let m = manager()
        ops.pendingPageSize = 2
        listed((1...5).map { ("authenticate", auth("a\($0)")) })
        try await m.refreshApprovals()
        #expect(ops.pendingCalls == ["nil", "2", "4"])
        #expect(Set(m.approvals.map(\.key)) == Set((1...5).map { "auth:a\($0)" }))
    }

    /// Events arrive in no order (§8.4): one as old as the list, or older, is ignored; a later one is applied; during the
    /// read as after it.
    @Test func eventsNoLaterThanTheListAreIgnored() async throws {
        let m = manager()
        listed([("authenticate", auth("a1"))], ts: 10)
        try await m.refreshApprovals()
        m.onEvent(event("connection.authenticate.pending", auth("a2"), ts: now))
        m.onEvent(event("approval.pending", approval("d1"), ts: later(10)))
        m.onEvent(event("device.session.pending", session("s1", device: "dev-1"), ts: later(9)))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1"], "decided or expired: the list does not hold them")
        m.onEvent(event("connection.authenticate.pending", auth("a3"), ts: later(11)))
        m.onEvent(event("approval.pending", approval("d2"), ts: later(12)))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "auth:a3", "device:approval.pending:d2"])
        // The other kinds are the lists' own, and not judged by the time.
        m.onEvent(event("grant.pending", #"{"request_id":"g1","connection_id":"c1","items":[],"exp":"\#(exp)"}"#, ts: now))
        #expect(m.approvals.contains { $0.key == "grant:g1" })
        // After a drop the first read sets the time again: events are applied until then.
        m.forgetOpenVault()
        m.onEvent(event("connection.authenticate.pending", auth("a4"), ts: now))
        #expect(m.approvals.map(\.key) == ["auth:a4"])
    }

    @Test func aClosingEventForAnAskNotHeldDoesNothing() async throws {
        let m = manager()
        listed([("authenticate", auth("a1")), ("session", session("s1", device: "dev-1"))])
        try await m.refreshApprovals()
        let before = m.approvals.map(\.key).sorted()
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"zz","approved":true}"#))
        m.onEvent(event("sync.event", #"{"kind":"approval.decided","approval_id":"zz","approved":false}"#))
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-other","expires_at":"\#(exp)"}"#))
        #expect(m.approvals.map(\.key).sorted() == before)
    }

    /// A device has one session request; `sync.event` `device.session` closes it, by `device_id`, whether granted or ended.
    @Test func aSessionIsClosedByItsDevice() async throws {
        let m = manager()
        m.onEvent(event("device.session.pending", session("s1", device: "dev-1")))
        m.onEvent(event("device.session.pending", session("s2", device: "dev-2")))
        m.onEvent(event("device.session.pending", session("s3", device: "dev-2")))
        #expect(Set(m.approvals.map(\.key)) == ["device:device.session.pending:s1", "device:device.session.pending:s3"], "a newer request of the device replaces the older")
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1","expires_at":"\#(exp)"}"#))
        #expect(m.approvals.map(\.key) == ["device:device.session.pending:s3"])
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-2"}"#))
        #expect(m.approvals.isEmpty)
    }

    /// An older vault: today's behaviour (nothing covered, nothing dropped, "No longer on this phone" stays), and the list
    /// is not asked for again until the next unlock; a passed owner check after a hold (which also drops everything) does
    /// not ask again.
    @Test func unsupportedKeepsTodaysBehaviourAndIsAskedAgainOnlyAfterAnUnlock() async throws {
        let m = manager()
        ops.pendingSupported = false
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        try await m.refreshApprovals()
        #expect(ops.pendingCalls.count == 1)
        #expect(m.approvals.map(\.key) == ["auth:a1"], "nothing dropped")
        try await m.refreshApprovals()
        #expect(ops.pendingCalls.count == 1, "not asked again")
        // A hold, then a passed check: the same vault, not asked.
        m.forgetOpenVault()
        #expect(m.mayHaveBeenDropped("auth:a1"))
        try await m.refreshApprovals()
        #expect(ops.pendingCalls.count == 1 && m.approvals.isEmpty && m.mayHaveBeenDropped("auth:a1"), "No longer on this phone stays")
        // The unlock: asked again, and now answered.
        m.forgetOpenVault()
        m.vaultOpened()
        ops.pendingSupported = true
        listed([("authenticate", auth("a1"))])
        try await m.refreshApprovals()
        #expect(ops.pendingCalls.count == 2 && m.approvals.map(\.key) == ["auth:a1"])
    }

    /// Any other failure covers nothing, keeps what is known, and is tried again at the next refresh.
    @Test func otherFailuresCoverNothingAndAreTriedAgain() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        for code in ["owner_check_required", "retry"] {
            ops.pendingError = FakeApprovalOps.error(code)
            try await m.refreshApprovals()
            #expect(m.approvals.map(\.key) == ["auth:a1"])
        }
        m.forgetOpenVault()
        try await m.refreshApprovals()
        #expect(m.mayHaveBeenDropped("auth:a1"), "not answered")
        ops.pendingError = nil
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        listed([])
        try await m.refreshApprovals()
        #expect(ops.pendingCalls.count == 4 && m.approvals.isEmpty, "tried at every refresh, then answered")
    }

    /// A page that fails after the first does not leave the time behind: events are applied until a read is through.
    @Test func aReadThatFailsHalfwayIsNotAnAnswer() async throws {
        let m = manager()
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        while ops.pendingCalls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        gate.fail(FakeApprovalOps.error("retry"))
        try await read.value
        #expect(m.pendingListTs == nil && m.mayHaveBeenDropped("auth:a1"))
        m.onEvent(event("connection.authenticate.pending", auth("a9"), ts: now))
        #expect(m.approvals.map(\.key) == ["auth:a9"])
    }

    /// An ask that arrives during the read is not lost, a decision during it is not undone, and an event as old as the
    /// list's time is ignored during the read as after it.
    @Test func whatHappensDuringTheReadIsKept() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("approval", approval("d1")), ("authenticate", auth("a2"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        while ops.pendingCalls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        m.onEvent(event("connection.authenticate.pending", auth("new"), ts: later(20)))
        m.onEvent(event("connection.authenticate.pending", auth("old"), ts: later(5)))
        m.onEvent(event("sync.event", #"{"kind":"approval.decided","approval_id":"d1","approved":true}"#, ts: later(20)))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a2","approved":false}"#, ts: later(20)))
        gate.complete(())
        try await read.value
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "auth:new"])
    }

    @Test func aSessionClosedDuringTheReadIsNotBroughtBack() async throws {
        let m = manager()
        listed([("session", session("s1", device: "dev-1"))])
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await m.refreshApprovals() }
        while ops.pendingCalls.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(5)))
        gate.complete(())
        try await read.value
        #expect(m.approvals.isEmpty)
    }

    /// `action` and `location` asks have no screen on this phone: their entries are skipped, whatever they hold, and the
    /// read does not fail.
    @Test func actionAndLocationEntriesAreSkipped() async throws {
        let m = manager()
        listed([
            ("action", #"{"invocation_id":"i1","connection_id":"c1","action_id":"audit.recent","sensitivity":"low","params":{},"exp":"\#(exp)"}"#),
            ("location", #"{"request_id":"l1","connection_id":"c1","exp":"\#(exp)"}"#),
            ("future", #""text""#), ("authenticate", auth("a1")),
        ])
        try await m.refreshApprovals()
        #expect(m.approvals.map(\.key) == ["auth:a1"] && m.stored.count == 1)
        #expect(!m.mayHaveBeenDropped("auth:zz"))
    }

    /// An ask the vault lists that has expired by the phone's clock is not shown.
    @Test func anExpiredEntryIsNotKept() async throws {
        let m = manager()
        listed([("authenticate", #"{"request_id":"a1","connection_id":"c1","exp":"\#(Timestamps.formatMillis(now.addingTimeInterval(-1)))"}"#)])
        try await m.refreshApprovals()
        #expect(m.approvals.isEmpty && m.stored.isEmpty)
    }

    /// Waits until the fake has been called [count] times.
    func waitForCalls(_ count: Int) async throws {
        while ops.pendingCalls.count < count { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Closing events follow the time rule too (§10.4.2): one no later than the list, made for a device that has asked again
    /// since, does not end the newer request: after the merge, and during the read before its first page answered.
    @Test func aClosingEventNoLaterThanTheListDoesNotEndANewerRequest() async throws {
        let m = manager()
        listed([("session", session("r2", device: "dev-1")), ("authenticate", auth("a1"))], ts: 10)
        try await m.refreshApprovals()
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(5)))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":true}"#, ts: later(5)))
        #expect(Set(m.approvals.map(\.key)) == ["device:device.session.pending:r2", "auth:a1"])
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(11)))
        #expect(m.approvals.map(\.key) == ["auth:a1"], "a later close applies")

        // During a read, before the first page answered: the old close is no cut yet, but its time is older than the list's.
        let n = manager()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await n.refreshApprovals() }
        try await waitForCalls(2)
        n.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(5)))
        gate.complete(())
        try await read.value
        #expect(Set(n.approvals.map(\.key)) == ["device:device.session.pending:r2", "auth:a1"])
    }

    /// A decision made on this phone during the read is not undone by the list.
    @Test func aDecisionMadeHereDuringTheReadIsNotUndone() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        try await waitForCalls(2)
        try await m.denyAuthentication("a1")
        gate.complete(())
        try await read.value
        #expect(m.approvals.map(\.key) == ["auth:a2"])
    }

    /// Reads overlap: one that fails does not lower the cut a read on its way set, and an older list merged after a newer one
    /// does not remove what the newer one added.
    @Test func overlappingReadsKeepTheNewestCutAndTheNewestList() async throws {
        let m = manager()
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 10)
        let gateA = TestDeferred<Void>()
        ops.listGate = gateA
        ops.gateFrom = 1
        let a = Task { try await m.refreshApprovals() }
        try await waitForCalls(2)
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 20)
        let gateB = TestDeferred<Void>()
        ops.listGate = gateB
        let b = Task { try await m.refreshApprovals() }
        try await waitForCalls(4)
        gateA.fail(FakeApprovalOps.error("retry"))
        try await a.value
        #expect(m.pendingListTs == later(20), "the read that failed leaves the other's cut")
        m.onEvent(event("connection.authenticate.pending", auth("a9"), ts: later(15)))
        #expect(!m.approvals.contains { $0.key == "auth:a9" })
        gateB.complete(())
        try await b.value
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "auth:a2"])
        #expect(m.pendingListTs == later(20))

        // An older list that ends after a newer one is not merged.
        let n = manager()
        ops.pendingPageSize = 50
        ops.gateFrom = 0
        listed([("authenticate", auth("a1"))], ts: 10)
        let gateC = TestDeferred<Void>()
        ops.listGate = gateC
        ops.pendingCalls = []
        let c = Task { try await n.refreshApprovals() }
        try await waitForCalls(1)
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 20)
        let gateD = TestDeferred<Void>()
        ops.listGate = gateD
        let d = Task { try await n.refreshApprovals() }
        try await waitForCalls(2)
        gateD.complete(())
        try await d.value
        #expect(Set(n.approvals.map(\.key)) == ["auth:a1", "auth:a2"])
        gateC.complete(())
        try await c.value
        #expect(Set(n.approvals.map(\.key)) == ["auth:a1", "auth:a2"], "the older list did not remove a2")
    }

    /// A creation event ignored during a read that then fails is applied after all.
    @Test func eventsIgnoredDuringAReadThatFailsAreApplied() async throws {
        let m = manager()
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        try await waitForCalls(2)
        m.onEvent(event("connection.authenticate.pending", auth("a9"), ts: later(5)))
        #expect(m.approvals.isEmpty, "ignored while the read is on its way")
        gate.fail(FakeApprovalOps.error("retry"))
        try await read.value
        #expect(m.approvals.map(\.key) == ["auth:a9"])
    }

    /// A device has one session request: a listed one is not added beside a newer request that arrived during the read.
    @Test func aListedSessionDoesNotJoinANewerRequestOfTheSameDevice() async throws {
        let m = manager()
        ops.pendingPageSize = 1
        listed([("session", session("s2", device: "dev-1")), ("authenticate", auth("a1"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        try await waitForCalls(2)
        m.onEvent(event("device.session.pending", session("s3", device: "dev-1"), ts: later(20)))
        gate.complete(())
        try await read.value
        #expect(Set(m.approvals.map(\.key)) == ["device:device.session.pending:s3", "auth:a1"])
    }

    /// A backlog event processed before the first page answered, no later than the list, is for the list to judge: an ask the
    /// list does not hold is gone.
    @Test func aBacklogEventTheListDoesNotHoldIsGone() async throws {
        let m = manager()
        listed([("authenticate", auth("a1"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await m.refreshApprovals() }
        try await waitForCalls(1)
        m.onEvent(event("connection.authenticate.pending", auth("a5"), ts: now))
        m.onEvent(event("connection.authenticate.pending", auth("a6"), ts: later(30)))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a5", "auth:a6"])
        gate.complete(())
        try await read.value
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "auth:a6"], "a6 is later than the list")
    }

    /// A read on its way that then fails: [during] runs while it waits on its second page, and the read fails.
    func failingRead(on m: ApprovalsManager, during: () async throws -> Void) async throws {
        ops.pendingPageSize = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2"))], ts: 10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        ops.gateFrom = 1
        let read = Task { try await m.refreshApprovals() }
        try await waitForCalls(2)
        try await during()
        gate.fail(FakeApprovalOps.error("retry"))
        try await read.value
    }

    /// An ask created and decided during a read that fails stays gone: the replay of the creation sees the decision.
    @Test func anAskCreatedAndDecidedDuringAFailedReadStaysGone() async throws {
        let m = manager()
        try await failingRead(on: m) {
            m.onEvent(event("connection.authenticate.pending", auth("x"), ts: later(5)))
            m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"x","approved":true}"#, ts: later(6)))
        }
        #expect(m.approvals.isEmpty)
    }

    /// A held ask decided on another device during a read that fails is gone, though the read said nothing.
    @Test func aHeldAskDecidedDuringAFailedReadIsGone() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        try await failingRead(on: m) {
            m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":false}"#, ts: later(5)))
        }
        #expect(m.approvals.isEmpty)
    }

    /// A session request ignored during a read that fails does not replace the newer one of its device that was applied.
    @Test func aReplayedOlderSessionDoesNotReplaceANewerOne() async throws {
        let m = manager()
        try await failingRead(on: m) {
            m.onEvent(event("device.session.pending", session("r1", device: "dev-1"), ts: later(5)))
            m.onEvent(event("device.session.pending", session("r2", device: "dev-1"), ts: later(20)))
        }
        #expect(m.approvals.map(\.key) == ["device:device.session.pending:r2"])
        // Reordered outside any read: the older one that arrives last is dropped.
        let n = manager()
        n.onEvent(event("device.session.pending", session("r4", device: "dev-2"), ts: later(40)))
        n.onEvent(event("device.session.pending", session("r3", device: "dev-2"), ts: later(30)))
        #expect(n.approvals.map(\.key) == ["device:device.session.pending:r4"])
    }

    /// A decision made on this phone after the event was ignored is not undone by the replay.
    @Test func aReplayDoesNotBringBackWhatWasDecidedHere() async throws {
        let m = manager()
        try await failingRead(on: m) {
            m.onEvent(event("connection.authenticate.pending", auth("x"), ts: later(5)))
            try await m.denyAuthentication("x")
        }
        #expect(m.approvals.isEmpty)
    }

    /// A close that arrives before its creation (events come in no order, §8.4) is remembered: outside any read, in both
    /// orders, the ask is not shown; a decision made here is remembered too.
    @Test func aCloseBeforeTheCreationKeepsTheAskOut() async throws {
        let m = manager()
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":true}"#, ts: later(5)))
        m.onEvent(event("connection.authenticate.pending", auth("a1"), ts: later(4)))
        m.onEvent(event("sync.event", #"{"kind":"approval.decided","approval_id":"d1","approved":false}"#, ts: later(5)))
        m.onEvent(event("approval.pending", approval("d1"), ts: later(4)))
        #expect(m.approvals.isEmpty)
        // The other order.
        m.onEvent(event("connection.authenticate.pending", auth("a2"), ts: later(4)))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a2","approved":true}"#, ts: later(5)))
        #expect(m.approvals.isEmpty)
        try await m.denyAuthentication("a3")
        m.onEvent(event("connection.authenticate.pending", auth("a3"), ts: later(4)))
        #expect(m.approvals.isEmpty, "decided here")
        // A session request: refused when its device's close is at or after it, taken when it is later.
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(5)))
        m.onEvent(event("device.session.pending", session("s1", device: "dev-1"), ts: later(3)))
        m.onEvent(event("device.session.pending", session("s2", device: "dev-1"), ts: later(5)))
        #expect(m.approvals.isEmpty)
        m.onEvent(event("device.session.pending", session("s3", device: "dev-1"), ts: later(6)))
        #expect(m.approvals.map(\.key) == ["device:device.session.pending:s3"])
    }

    /// A merged list takes the closes it already judges.
    @Test func aMergedListPrunesTheClosesItJudges() async throws {
        let m = manager()
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":true}"#, ts: later(5)))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a2","approved":true}"#, ts: later(50)))
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"dev-1"}"#, ts: later(5)))
        try await m.denyAuthentication("a3")
        listed([], ts: 10)
        try await m.refreshApprovals()
        #expect(Set(m.closedAsks.map(\.key)) == ["auth:a2", "auth:a3"] && m.sessionClosedAt.isEmpty)
    }

    /// A list is merged only when complete: a `next` that repeats the cursor asked for leaves it partial, nothing is merged
    /// and the screen is told.
    @Test func aListThatNeverEndsIsNotMerged() async throws {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        ops.pendingPageSize = 1
        ops.pendingStuck = true
        listed([("authenticate", auth("a2")), ("authenticate", auth("a3")), ("authenticate", auth("a4"))], ts: 10)
        try await m.refreshApprovals()
        #expect(m.approvals.map(\.key) == ["auth:a1"] && m.openAsksError == .other && m.mayHaveBeenDropped("auth:zz"))
        #expect(m.pendingListTs == nil)
    }

    /// A stale cursor starts the listing again (§10.4.2): the read starts once more with a fresh first page; if that restarts
    /// too, the read fails.
    @Test func aStaleCursorRestartsTheReadOnceThenFails() async throws {
        let m = manager()
        ops.pendingPageSize = 1
        ops.pendingRestarts = 1
        listed([("authenticate", auth("a1")), ("authenticate", auth("a2")), ("authenticate", auth("a3"))], ts: 10)
        try await m.refreshApprovals()
        #expect(ops.pendingCalls == ["nil", "1", "nil", "1", "2"])
        #expect(Set(m.approvals.map(\.key)) == ["auth:a1", "auth:a2", "auth:a3"] && m.openAsksError == nil)

        let n = manager()
        n.onEvent(event("connection.authenticate.pending", auth("a9")))
        ops.pendingRestarts = 2
        try await n.refreshApprovals()
        #expect(n.approvals.map(\.key) == ["auth:a9"] && n.openAsksError == .other, "nothing merged")
    }

    /// Why the read failed is kept for the screen: a vault on hold is said to be, a failure is one; an answered read and a
    /// drop clear it.
    @Test func theFailureOfTheReadIsKeptUntilAnAnswerOrADrop() async throws {
        let m = manager()
        ops.pendingError = FakeApprovalOps.error("owner_check_required")
        try await m.refreshApprovals()
        #expect(m.openAsksError == .ownerCheckRequired)
        ops.pendingError = FakeApprovalOps.error("retry")
        try await m.refreshApprovals()
        #expect(m.openAsksError != nil && m.openAsksError != .ownerCheckRequired)
        ops.pendingError = nil
        try await m.refreshApprovals()
        #expect(m.openAsksError == nil)
        ops.pendingError = FakeApprovalOps.error("retry")
        try await m.refreshApprovals()
        m.forgetOpenVault()
        #expect(m.openAsksError == nil)
        // An older vault is not a failure.
        ops.pendingError = nil
        ops.pendingSupported = false
        try await m.refreshApprovals()
        #expect(m.openAsksError == nil)
    }
}

// swiftlint:enable line_length
