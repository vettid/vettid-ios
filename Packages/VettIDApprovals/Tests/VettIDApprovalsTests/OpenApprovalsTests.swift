import Foundation
import os
import Testing
@testable import VettIDApprovals
@testable import VettIDData

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// What the approvals indicator and the drawer badge count (ANDROID-PLAN §4 "The approvals indicator" 1, 3, 5; IOS-PLAN
/// §4.12). Mirrors vettid-android `OpenApprovalsTest`; a grant request stands in for its location request (no location
/// requests on iOS), as an entry critical only in its last 2 minutes.
@Suite struct OpenApprovalsTests {
    static let now = Date(timeIntervalSince1970: 1_795_996_800)
    static func sec(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }
    static let names: [String: String] = ["c-a": "Alex", "c-s": "Bank", "c-p": "Shop", "c": "Sam", "c-k": "Kim"]
    static func of(_ list: [PendingApproval], at: Date = now) -> OpenApprovals { OpenApprovalRules.of(list, now: at) { names[$0] } }

    static func auth(_ id: String, _ exp: Date?, _ purpose: AuthenticationPurpose = .absent, conn: String = "c-a", at: Date = now) -> PendingApproval {
        .authentication(AuthenticationRequest(requestID: id, connectionID: conn, context: nil, receivedAt: at, exp: exp, purpose: purpose))
    }

    static func grant(_ id: String, _ exp: Date?, conn: String = "c-k", at: Date = now) -> PendingApproval {
        .grant(GrantRequest(requestID: id, connectionID: conn, entries: [], uses: nil, expiresIn: nil, reason: nil, receivedAt: at, exp: exp))
    }

    static func device(_ type: String, _ exp: Date?) -> PendingApproval {
        .device(DeviceRequest(type: type, id: "d1", deviceName: "Laptop", role: "desktop", requestType: nil, receivedAt: now, exp: exp))
    }

    static func incoming(_ state: RequestState, exp: Date? = nil) -> PendingApproval {
        var r = ConnectionRequest(pendingID: "p-\(state)", sas: "123456", remote: false, name: "Ann Lee", receivedAt: now, exp: exp)
        r.state = state
        return .connection(.incoming(r))
    }

    static func outgoing(_ state: RequestState) -> PendingApproval {
        .connection(.outgoing(OutgoingRequest(connectionID: "o-\(state)", sas: state == .waiting ? nil : "123456", remote: false, name: "Bo", state: state, receivedAt: now, exp: nil)))
    }

    @Test func theCountIsTheEntriesWaitingForThisMembersDecision() {
        let list = [
            Self.grant("open", Self.sec(86_400), conn: "k1"),
            Self.grant("expired", Self.sec(-1), conn: "k2"),
            Self.grant("at its deadline", Self.now, conn: "k3"),
            Self.grant("no deadline", nil, conn: "k4"),
            Self.incoming(.pending),
            // An outgoing request whose safety code waits for this member's Approve counts (owner, GC #17794 a).
            Self.outgoing(.pending),
            // An approved connection waiting for its peer, and an outgoing one before the handshake: not counted.
            Self.incoming(.approved),
            Self.outgoing(.waiting),
            // An outgoing request this member approved, waiting for the other side: not counted.
            Self.outgoing(.approved),
        ]
        #expect(Self.of(list).count == 4)
        #expect(Self.of([]) == OpenApprovals())
    }

    @Test func theLastTwoMinutesAreTimeCritical() {
        #expect(Self.of([Self.grant("g", Self.sec(121))]).critical == nil)
        #expect(Self.of([Self.grant("g", Self.sec(120))]).critical == CriticalApproval(deadline: Self.sec(120), urgent: true, label: "Kim"))
        #expect(Self.of([Self.grant("g", nil)]).critical == nil, "no deadline: never time-critical by the window")
    }

    @Test func challengesSessionsAndHeldRequestsAreTimeCriticalFromArrival() {
        for p in [AuthenticationPurpose.absent, .signin, .approval] {
            #expect(OpenApprovalRules.timeCritical(Self.auth("a", Self.sec(600), p), now: Self.now), "\(p)")
        }
        #expect(OpenApprovalRules.timeCritical(Self.device("device.session.pending", Self.sec(600)), now: Self.now))
        #expect(OpenApprovalRules.timeCritical(Self.device("approval.pending", Self.sec(300)), now: Self.now))
        #expect(!OpenApprovalRules.timeCritical(Self.grant("g", Self.sec(600)), now: Self.now))
        #expect(!OpenApprovalRules.timeCritical(Self.incoming(.pending, exp: Self.sec(600)), now: Self.now))
        // From arrival with no deadline known: the clock alone.
        #expect(Self.of([Self.auth("a", nil)]).critical == CriticalApproval(deadline: nil, urgent: true, label: nil))
    }

    @Test func signInsAloneAreNeutralAndTheSoonestDeadlineIsShown() {
        let signin = Self.auth("s", Self.sec(500), .signin, conn: "c-s")
        #expect(Self.of([signin]).critical == CriticalApproval(deadline: Self.sec(500), urgent: false, label: "Bank"))
        let approval = Self.auth("p", Self.sec(400), .approval, conn: "c-p")
        #expect(Self.of([signin, approval, Self.grant("far", Self.sec(9_000))]).critical == CriticalApproval(deadline: Self.sec(400), urgent: true, label: "Shop"))
        // An urgent entry later than a sign-in: the sign-in's time, in the urgent colors.
        let later = Self.auth("p", Self.sec(590), .approval, conn: "c-p")
        #expect(Self.of([signin, later]).critical == CriticalApproval(deadline: Self.sec(500), urgent: true, label: "Bank"))
    }

    @Test func urgencyAndTheSoonestDeadlineAreJudgedOverTheTimeCriticalEntriesOnly() {
        let signin = Self.auth("s", Self.sec(500), .signin, conn: "c-s")
        // A grant request 300 s away is not time-critical yet: neither its deadline nor its urgency counts.
        #expect(Self.of([signin, Self.grant("g", Self.sec(300))]).critical == CriticalApproval(deadline: Self.sec(500), urgent: false, label: "Bank"))
        // In its last 2 minutes it is: the soonest, and urgent.
        #expect(Self.of([signin, Self.grant("g", Self.sec(100))]).critical == CriticalApproval(deadline: Self.sec(100), urgent: true, label: "Kim"))
    }

    /// A connection's asks within 10 minutes of the first are one batch, one entry (1), as the Approvals list shows them.
    @Test func aBatchCountsAsOne() {
        let a1 = Self.auth("a1", Self.sec(9_000), conn: "c", at: Self.now)
        let a2 = Self.grant("g2", Self.sec(9_000), conn: "c", at: Self.sec(300))
        let later = Self.auth("a3", Self.sec(9_000), conn: "c", at: Self.sec(601))
        let other = Self.auth("a4", Self.sec(9_000), conn: "d", at: Self.sec(60))
        #expect(Self.of([a1, a2]).count == 1)
        #expect(Self.of([a1, a2, later]).count == 2, "a second batch 10 minutes after the first")
        #expect(Self.of([a1, a2, later, other, Self.device("approval.pending", Self.sec(9_000))]).count == 4, "another connection's ask, and an approval that is not an ask")
    }

    /// A connection request names itself (its `name`), so its time left can be said (11).
    @Test func aConnectionRequestIsNamedByItsOwnName() {
        #expect(Self.of([Self.incoming(.pending, exp: Self.sec(100))]).critical?.label == "Ann Lee")
    }

    @Test func aDeviceRequestIsNamedByItsDevice() {
        #expect(Self.of([Self.device("device.session.pending", Self.sec(60))]).critical?.label == "Laptop")
    }

    /// The label is the connection's shown name, cleaned; one with nothing visible names nothing.
    @Test func aConnectionWithoutAVisibleNameNamesNothing() {
        let a = Self.auth("a", Self.sec(60), conn: "x")
        #expect(OpenApprovalRules.of([a], now: Self.now) { _ in " \u{200B} " }.critical?.label == nil)
        #expect(OpenApprovalRules.of([a], now: Self.now) { _ in " Dr\u{202E} Lee " }.critical?.label == "Dr Lee")
    }

    @Test func changesAtEachDeadlineAndTwoMinutesBefore() {
        #expect(OpenApprovalRules.changesAt([Self.grant("g", Self.sec(500)), Self.grant("n", nil), Self.outgoing(.waiting)]) == [Self.sec(380), Self.sec(500)])
    }

    /// A clock whose sleeps move virtual time forward at once; [extra] is time that passes with no sleep (deep sleep).
    final class Virtual: Sendable {
        let t = OSAllocatedUnfairLock(initialState: 0.0)
        var clock: DeadlineClock {
            DeadlineClock(now: { [t] in OpenApprovalsTests.sec(t.withLock { $0 }) }, sleep: { [t] s in t.withLock { $0 += s } })
        }
    }

    @MainActor
    @Test func theClockWakesAtEachPointInOrder() async {
        let v = Virtual()
        var seen: [Date] = []
        await v.clock.run([Self.sec(-5), Self.sec(30), Self.sec(10), Self.sec(30)]) { seen.append($0) }
        #expect(seen == [Self.now, Self.sec(10), Self.sec(30)], "now, then each point still to come in order (one already past adds nothing)")
    }

    /// Started again on return (the caller's part): the sleeps start over from the time then, and points already past add nothing.
    @MainActor
    @Test func aRestartAfterDeepSleepStartsFromTheTimeThen() async {
        let v = Virtual()
        v.t.withLock { $0 = 25 }
        var seen: [Date] = []
        await v.clock.run([Self.sec(10), Self.sec(30)]) { seen.append($0) }
        #expect(seen == [Self.sec(25), Self.sec(30)])
    }

    @MainActor
    @Test func anEntryStopsCountingAtItsDeadlineWithoutARead() async {
        let v = Virtual()
        let list = [Self.grant("soon", Self.sec(200)), Self.grant("g", nil, conn: "k2")]
        var counts: [OpenApprovals] = []
        await v.clock.run(OpenApprovalRules.changesAt(list)) { counts.append(Self.of(list, at: $0)) }
        #expect(counts == [
            OpenApprovals(count: 2),
            OpenApprovals(count: 2, critical: CriticalApproval(deadline: Self.sec(200), urgent: true, label: "Kim")),
            OpenApprovals(count: 1),
        ])
    }

    @MainActor
    @Test func aCancelledClockStopsAtItsSleep() async {
        var seen: [Date] = []
        let clock = DeadlineClock(now: { Self.now }, sleep: { _ in throw CancellationError() })
        await clock.run([Self.sec(10)]) { seen.append($0) }
        #expect(seen == [Self.now])
    }
}

// swiftlint:enable line_length
