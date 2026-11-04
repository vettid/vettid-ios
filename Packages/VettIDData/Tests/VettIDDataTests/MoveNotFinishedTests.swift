import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// VAULT-MESSAGING 0.83.11 §11.14.10: before the new phone's first unlock from storage the vault answers `transfer_incomplete`
/// to four requests; the app says to finish the move, and never the unlock's text. Mirrors vettid-android
/// `MoveNotFinishedTest` and `MoveNotFinishedApprovalTest`.
@MainActor
@Suite struct MoveNotFinishedTests {
    /// The owner-approved text (2026-11-04), word for word.
    static let approved = "The move to this phone isn't finished. Use Finish the move on this phone, then try again."
    /// The unlock flow's text, which these four requests must never show.
    static let unlockText = "The move to this phone did not finish. Approve it again on your old phone."
    static let types = ["connection.authenticate.approve", "leash.grant.issue", "device.pair.approve", "share.rule.set"]

    private func failure(_ type: String, _ code: String) -> VaultFailure {
        let e = VaultOpError(type: type, code: code, detail: "", body: nil)
        return VaultFailures.map(e) as! VaultFailure // swiftlint:disable:this force_cast
    }

    @Test func theApprovedTextIsWordForWord() {
        #expect(FailureKind.moveNotFinished.message == Self.approved)
        #expect(FailureKind.moveNotFinished.messageKey == "data_failure_move_not_finished")
        #expect(FailureKind.transferIncomplete.message == Self.unlockText)
    }

    @Test func theFourGatedTypesAreTheSetAndEachGivesTheNewKindAndText() {
        #expect(VaultFailures.moveGatedTypes == Set(Self.types))
        for type in Self.types {
            let f = failure(type, "transfer_incomplete")
            #expect(f.kind == .moveNotFinished, "\(type)")
            #expect(f.kind.message == Self.approved && f.kind.message != Self.unlockText, "\(type)")
            #expect(f.code == "transfer_incomplete")
        }
    }

    @Test func anyOtherTypeAndTheUnlockKeepTheUnlockText() {
        for type in ["credential.unlock", "pin.change", "item.get", "connection.authenticate.deny", ""] {
            let f = failure(type, "transfer_incomplete")
            #expect(f.kind == .transferIncomplete && f.kind.message == Self.unlockText, "\(type)")
        }
        // The unlock path maps the code itself, with no request type.
        #expect(VaultFailures.opFailure("transfer_incomplete") == .transferIncomplete)
        // Another code to a gated type is unchanged.
        #expect(failure("share.rule.set", "busy").kind == .busy)
    }

    /// `share.rule.set` for an agent subject, before "Finish the move": the save says so, not the unlock's text.
    @Test func aRuleSaveRefusedTransferIncompleteSaysToFinishTheMove() async throws {
        let ops = FakeSharingOps()
        ops.ruleError = VaultOpError(type: "share.rule.set", code: "transfer_incomplete", detail: "", body: nil)
        let m = SharingManager(ops: { ops })
        var failure: VaultFailure?
        do { try await m.saveRule(RuleDraft(connectionID: "c1", tags: ["a"])) } catch { failure = error as? VaultFailure }
        #expect(failure?.kind == .moveNotFinished && failure?.kind.message == Self.approved)
    }

    /// The challenge stays open after the refusal, so it can be approved again after the move.
    @Test func anApprovalRefusedTransferIncompleteKeepsTheChallenge() async throws {
        let ops = FakeApprovalOps()
        let now = Date(timeIntervalSince1970: 1_791_115_200)
        let connOps = FakeConnectionOps()
        let conns = ConnectionsManager(ops: { connOps }, now: { now })
        let m = ApprovalsManager(connections: conns, ops: { ops }, openUnlockWindow: { _ in }, now: { now })
        let exp = Timestamps.formatMillis(now.addingTimeInterval(600))
        m.onEvent(VaultMessage(inner: Inner(
            id: Ulid.new(), type: "connection.authenticate.pending", ts: now,
            body: Array(#"{"request_id":"a1","connection_id":"c1","exp":"\#(exp)"}"#.utf8)
        )))
        #expect(m.approvals.map(\.key) == ["auth:a1"])
        for _ in 0..<2 {
            ops.errors["authApprove"] = VaultOpError(
                type: "connection.authenticate.approve", code: "transfer_incomplete", detail: "", body: nil
            )
            var kind: FailureKind?
            do { try await m.approveAuthentication("a1", password: "pw") } catch { kind = (error as? VaultFailure)?.kind }
            #expect(kind == .moveNotFinished)
            #expect(m.approvals.map(\.key) == ["auth:a1"])
        }
        #expect(ops.calls == ["authApprove:a1", "authApprove:a1"], "the second approval reached the vault")
        // After the move the same challenge is approved.
        try await m.approveAuthentication("a1", password: "pw")
        #expect(m.approvals.isEmpty)
    }
}
