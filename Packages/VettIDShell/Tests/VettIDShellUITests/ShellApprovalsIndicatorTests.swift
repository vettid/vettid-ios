#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDOnboarding
import VettIDShell
@testable import VettIDShellUI
import VettIDUI

/// The approvals indicator the shell provides (ANDROID-PLAN §4 "The approvals indicator" 1, 2, 6, 8; IOS-PLAN §4.12): its
/// count follows the open approvals, none at 0, while held or due or at the app lock, none for votes, a tap opens the
/// Approvals list, and the drawer badge is the same count. Mirrors vettid-android `ShellApprovalsIndicatorTest`.
@MainActor
@Suite struct ShellApprovalsIndicatorTests {
    let repo = FakeVaultRepository(.unlocked)
    let connections = FakeConnections()
    let votes = FakeVotes()
    let approvals: FakeApprovals
    let model: ShellModel

    init() {
        approvals = FakeApprovals(connections: connections)
        model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
    }

    func shell(gated: Bool = false) -> AppShell {
        let gate = OwnerCheckGate(gated: gated, warning: false, holdOff: false, notices: [], presenceUnrecorded: false)
        return AppShell(
            account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
            model: model, gate: gate, now: Date(), version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
            promptReason: "Unlock VettID", connections: connections, connectionRequests: connections, approvals: approvals,
            votes: votes
        ) {}
    }

    static func grant(_ id: String, conn: String, at: TimeInterval = 0, exp: Date? = nil) -> PendingApproval {
        .grant(GrantRequest(
            requestID: id, connectionID: conn, entries: [], uses: nil, expiresIn: nil, reason: nil,
            receivedAt: Date().addingTimeInterval(at), exp: exp
        ))
    }

    @Test func theCountFollowsTheOpenApprovals() {
        approvals.listed = [Self.grant("g1", conn: "c1")]
        #expect(shell().approvalsIndicator(locked: false)?.count == 1)
        approvals.listed += [Self.grant("g2", conn: "c2"), Self.grant("g3", conn: "c3")]
        #expect(shell().approvalsIndicator(locked: false)?.count == 3)
    }

    @Test func noneAtZeroWhileHeldOrDueOrAtTheAppLock() {
        #expect(shell().approvalsIndicator(locked: false) == nil)
        approvals.listed = [Self.grant("g1", conn: "c1")]
        #expect(shell(gated: true).approvalsIndicator(locked: false) == nil)
        #expect(shell().approvalsIndicator(locked: true) == nil)
        #expect(shell().approvalsIndicator(locked: false) != nil)
    }

    /// An open vote is the Votes badge's, never an approval.
    @Test func votesAreNotCounted() {
        votes.votes = [VoteSummary(proposalID: "p1", connectionID: "c1", title: "Adopt the budget", state: .open)]
        #expect(shell().approvalsIndicator(locked: false) == nil)
        #expect(shell().badges[.approvals] == 0)
    }

    /// Always the list, never the single request, even at 1 (6), from wherever the member is.
    @Test func aTapOpensTheApprovalsList() throws {
        approvals.listed = [Self.grant("g1", conn: "c1")]
        model.navigate(.messages)
        model.path = [.conversation("c1")]
        try #require(shell().approvalsIndicator(locked: false)).onTap()
        #expect(model.destination == .approvals && model.path.isEmpty)
    }

    /// The drawer's Approvals badge is the indicator's count (8): a batch is one, and an expired entry is not counted.
    @Test func theDrawerBadgeIsTheSameCount() {
        approvals.listed = [
            Self.grant("g1", conn: "c1"), Self.grant("g2", conn: "c1", at: 60),
            Self.grant("old", conn: "c2", exp: Date().addingTimeInterval(-1)),
        ]
        let s = shell()
        #expect(s.badges[.approvals] == 1 && s.approvalsIndicator(locked: false)?.count == 1)
    }

    /// Time-critical: the soonest entry's connection by its title, bidi-isolated, and its deadline.
    @Test func aTimeCriticalEntryIsNamedByItsConnection() throws {
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Sam"
        c.lastName = "Lee"
        connections.connections = [c]
        let exp = Date().addingTimeInterval(60)
        approvals.listed = [Self.grant("g1", conn: "c1", exp: exp)]
        let i = try #require(shell().approvalsIndicator(locked: false))
        #expect(i.critical && i.urgent && i.deadline == exp && i.label == "\u{2068}Sam Lee\u{2069}")
    }
}
#endif
