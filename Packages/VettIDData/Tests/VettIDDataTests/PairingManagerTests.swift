import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length file_length

private func obj(_ s: String) throws -> JsonObject { try StrictJson.parseObject(Array(s.utf8)) }

/// TEST ONLY. The clock's offset from virtual time: a moment that passes without the timers running (kotlinx `clock = ...` beside
/// `advanceTimeBy`).
final class Skew: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    var value: TimeInterval {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }
}

/// TEST ONLY. The manager a closure given to it must reach.
@MainActor
final class PairingBox {
    var manager: PairingManager?
}

/// TEST ONLY. A count the test's closures bump on the main actor.
@MainActor
final class ReadCounter {
    var n = 0
}

extension PairingManager {
    /// The screens' calls as one test screen (owner 0) makes them.
    func start(_ role: PairRole = .agent) async { await start(role, owner: 0) }

    func leave(token: Int) { leave(token: token, owner: 0) }

    func acknowledge(token: Int) { acknowledge(token: token, owner: 0) }

    /// The rejection of the comparison held now.
    func reject() async {
        var id = "none"
        if case .compare(let p) = state.stage { id = p.pairingID }
        await reject(pairingID: id)
    }

    /// The approval of the comparison held now (what a screen's sheet does for the comparison it was opened for).
    func approve(sessionSeconds: Int?) async {
        var id = "none"
        if case .compare(let p) = state.stage { id = p.pairingID }
        await approve(pairingID: id, sessionSeconds: sessionSeconds)
    }
}

/// TEST ONLY. `device.pair.*` as the vault answers them: the calls in order, the roles asked for, an answer per role, and gates that
/// hold the next create or approval until a test completes them.
@MainActor
final class FakePairingOps: PairingOps {
    var created: JsonObject
    var calls: [String] = []
    var roles: [String] = []
    var refuse: [String: String] = [:]
    /// Runs when an approval arrives, before it is answered; it may throw (an approval that got no answer).
    var onApprove: (@MainActor () throws -> Void)?
    var byRole: [String: JsonObject] = [:]
    var holdNext: TestDeferred<Void>?
    /// Completed when an agent create reached its gate.
    let held = TestDeferred<Void>()
    var holdApprove: TestDeferred<Void>?
    let approveEntered = TestDeferred<Void>()
    var holdReject: TestDeferred<Void>?
    let rejectEntered = TestDeferred<Void>()

    init(created: JsonObject) { self.created = created }

    private func refusal(_ key: String) -> VaultOpError? {
        refuse[key].map { VaultOpError(type: "device.pair.\(key)", code: $0, detail: "", body: nil) }
    }

    func create(role: PairRole) async throws -> JsonObject {
        roles.append(role.wire)
        calls.append("create")
        if let e = refusal("create") { throw e }
        if let gate = holdNext, role == .agent {
            holdNext = nil
            held.complete(())
            try await gate.value()
        }
        return byRole[role.wire] ?? created
    }

    func approve(pairingID: String, sessionSeconds: Int?) async throws {
        calls.append("approve:\(pairingID):\(sessionSeconds.map(String.init) ?? "nil")")
        if let gate = holdApprove {
            holdApprove = nil
            approveEntered.complete(())
            try await gate.value()
        }
        try onApprove?()
        if let e = refusal("approve") { throw e }
    }

    func reject(pairingID: String) async throws {
        calls.append("reject:\(pairingID)")
        if let gate = holdReject {
            holdReject = nil
            rejectEntered.complete(())
            try await gate.value()
        }
        if let e = refusal("reject") { throw e }
    }
}

/// Pairing an agent or a desktop (ANDROID-PLAN 0.1.53 AA2; "Pair a desktop", owner decision 2026-11-05, vettid-android #291;
/// VAULT-MESSAGING §6.7, §10.3). Mirrors vettid-android `PairingManagerTest`, on virtual time. (The test of the Approvals entry
/// that a left comparison closes is AA5's and is not here.)
@MainActor
@Suite(.serialized) struct PairingManagerTests {
    let time = VirtualTime()
    let skew = Skew()
    var t0: Date { time.now() }

    func now() -> Date { time.now().addingTimeInterval(skew.value) }

    func link(_ kind: InviteKind = .agent, exp: Date? = nil) throws -> String {
        let e = exp ?? time.now().addingTimeInterval(600)
        return try InviteQr(
            kind: kind, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: UInt64(e.timeIntervalSince1970)
        ).link()
    }

    func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    func created(_ id: String = "p1", _ kind: InviteKind = .agent, link bad: String? = nil, withExp: Bool = true) throws -> JsonObject {
        let l = try bad ?? link(kind)
        return try obj(#"{"pairing_id":"\#(id)","link":"\#(l)"\#(withExp ? #","exp":"\#(iso(time.now().addingTimeInterval(600)))""# : "")}"#)
    }

    func ops() throws -> FakePairingOps { FakePairingOps(created: try created()) }

    /// Answers per role: the agent's `pa` and the desktop's `pd`.
    func both(_ ops: FakePairingOps) throws {
        ops.byRole["agent"] = try created("pa", .agent)
        ops.byRole["desktop"] = try created("pd", .desktop)
    }

    /// A desktop's code is what `created` answers.
    func desktopOps() throws -> FakePairingOps { FakePairingOps(created: try created("p1", .desktop)) }

    func manager(
        _ ops: FakePairingOps, known: Set<String>? = ["me"], listed: [DeviceInfo] = [], paired: PairedCount? = nil
    ) -> PairingManager {
        let base = time.now
        return PairingManager(
            ops: { ops }, now: { [skew] in base().addingTimeInterval(skew.value) }, sleep: time.sleep,
            knownDeviceIDs: { known }, readDevices: { listed }, onPaired: { paired?.n += 1 }
        )
    }

    final class PairedCount {
        var n = 0
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: time.now(), body: Array(body.utf8)))
    }

    func pending(_ id: String = "p1", name: String = "Claude on laptop", sas: String = "123456", role: String = "agent") -> VaultMessage {
        event("device.pair.pending", #"{"pairing_id":"\#(id)","pending_id":"x","role":"\#(role)","name":"\#(name)","sas":"\#(sas)"}"#)
    }

    func paidFeed(_ deviceID: String, at: Date? = nil) -> VaultMessage {
        event("feed.event", #"{"item_id":"i","seq":1,"kind":"device.paired","at":"\#(iso(at ?? time.now()))","status":"unread","device_id":"\#(deviceID)"}"#)
    }

    func agent(_ id: String, _ name: String) -> DeviceInfo { DeviceInfo(id: id, kind: "agent", name: name) }

    func desktopDevice(_ id: String, _ name: String) -> DeviceInfo { DeviceInfo(id: id, kind: "desktop", name: name) }

    /// An approval whose id search runs on virtual time: the time moves on until it is done.
    func approve(_ m: PairingManager, _ seconds: Int? = 3600) async {
        let t = Task { await m.approve(sessionSeconds: seconds) }
        await time.advance(seconds: 11)
        await t.value
    }

    func code(_ m: PairingManager) -> PairingCode? {
        if case .code(let c) = m.state.stage { c } else { nil }
    }

    func compared(_ m: PairingManager) -> PendingPairing? {
        if case .compare(let p) = m.state.stage { p } else { nil }
    }

    func paired(_ m: PairingManager) -> (name: String, deviceID: String?)? {
        if case .paired(let n, let d) = m.state.stage { (n, d) } else { nil }
    }

    func held(_ m: PairingManager) -> String? {
        switch m.state.stage {
        case .code(let c): c.pairingID
        case .codeExpired(let id, _): id
        default: nil
        }
    }

    // MARK: The agent

    @Test func aCodeIsMadeForAnAgentOnly() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        let c = try #require(code(m))
        #expect(c.pairingID == "p1")
        #expect(ops.calls == ["create"])
        // The code never reaches a text form (a log, a crash report).
        #expect(!"\(c)".contains(c.link) && !String(reflecting: c).contains(c.link))
    }

    @Test func aLinkThatIsNotAnAgentPairingOrDoesNotReadIsNeverShown() async throws {
        let ops = try ops()
        let m = manager(ops)
        ops.created = try created("p1", .desktop)
        await m.start()
        #expect(m.state.stage == .idle)
        #expect(m.state.error == .other)
        ops.created = try created("p1", link: "not a link", withExp: false)
        await m.start()
        #expect(m.state.stage == .idle)
        ops.created = try obj(#"{"link":"\#(try link())"}"#)
        await m.start()
        #expect(m.state.stage == .idle)
    }

    @Test func theCodeNeverOutlivesTenMinutes() async throws {
        let ops = try ops()
        let far = t0.addingTimeInterval(86_400)
        ops.created = try obj(#"{"pairing_id":"p1","link":"\#(try link(exp: far))","exp":"\#(iso(far))"}"#)
        let m = manager(ops)
        await m.start()
        let c = try #require(code(m))
        #expect(c.exp <= t0.addingTimeInterval(11 * 60))
    }

    @Test func aFailedCodeSaysSoAndKeepsNothing() async throws {
        let ops = try ops()
        ops.refuse["create"] = "owner_check_required"
        let m = manager(ops)
        await m.start()
        #expect(m.state.stage == .idle)
        #expect(m.state.error == .ownerCheckRequired)
        #expect(!m.state.busy)
        // A second ask is made when the first failed.
        ops.refuse = [:]
        m.acknowledge()
        await m.start()
        #expect(code(m) != nil)
    }

    @Test func theCodeExpiresUnusedAndNothingIsPaired() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        let exp = t0.addingTimeInterval(600)
        await time.advance(seconds: 601)
        #expect(m.state.stage == .codeExpired(pairingID: "p1", exp: exp))
        // "New code" makes a new pairing.
        ops.created = try created("p2")
        m.acknowledge()
        await m.start()
        #expect(code(m)?.pairingID == "p2")
    }

    @Test func aLateAnswerIsTakenForAMinuteAfterTheCodeEndedAndStillNeedsTheComparison() async throws {
        let m = manager(try ops())
        await m.start()
        await time.advance(seconds: 601)
        m.onEvent(pending("other"))
        guard case .codeExpired = m.state.stage else { Issue.record("not expired"); return }
        m.onEvent(pending())
        #expect(compared(m)?.sas == "123456")

        let late = manager(try ops())
        await late.start()
        await time.advance(seconds: 601)
        skew.value = 61
        late.onEvent(pending())
        guard case .codeExpired = late.state.stage else { Issue.record("not expired"); return }
    }

    @Test func theAgentsAnswerShowsTheDigitsAndASanitisedName() async throws {
        let m = manager(try ops())
        await m.start()
        m.onEvent(pending(name: "  Red\\u202e  Team  ", sas: "123 456"))
        let p = try #require(compared(m))
        #expect(p.sas == "123456")
        #expect(p.name == "Red  Team")
        #expect(p.comparable)
        // The digits and the name never reach a text form.
        #expect(!"\(p)".contains("123456") && !String(reflecting: p).contains("Red") && !"\(m.state)".contains("Red"))
        var dumped = ""
        dump(m.state, to: &dumped)
        #expect(!dumped.contains("123456") && !dumped.contains("Red"))
    }

    @Test func anEventForAnotherPairingOrWithNoCodeHeldChangesNothing() async throws {
        let m = manager(try ops())
        // Nothing held (the process started again): nothing to compare.
        m.onEvent(pending())
        #expect(m.state.stage == .idle)
        await m.start()
        m.onEvent(pending("other"))
        #expect(code(m) != nil)
        // The second event for the same pairing does not replace the first.
        m.onEvent(pending(sas: "111111"))
        m.onEvent(pending(sas: "222222"))
        #expect(compared(m)?.sas == "111111")
    }

    @Test func aCodeThatIsNotSixDigitsOrNotAnAgentCanOnlyBeRejected() async throws {
        for (sas, role) in [("12345", "agent"), ("abcdef", "agent"), ("1234567", "agent"), ("123456", "desktop"), ("١٢٣٤٥٦", "agent")] {
            let ops = try ops()
            let m = manager(ops)
            await m.start()
            m.onEvent(pending(sas: sas, role: role))
            #expect(compared(m)?.comparable == false, "\(sas) \(role)")
            await approve(m)
            #expect(ops.calls == ["create"])
            await m.reject()
            #expect(ops.calls == ["create", "reject:p1"])
            #expect(m.state.stage == .rejected(told: true))
        }
    }

    @Test func approvingSendsTheSessionAndNeverGrants() async throws {
        let ops = try ops()
        let count = PairedCount()
        let m = manager(ops, paired: count)
        await m.start()
        m.onEvent(pending())
        // A device.paired item from before the approval is not this pairing's.
        m.onEvent(paidFeed("agent-9", at: t0.addingTimeInterval(-3_600)))
        await approve(m)
        #expect(ops.calls == ["create", "approve:p1:3600"])
        #expect(paired(m)?.name == "Claude on laptop")
        // The list is read again once it is paired.
        #expect(count.n == 1)
    }

    @Test func noAccessYetSendsNoSession() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await approve(m, nil)
        #expect(ops.calls.contains("approve:p1:nil"))
    }

    /// The vault takes 60 to 86,400 seconds (§10.3): anything else is not sent, and the comparison stays.
    @Test func aSessionOutsideTheVaultsBoundsIsNotSent() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await approve(m, 59)
        await approve(m, 86_401)
        await approve(m, -1)
        #expect(ops.calls == ["create"])
        #expect(compared(m) != nil)
        // The bounds themselves are taken.
        await approve(m, 60)
        #expect(ops.calls == ["create", "approve:p1:60"])
        let n = try self.ops()
        let other = manager(n)
        await other.start()
        other.onEvent(pending())
        await approve(other, 86_400)
        #expect(n.calls == ["create", "approve:p1:86400"])
    }

    /// A second tap while the approval is in flight is not a second approval.
    @Test func anApprovalInFlightIsNotSentTwice() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let gate = TestDeferred<Void>()
        ops.holdApprove = gate
        let first = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.approveEntered.isCompleted })
        #expect(m.state.busy)
        // The taps run as tasks, so that a guard that fails shows as a count of calls, never as a wait.
        let second = Task { await m.approve(sessionSeconds: 3600) }
        let rejecting = Task { await m.reject() }
        await time.runCurrent()
        #expect(ops.calls == ["create", "approve:p1:3600"])
        gate.complete(())
        await time.advance(seconds: 11)
        await first.value
        await second.value
        await rejecting.value
        #expect(ops.calls == ["create", "approve:p1:3600"])
        #expect(paired(m) != nil)
    }

    /// Two new devices announced while the approval ran: neither is taken for the new one, and the list opens instead.
    @Test func moreThanOneNewDeviceInTheFeedGivesNoId() async throws {
        let ops = try ops()
        let m = manager(ops, listed: [agent("new", "Claude on laptop")])
        ops.onApprove = {
            m.onEvent(self.paidFeed("agent-8"))
            m.onEvent(self.paidFeed("agent-9"))
        }
        await m.start()
        m.onEvent(pending())
        await approve(m)
        #expect(paired(m) != nil && paired(m)?.deviceID == nil)
    }

    @Test func theNewAgentsIdComesFromTheFeedItem() async throws {
        let ops = try ops()
        let m = manager(ops)
        // The vault's feed item for the new agent arrives while the approval is being answered.
        ops.onApprove = { m.onEvent(self.paidFeed("agent-9")) }
        await m.start()
        m.onEvent(pending())
        await approve(m)
        #expect(paired(m)?.deviceID == "agent-9")
    }

    @Test func withoutTheFeedItemTheListNamesTheOneNewAgentOrNone() async throws {
        let one = manager(try ops(), known: ["me", "me2"], listed: [agent("me2", "Other"), agent("new", "Claude on laptop")])
        await one.start()
        one.onEvent(pending())
        await approve(one)
        #expect(paired(one)?.deviceID == "new")

        // Two that fit: the list opens instead (no id).
        let two = manager(try ops(), listed: [agent("n1", "Claude on laptop"), agent("n2", "Claude on laptop")])
        await two.start()
        two.onEvent(pending())
        await approve(two)
        #expect(paired(two) != nil && paired(two)?.deviceID == nil)

        // The list was never read before the approval: nothing is "new" to it (no guess).
        let unknown = manager(try ops(), known: nil, listed: [agent("n1", "Claude on laptop")])
        await unknown.start()
        unknown.onEvent(pending())
        await approve(unknown)
        #expect(paired(unknown) != nil && paired(unknown)?.deviceID == nil)
    }

    @Test func aRefusedApprovalIsAnEndedPairingAndGrantsNothing() async throws {
        let ops = try ops()
        ops.refuse["approve"] = "not_found"
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.approve(sessionSeconds: 3600)
        #expect(m.state.stage == .ended)
        #expect(!m.state.unknownOutcome)
        // A second approval of an ended pairing is not sent.
        await m.approve(sessionSeconds: 3600)
        #expect(ops.calls == ["create", "approve:p1:3600"])
    }

    /// VAULT-MESSAGING 0.83.11 §11.14.10: `transfer_incomplete` to an approval that carries grants.
    @Test func transferIncompleteIsTheMoveNotFinishedTextAndNotTheUnlocks() async throws {
        let ops = try ops()
        ops.refuse["approve"] = "transfer_incomplete"
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.approve(sessionSeconds: 3600)
        #expect(m.state.stage == .ended)
        let kind = try #require(m.state.error)
        #expect(kind == .moveNotFinished)
        #expect(kind.message == "The move to this phone isn't finished. Use Finish the move on this phone, then try again.")
        #expect(kind.message != FailureKind.transferIncomplete.message)
    }

    @Test func anApprovalThatGotNoAnswerSaysTheOutcomeIsUnknown() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await approve(m)
        // Not asserted either way: nothing was confirmed, and the screen says so.
        #expect(m.state.stage == .ended)
        #expect(m.state.unknownOutcome)
        #expect(m.state.agentName == "Claude on laptop")
        #expect(!m.state.busy)
    }

    @Test func noConnectionAtAllIsAnUnknownOutcomeToo() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.notConnectedToInternet) }
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await approve(m)
        #expect(m.state.stage == .ended)
        #expect(m.state.unknownOutcome)
    }

    @Test func aScreenThatLeavesWhileTheApprovalIsInFlightDoesNotStrandThePairing() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let screen = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.calls.contains("approve:p1:3600") })
        screen.cancel()
        await time.advance(seconds: 11)
        await screen.value
        #expect(!m.state.busy)
        #expect(m.state.stage == .ended)
        // Nothing is left watching or busy: a new code can be made.
        ops.created = try created("p2")
        m.acknowledge()
        await m.start()
        #expect(code(m)?.pairingID == "p2")
    }

    @Test func cancellingAnExpiredCodeStillTellsTheVault() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        await time.advance(seconds: 601)
        await m.cancel()
        #expect(m.state.stage == .idle)
        #expect(ops.calls == ["create", "reject:p1"])
    }

    @Test func anUnansweredApprovalThatTheFeedItemConfirmsIsPaired() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        // The device.paired item arrives after the request gave up, within the wait.
        let late = Task { @MainActor [time] in
            try? await time.sleep(.seconds(3))
            m.onEvent(self.paidFeed("agent-9"))
        }
        await approve(m)
        await late.value
        #expect(m.state.stage == .paired(name: "Claude on laptop", deviceID: "agent-9"))
    }

    @Test func anUnansweredApprovalThatTheListConfirmsIsPaired() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let count = PairedCount()
        let m = manager(ops, listed: [agent("new", "Claude on laptop")], paired: count)
        await m.start()
        m.onEvent(pending())
        await approve(m)
        #expect(m.state.stage == .paired(name: "Claude on laptop", deviceID: "new"))
        #expect(count.n == 1)
    }

    @Test func aFeedItemOfADeviceListedBeforeOrFromBeforeTheApprovalIsNotTheNewAgent() async throws {
        let ops = try ops()
        let m = manager(ops, known: ["me", "old"])
        await m.start()
        m.onEvent(pending())
        ops.onApprove = {
            m.onEvent(self.paidFeed("old"))
            m.onEvent(self.paidFeed("stale", at: self.t0.addingTimeInterval(-86_400)))
        }
        await approve(m)
        #expect(paired(m) != nil && paired(m)?.deviceID == nil)
    }

}

extension PairingManagerTests {
    // MARK: The daily check, the end of the comparison, rejecting, cancelling and the lock

    @Test func aDueDailyCheckKeepsTheComparisonForAnotherTry() async throws {
        let ops = try ops()
        ops.refuse["approve"] = "owner_check_required"
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.approve(sessionSeconds: 3600)
        #expect(compared(m) != nil)
        #expect(m.state.error == .ownerCheckRequired)
        ops.refuse = [:]
        m.acknowledge(token: m.state.token)
        #expect(m.state.error == nil)
        await approve(m)
        #expect(paired(m) != nil)
    }

    @Test func theComparisonEndsAtTenMinutesAndCannotBeApprovedAfter() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        // The comparison's own timer starts waiting for its end first.
        await time.runCurrent()
        skew.value = 601
        // Even before the timer ran, an approval is refused locally.
        await approve(m)
        #expect(ops.calls == ["create"])
        #expect(compared(m) != nil, "the comparison is still there: only the timer ends it")
        skew.value = 0
        await time.advance(seconds: 601)
        #expect(m.state.stage == .ended)
    }

    @Test func rejectingTellsTheVaultAndAFailureOfThatIsSaid() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.reject()
        #expect(m.state.stage == .rejected(told: true))
        m.acknowledge()
        #expect(m.state.stage == .idle)

        let bad = try self.ops()
        bad.refuse["reject"] = "internal"
        let n = manager(bad)
        await n.start()
        n.onEvent(pending())
        await n.reject()
        // Nothing is paired either way; the screen says the vault could not be told.
        #expect(n.state.stage == .rejected(told: false))
    }

    @Test func cancellingRejectsAndHoldsNothing() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        await m.cancel()
        #expect(m.state.stage == .idle)
        #expect(ops.calls == ["create", "reject:p1"])
        // A comparison left is rejected too.
        await m.start()
        m.onEvent(pending())
        await m.cancel()
        #expect(m.state.stage == .idle)
        #expect(ops.calls.last == "reject:p1")
    }

    @Test func aLockDropsEverythingAndALateAnswerIsNotApplied() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        m.clear()
        #expect(m.state == PairingState())
        // The agent's late event for the dropped pairing is not taken.
        m.onEvent(pending())
        #expect(m.state.stage == .idle)
        await m.approve(sessionSeconds: 3600)
        #expect(ops.calls == ["create"])
    }

    @Test func aSecondStartKeepsALiveCodeAndAComparison() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        await m.start()
        #expect(ops.calls == ["create"])
        m.onEvent(pending())
        await m.start()
        #expect(ops.calls == ["create"])
        #expect(compared(m) != nil)
    }

}

extension PairingManagerTests {
    // MARK: A desktop (vettid-android #291)

    @Test func aDesktopCodeAsksForTheDesktopRoleAndTheStateSaysSo() async throws {
        let ops = try desktopOps()
        let m = manager(ops)
        await m.start(.desktop)
        #expect(ops.roles == ["desktop"])
        #expect(code(m) != nil)
        #expect(m.state.role == .desktop)
        // The agent's button still asks for an agent.
        let a = try self.ops()
        await manager(a).start()
        #expect(a.roles == ["agent"])
    }

    @Test func anAgentLinkIsRefusedForADesktopPairingAndTheReverse() async throws {
        let ops = try ops()
        let m = manager(ops)
        // Default (an agent link) for a desktop pairing: never shown.
        await m.start(.desktop)
        #expect(m.state.stage == .idle)
        #expect(m.state.error == .other)
        // A desktop link for an agent pairing: never shown.
        ops.created = try created("p1", .desktop)
        m.acknowledge()
        await m.start(.agent)
        #expect(m.state.stage == .idle)
        #expect(m.state.error == .other)
        // The right kind for each is shown.
        m.acknowledge()
        await m.start(.desktop)
        #expect(code(m) != nil)
    }

    @Test func aDesktopPairingIsComparedAndApprovedWithNoGrants() async throws {
        let ops = try desktopOps()
        let m = manager(ops)
        await m.start(.desktop)
        m.onEvent(pending(name: "Work laptop", role: "desktop"))
        let c = try #require(compared(m))
        #expect(c.comparable)
        #expect(c.sas == "123456")
        #expect(m.state.role == .desktop)
        await approve(m)
        // The approval op has no place for grants: pairing id and the first session only.
        #expect(ops.calls == ["create", "approve:p1:3600"])
        #expect(paired(m) != nil)
        #expect(m.state.role == .desktop)
    }

    @Test func aDesktopPairingWhosePendingIsForAnAgentOrHasNoCodeCanOnlyBeRejected() async throws {
        for (sas, role) in [("123456", "agent"), ("12345", "desktop"), ("abcdef", "desktop")] {
            let ops = try desktopOps()
            let m = manager(ops)
            await m.start(.desktop)
            m.onEvent(pending(sas: sas, role: role))
            #expect(compared(m)?.comparable == false, "\(sas) \(role)")
            await approve(m)
            #expect(ops.calls == ["create"])
            await m.reject()
            #expect(ops.calls == ["create", "reject:p1"])
        }
        // And the agent's pairing refuses a desktop's pending.
        let m = manager(try ops())
        await m.start()
        m.onEvent(pending(role: "desktop"))
        #expect(compared(m)?.comparable == false)
    }

    @Test func aMismatchRejectsADesktopPairing() async throws {
        let ops = try desktopOps()
        let m = manager(ops)
        await m.start(.desktop)
        m.onEvent(pending(role: "desktop"))
        await m.reject()
        #expect(ops.calls == ["create", "reject:p1"])
        #expect(m.state.stage == .rejected(told: true))
    }

    @Test func aDesktopCodeExpiresAndALockClearsIt() async throws {
        let m = manager(try desktopOps())
        await m.start(.desktop)
        await time.advance(seconds: 601)
        guard case .codeExpired = m.state.stage else { Issue.record("not expired"); return }
        #expect(m.state.role == .desktop)
        let n = manager(try desktopOps())
        await n.start(.desktop)
        n.onEvent(pending(role: "desktop"))
        n.clear()
        #expect(n.state == PairingState())
        n.onEvent(pending(role: "desktop"))
        #expect(n.state.stage == .idle)
    }

    @Test func theNewDesktopsIdComesFromTheListAsADesktopNotAnAgent() async throws {
        let m = manager(try desktopOps(), listed: [agent("a1", "Work laptop"), desktopDevice("d1", "Work laptop")])
        await m.start(.desktop)
        m.onEvent(pending(name: "Work laptop", role: "desktop"))
        await approve(m)
        #expect(paired(m)?.deviceID == "d1")
    }

}

extension PairingManagerTests {
    // MARK: Switching between the two

    @Test func theOtherButtonRejectsTheHeldCodeAndReplacesItInOneStep() async throws {
        let ops = try ops()
        try both(ops)
        let m = manager(ops)
        await m.start(.agent)
        #expect(code(m)?.pairingID == "pa")
        await m.start(.desktop)
        // Already the desktop's code: nothing of the agent's is left to read, and the old id is told it is not wanted.
        #expect(m.state.role == .desktop)
        #expect(code(m)?.pairingID == "pd")
        #expect(await eventually { ops.calls.contains("reject:pa") })
        // Only the agent's create comes first for sure, then the other two, once each.
        #expect(ops.calls.first == "create")
        #expect(ops.calls.dropFirst().sorted() == ["create", "reject:pa"])
    }

    @Test func theOtherButtonRejectsAHeldComparisonToo() async throws {
        let ops = try ops()
        try both(ops)
        let m = manager(ops)
        await m.start(.agent)
        m.onEvent(pending("pa"))
        await m.start(.desktop)
        #expect(code(m)?.pairingID == "pd")
        #expect(await eventually { ops.calls.contains("reject:pa") })
    }

    @Test func aCreateOfTheOtherRoleStillInFlightIsSupersededDroppedAndRejected() async throws {
        let ops = try ops()
        try both(ops)
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let first = Task { await m.start(.agent) }
        #expect(await eventually { ops.held.isCompleted })
        #expect(m.state.stage == .creating)
        // The desktop button while the agent's create is out: the desktop code is made, not skipped.
        await m.start(.desktop)
        #expect(code(m)?.pairingID == "pd")
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:pa") })
        await first.value
        // The agent's late answer is dropped (the desktop code is still the one shown) and that pairing is rejected.
        #expect(code(m)?.pairingID == "pd")
        #expect(m.state.role == .desktop)
        #expect(!ops.calls.contains("reject:pd"))
    }

    @Test func aSupersededCreateIsRejectedEvenWhenItsCallerWasCancelled() async throws {
        let ops = try ops()
        try both(ops)
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let first = Task { await m.start(.agent) }
        #expect(await eventually { ops.held.isCompleted })
        first.cancel()
        await m.start(.desktop)
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:pa") })
        #expect(held(m) == "pd")
        #expect(m.state.role == .desktop)
    }

    @Test func aLockDuringCreatingShowsNothingAndRejectsTheAnswerWhenItArrives() async throws {
        let ops = try ops()
        try both(ops)
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let first = Task { await m.start(.agent) }
        #expect(await eventually { ops.held.isCompleted })
        m.clear()
        #expect(m.state == PairingState())
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:pa") })
        await first.value
        // Nothing of it was shown.
        #expect(m.state == PairingState())
        #expect(ops.calls == ["create", "reject:pa"])
    }

    @Test func anApprovalInFlightIsNotSwitchedByTheOtherButton() async throws {
        let ops = try ops()
        try both(ops)
        let m = manager(ops)
        await m.start(.agent)
        m.onEvent(pending("pa"))
        let gate = TestDeferred<Void>()
        ops.holdApprove = gate
        let approving = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.approveEntered.isCompleted })
        let before = m.state
        #expect(before.busy)
        await m.start(.desktop)
        // Nothing changed: the same state and role, and no create (so no new generation either: the approval still settles).
        #expect(m.state == before)
        #expect(m.state.role == .agent)
        #expect(ops.roles == ["agent"])
        gate.complete(())
        // The approval settles as Paired (not dropped by a new generation); its search for the id then needs virtual time.
        #expect(await eventually { paired(m) != nil })
        await time.advance(seconds: 11)
        await approving.value
        #expect(m.state.role == .agent)
    }

    @Test func theSameRoleKeepsAHeldCodeButTheOtherRoleReplacesAComparison() async throws {
        let ops = try ops()
        try both(ops)
        let m = manager(ops)
        await m.start(.agent)
        await m.start(.agent)
        #expect(ops.calls == ["create"])
        m.onEvent(pending("pa"))
        await m.start(.desktop)
        #expect(m.state.role == .desktop)
        #expect(await eventually { ops.calls.contains("reject:pa") })
    }

    @Test func aReadablePairingWithTheWrongKindOrAnUnreadableLinkIsRejectedAtOnceAndNeverShown() async throws {
        struct Case {
            let role: PairRole
            let id: String
            let link: String
        }
        let cases = [
            Case(role: .agent, id: "p1", link: try link(.desktop)), Case(role: .desktop, id: "p2", link: try link(.agent)),
            Case(role: .agent, id: "p3", link: "not a link"), Case(role: .desktop, id: "p4", link: "not a link"),
        ]
        for c in cases {
            let (role, id, bad) = (c.role, c.id, c.link)
            let ops = try ops()
            ops.created = try created(id, link: bad)
            let m = manager(ops)
            await m.start(role)
            // Nothing is shown, and the vault is told this pairing is not wanted (in the manager's scope).
            #expect(m.state.stage == .idle)
            #expect(m.state.error == .other)
            #expect(await eventually { ops.calls.contains("reject:\(id)") })
        }
        // No readable id: nothing to reject.
        let ops = try ops()
        ops.created = try obj(#"{"link":"\#(try link())"}"#)
        let m = manager(ops)
        await m.start(.agent)
        #expect(m.state.stage == .idle)
        #expect(ops.calls == ["create"])
    }

    @Test func pressingTheOtherButtonJustAfterPairedStartsTheOtherPairingAndTheLateSearchTouchesNothing() async throws {
        let ops = try ops()
        try both(ops)
        let m = manager(ops, listed: [desktopDevice("d1", "Work laptop")])
        await m.start(.desktop)
        m.onEvent(pending("pd", name: "Work laptop", role: "desktop"))
        let approving = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { paired(m) != nil })
        // The id search is still waiting (virtual time); the member pairs an agent instead.
        await m.start(.agent)
        #expect(held(m) == "pa")
        #expect(m.state.role == .agent)
        await time.advance(seconds: 11)
        await approving.value
        #expect(m.state.role == .agent)
        // The late search wrote nothing: the agent's code is still the one held.
        #expect(held(m) == "pa")
    }

}

extension PairingManagerTests {
    // MARK: Review fixes

    /// Leaving while "Making a pairing code": nothing is shown, and the answer that comes is rejected, never installed as a live
    /// code that no screen holds.
    @Test func leavingWhileTheCodeIsBeingMadeRejectsItsAnswer() async throws {
        let ops = try ops()
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let starting = Task { await m.start(.agent) }
        #expect(await eventually { ops.held.isCompleted })
        #expect(m.state.stage == .creating)
        await m.cancel()
        #expect(m.state == PairingState())
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:p1") })
        await starting.value
        #expect(m.state == PairingState())
        #expect(ops.calls == ["create", "reject:p1"])
    }

    /// A late answer of a code whose end has passed but whose timer has not run yet is taken, as for an expired one. (This is the test
    /// that pins the change: before it a `.code` took an answer only before its end.)
    @Test func aLateAnswerBeforeTheExpiryTimerRanIsTaken() async throws {
        let m = manager(try ops())
        await m.start()
        // The comparison's timer waits for the end; the clock is past it, within the late minute.
        await time.runCurrent()
        skew.value = 630
        guard case .code = m.state.stage else { Issue.record("the timer ran"); return }
        m.onEvent(pending())
        #expect(compared(m)?.sas == "123456")
    }

    /// Past the late minute it is not taken (the same with or without the change above).
    @Test func anAnswerPastTheLateMinuteIsNotTaken() async throws {
        let m = manager(try ops())
        await m.start()
        await time.runCurrent()
        skew.value = 661
        m.onEvent(pending())
        #expect(compared(m) == nil)
    }

    /// "New code" after an expiry tells the vault that the expired pairing is not wanted.
    @Test func aNewCodeAfterExpiryRejectsTheExpiredPairing() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        await time.advance(seconds: 601)
        ops.created = try created("p2")
        m.acknowledge()
        await m.start()
        #expect(code(m)?.pairingID == "p2")
        // Without the screen's acknowledge in between (the stage is still the expired one):
        let n = try self.ops()
        let other = manager(n)
        await other.start()
        await time.advance(seconds: 601)
        n.created = try created("p3")
        await other.start()
        #expect(code(other)?.pairingID == "p3")
        #expect(await eventually { n.calls.contains("reject:p1") })
    }

    /// Every start is a new pairing: the id search of the one before, still waiting, reads nothing for it.
    @Test func aStartAfterAPairedPairingCutsTheEarlierSearch() async throws {
        let ops = try ops()
        let reads = ReadCounter()
        let base = time.now
        let m = PairingManager(
            ops: { ops }, now: { base() }, sleep: time.sleep, knownDeviceIDs: { ["me"] },
            readDevices: {
                reads.n += 1
                return []
            }
        )
        await m.start()
        m.onEvent(pending())
        let task = Task { await m.approve(sessionSeconds: 3600) }
        await time.advance(seconds: 2)
        #expect(paired(m) != nil)
        // The member reads the end and starts again while the search still waits.
        m.acknowledge()
        ops.created = try created("p2")
        await m.start()
        await time.advance(seconds: 15)
        await task.value
        #expect(reads.n == 0)
        #expect(code(m)?.pairingID == "p2")
    }

    /// An earlier approval's end does not stop the watch of a newer one (a lock, then a new pairing approved).
    @Test func anEarlierApprovalsEndLeavesTheNewerWatchAlone() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let first = Task { await m.approve(sessionSeconds: 3600) }
        await time.advance(seconds: 2)
        #expect(paired(m) != nil)
        m.clear()
        // A new pairing, approved while the earlier search is still ending.
        await m.start()
        m.onEvent(pending())
        let gate = TestDeferred<Void>()
        ops.holdApprove = gate
        ops.onApprove = { m.onEvent(self.paidFeed("agent-B")) }
        let second = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.approveEntered.isCompleted })
        // The earlier search ends now.
        await time.advance(seconds: 1)
        await first.value
        gate.complete(())
        await time.advance(seconds: 11)
        await second.value
        #expect(paired(m)?.deviceID == "agent-B")
    }

    /// "New code" on a code past its end whose timer has not run yet rejects it too: it could be answered for another minute.
    @Test func aNewCodeOnACodePastItsEndBeforeItsTimerRanRejectsIt() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        await time.runCurrent()
        skew.value = 601
        guard case .code = m.state.stage else { Issue.record("the timer ran"); return }
        // The new code lives past the skewed clock.
        let later = t0.addingTimeInterval(900)
        ops.created = try obj(#"{"pairing_id":"p2","link":"\#(try link(exp: later))","exp":"\#(iso(later))"}"#)
        await m.start()
        #expect(code(m)?.pairingID == "p2")
        #expect(await eventually { ops.calls.contains("reject:p1") })
    }

    /// An approval names the comparison it is for: one that is no longer the held one does nothing.
    @Test func anApprovalOfAnotherComparisonDoesNothing() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        // Sent as a task and the time moved on, so that a guard that fails is a count of calls and not a wait.
        let other = Task { await m.approve(pairingID: "other", sessionSeconds: 3600) }
        await time.advance(seconds: 11)
        await other.value
        #expect(ops.calls == ["create"])
        #expect(compared(m) != nil && !m.state.busy)
        await approve(m)
        #expect(ops.calls == ["create", "approve:p1:3600"])
    }

    // MARK: A late leave of an old screen (PairingState.token)

    /// Model A is done and model B starts: A's late leave, with the token it saw, reaches none of B's pairing: not while B's code is
    /// being made, not its code and not its comparison.
    @Test func anOldScreensLateLeaveNeverReachesTheNewerPairing() async throws {
        let ops = try ops()
        let m = manager(ops)
        // Screen A is owner 1, screen B owner 2.
        await m.start(.agent, owner: 1)
        let a = m.state.token
        #expect(code(m) != nil)
        await m.cancel()
        // B starts: its create is held.
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let b = Task { await m.start(.agent, owner: 2) }
        #expect(await eventually { ops.held.isCompleted })
        #expect(m.state.stage == .creating)
        #expect(m.state.token != a)
        m.leave(token: a, owner: 1)
        await time.runCurrent()
        #expect(m.state.stage == .creating, "B's create is not cancelled")
        gate.complete(())
        await b.value
        #expect(code(m) != nil, "B's code stays")
        m.leave(token: a, owner: 1)
        await time.runCurrent()
        #expect(code(m) != nil)
        m.onEvent(pending())
        #expect(compared(m) != nil)
        m.leave(token: a, owner: 1)
        m.acknowledge(token: a, owner: 1)
        await time.runCurrent()
        #expect(compared(m) != nil)
        // Nothing of B's was rejected; A's own cancel rejected A's.
        #expect(ops.calls.filter { $0.hasPrefix("reject") } == ["reject:p1"])
        // A final stage of B's is not acknowledged away by A either; B's own token does.
        await m.reject()
        #expect(m.state.stage == .rejected(told: true))
        m.acknowledge(token: a, owner: 1)
        #expect(m.state.stage == .rejected(told: true))
        m.acknowledge(token: m.state.token, owner: 2)
        #expect(m.state.stage == .idle)
    }

    /// (#242 follow-up) A leave is decided by its owner alone: a token gone stale in a timing gap does not skip it and strand
    /// the code.
    @Test func aLeaveWithAStaleTokenStillEndsItsOwnersPairing() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        let stale = m.state.token - 1
        m.leave(token: stale)
        await time.runCurrent()
        #expect(m.state.stage == .idle)
        #expect(ops.calls.filter { $0.hasPrefix("reject") } == ["reject:p1"])
    }

    /// (#242 follow-up) A screen's start clears an earlier final stage, but not a refused approval another screen kept for
    /// another try: only its owner acknowledges that.
    @Test func aScreensStartDoesNotClearAKeptComparisonsFailure() async throws {
        let ops = try ops()
        ops.refuse["approve"] = "owner_check_required"
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.approve(sessionSeconds: 3600)
        #expect(m.state.error == .ownerCheckRequired)
        m.acknowledge()
        #expect(m.state.error == .ownerCheckRequired, "the unowned acknowledge leaves it")
        m.acknowledge(token: m.state.token, owner: 1)
        #expect(m.state.error == .ownerCheckRequired, "another owner's leaves it")
        m.acknowledge(token: m.state.token)
        #expect(m.state.error == nil)
    }

    /// (#242 follow-up) A leave while a rejection is in flight marks the pairing abandoned; the rejection settling clears it.
    @Test func aSettledRejectionClearsTheAbandonedMark() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let gate = TestDeferred<Void>()
        ops.holdReject = gate
        let r = Task { await m.reject() }
        #expect(await eventually { ops.rejectEntered.isCompleted })
        m.leave(token: m.state.token)
        #expect(await eventually { m.abandoned })
        gate.complete(())
        await r.value
        #expect(m.state.stage == .rejected(told: true))
        #expect(!m.abandoned)
    }

    // MARK: A screen that goes (leave by token)

    /// Back during "Making a pairing code", then the screen released: the answer is rejected and no code is installed.
    @Test func leavingByTokenWhileTheCodeIsBeingMadeRejectsItsAnswer() async throws {
        let ops = try ops()
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let starting = Task { await m.start(.agent) }
        #expect(await eventually { ops.held.isCompleted })
        let token = m.state.token
        m.leave(token: token)
        m.leave(token: token)
        await time.runCurrent()
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:p1") })
        await starting.value
        #expect(m.state == PairingState())
    }

    /// Back on the comparison, then released: it is rejected, and cannot be approved any more.
    @Test func leavingByTokenOnTheComparisonRejectsIt() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let token = m.state.token
        m.leave(token: token)
        #expect(await eventually { ops.calls.contains("reject:p1") })
        #expect(m.state == PairingState())
        await m.approve(sessionSeconds: 3600)
        #expect(!ops.calls.contains { $0.hasPrefix("approve") })
    }

    /// Cancel while the approval is in flight, and the approval then comes back refused with the daily check due: the comparison is
    /// not kept with no screen, it is rejected.
    @Test func anApprovalRefusedForTheDailyCheckAfterItsScreenLeftIsRejected() async throws {
        let ops = try ops()
        ops.refuse["approve"] = "owner_check_required"
        let gate = TestDeferred<Void>()
        ops.holdApprove = gate
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let token = m.state.token
        let approving = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.approveEntered.isCompleted })
        m.leave(token: token)
        await time.runCurrent()
        #expect(compared(m) != nil, "the approval in flight settles it by its answer")
        gate.complete(())
        await approving.value
        #expect(await eventually { ops.calls.contains("reject:p1") })
        #expect(m.state == PairingState())
    }

    /// The same approval that succeeds is paired: the member tapped Approve.
    @Test func anApprovalThatSucceedsAfterItsScreenLeftIsPaired() async throws {
        let ops = try ops()
        let gate = TestDeferred<Void>()
        ops.holdApprove = gate
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        let token = m.state.token
        let approving = Task { await m.approve(sessionSeconds: 3600) }
        #expect(await eventually { ops.approveEntered.isCompleted })
        m.leave(token: token)
        await time.runCurrent()
        gate.complete(())
        await time.advance(seconds: 11)
        await approving.value
        #expect(paired(m) != nil)
        #expect(!ops.calls.contains { $0.hasPrefix("reject") })
    }

    // MARK: Owners

    /// A screen that takes over what is held (a feed item's screen shows the comparison of the one before it): the old screen's late
    /// cleanup rejects nothing of the new owner's; the new owner's own cleanup rejects it, if it is left unapproved.
    @Test func aScreenTakingOverAComparisonIsTheOnlyOneThatCanEndIt() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start(.agent, owner: 1)
        m.onEvent(pending())
        let token = m.state.token
        m.claim(owner: 2)
        m.leave(token: token, owner: 1)
        m.acknowledge(token: token, owner: 1)
        await time.runCurrent()
        #expect(compared(m) != nil, "the old owner's cleanup touches nothing")
        #expect(!ops.calls.contains { $0.hasPrefix("reject") })
        m.leave(token: token, owner: 2)
        #expect(await eventually { ops.calls.contains("reject:p1") })
        #expect(m.state == PairingState())
    }

    /// A final stage is read by its owner only.
    @Test func aFinalStageIsAcknowledgedByItsOwnerOnly() async throws {
        let m = manager(try ops())
        await m.start(.agent, owner: 1)
        m.onEvent(pending())
        m.claim(owner: 2)
        await m.reject()
        #expect(m.state.stage == .rejected(told: true))
        let token = m.state.token
        m.acknowledge(token: token, owner: 1)
        #expect(m.state.stage == .rejected(told: true))
        m.acknowledge(token: token, owner: 2)
        #expect(m.state.stage == .idle)
    }

    /// Screen S approves and goes Back (its approval still in flight); another screen then shows the same comparison. If the approval is
    /// refused for the daily check, the comparison is kept for the new owner, not rejected.
    @Test func aTakeoverOfAnAbandonedComparisonKeepsItWhenTheApprovalIsRefused() async throws {
        for viaStart in [false, true] {
            let ops = try self.ops()
            ops.refuse["approve"] = "owner_check_required"
            let gate = TestDeferred<Void>()
            ops.holdApprove = gate
            let m = manager(ops)
            await m.start(.agent, owner: 1)
            m.onEvent(pending())
            let token = m.state.token
            let approving = Task { await m.approve(sessionSeconds: 3600) }
            #expect(await eventually { ops.approveEntered.isCompleted })
            m.leave(token: token, owner: 1)
            await time.runCurrent()
            if viaStart { await m.start(.agent, owner: 2) } else { m.claim(owner: 2) }
            gate.complete(())
            await approving.value
            #expect(compared(m) != nil, "viaStart \(viaStart)")
            #expect(m.state.error == .ownerCheckRequired)
            #expect(!ops.calls.contains { $0.hasPrefix("reject") })
        }
    }

    /// A screen that left before its first state (no token) still ends what it started: the owner alone decides; another owner's does
    /// nothing.
    @Test func aLeaveWithNoTokenEndsWhatItsOwnerStarted() async throws {
        let ops = try ops()
        let gate = TestDeferred<Void>()
        ops.holdNext = gate
        let m = manager(ops)
        let starting = Task { await m.start(.agent, owner: 1) }
        #expect(await eventually { ops.held.isCompleted })
        m.leave(token: nil, owner: 2)
        await time.runCurrent()
        #expect(m.state.stage == .creating, "another owner's leave does nothing")
        m.leave(token: nil, owner: 1)
        await time.runCurrent()
        gate.complete(())
        #expect(await eventually { ops.calls.contains("reject:p1") })
        await starting.value
        #expect(m.state == PairingState())
    }

    /// A screen's start-up acknowledge leaves an expired code alone (it may still be answered for a minute); the next start rejects it.
    @Test func anAcknowledgeLeavesAnExpiredCodeAndTheNextStartRejectsIt() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start(.agent, owner: 1)
        await time.advance(seconds: 601)
        m.acknowledge()
        guard case .codeExpired = m.state.stage else { Issue.record("cleared"); return }
        ops.created = try created("p2")
        await m.start(.agent, owner: 2)
        #expect(code(m)?.pairingID == "p2")
        #expect(await eventually { ops.calls.contains("reject:p1") })
    }

    /// The same when the new screen starts: it keeps the code already shown (the same role) and owns it from then on.
    @Test func aStartThatKeepsTheShownCodeHandsItToTheNewScreen() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start(.agent, owner: 1)
        let token = m.state.token
        await m.start(.agent, owner: 2)
        #expect(ops.calls == ["create"], "the code is kept")
        #expect(m.state.token == token)
        m.leave(token: token, owner: 1)
        await time.runCurrent()
        #expect(code(m) != nil)
        m.leave(token: token, owner: 2)
        #expect(await eventually { ops.calls.contains("reject:p1") })
        #expect(m.state == PairingState())
    }

    /// Rejecting names the comparison shown: another is not rejected.
    @Test func aRejectionNamesTheComparisonShown() async throws {
        let ops = try ops()
        let m = manager(ops)
        await m.start()
        m.onEvent(pending())
        await m.reject(pairingID: "other")
        #expect(compared(m) != nil && !ops.calls.contains { $0.hasPrefix("reject") })
        await m.reject(pairingID: "p1")
        #expect(m.state.stage == .rejected(told: true))
    }

    // MARK: What the screens rely on (iOS)

    /// A lock during the search for the new device's id stops it: the list is never read afterwards (that could open a session and fill
    /// the list after the clear), and the search ends at once instead of waiting out its ten seconds.
    @Test func aLockDuringTheSearchForTheNewDeviceReadsNothingAndEndsAtOnce() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let reads = ReadCounter()
        let base = time.now
        let m = PairingManager(
            ops: { ops }, now: { base() }, sleep: time.sleep, knownDeviceIDs: { ["me"] },
            readDevices: {
                reads.n += 1
                return []
            }
        )
        await m.start()
        m.onEvent(pending())
        let finished = ReadCounter()
        let task = Task {
            await m.approve(sessionSeconds: 3600)
            finished.n = 1
        }
        await time.advance(seconds: 3)
        #expect(finished.n == 0, "still searching")
        m.clear()
        // Only a second later: a search that kept polling would still be waiting.
        await time.advance(seconds: 1)
        #expect(finished.n == 1)
        await time.advance(seconds: 11)
        await task.value
        #expect(reads.n == 0)
        #expect(m.state == PairingState())
    }

    /// The same when the lock lands as the search's last wait ends: after the ten seconds, before the list is read.
    @Test func aLockJustBeforeTheListIsReadReadsNothing() async throws {
        let ops = try ops()
        ops.onApprove = { throw URLError(.timedOut) }
        let reads = ReadCounter()
        let box = PairingBox()
        let polls = ReadCounter()
        let base = time.now
        let wait = time.sleep
        let m = PairingManager(
            ops: { ops }, now: { base() },
            sleep: { d in
                try await wait(d)
                // The search polls every 250 ms; the lock comes as the last of its 40 waits ends.
                if d == .milliseconds(250) {
                    await MainActor.run {
                        polls.n += 1
                        if polls.n == 40 { box.manager?.clear() }
                    }
                }
            },
            knownDeviceIDs: { ["me"] },
            readDevices: {
                reads.n += 1
                return []
            }
        )
        box.manager = m
        await m.start()
        m.onEvent(pending())
        let task = Task { await m.approve(sessionSeconds: 3600) }
        await time.advance(seconds: 20)
        await task.value
        #expect(polls.n == 40)
        #expect(reads.n == 0)
    }

    /// A pairing's code, digits and name are never in a text form of the state, the stage or the pending (nothing is logged).
    @Test func noStateOfAPairingPrintsACodeADigitOrAName() async throws {
        let m = manager(try ops())
        await m.start()
        let linkText = try #require(code(m)).link
        let texts = [
            "\(m.state)", String(reflecting: m.state), "\(m.state.stage)", String(reflecting: m.state.stage),
        ]
        m.onEvent(pending(name: "Red Team"))
        let after = ["\(m.state)", String(reflecting: m.state.stage), "\(m.state.stage)"]
        for t in texts + after { #expect(!t.contains(linkText) && !t.contains("123456") && !t.contains("Red Team")) }
        await approve(m)
        #expect(paired(m)?.name == "Red Team")
        #expect(!"\(m.state)".contains("Red Team") && !String(reflecting: m.state.stage).contains("Red Team"))
    }
}
// swiftlint:enable line_length file_length
