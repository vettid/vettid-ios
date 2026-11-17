import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

/// An approval with a document on its screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): it is fetched when the
/// screen opens, Approve waits until the whole of it has been on screen, approving goes over that document, a document
/// that fails its checks or a fetch that fails offer only Deny, and the decision is made from the request in hand.
@MainActor
@Suite struct ApprovalDocumentViewModelTests {
    let connections = FakeConnections()
    let fake: FakeApprovals
    let request = DocumentSamples.request(DocumentSamples.proposal)
    let document = DocumentSamples.checked(DocumentSamples.proposal)

    init() {
        fake = FakeApprovals(connections: connections)
        fake.listed = [.authentication(request)]
        fake.authDocument = .success(document)
    }

    func model() async -> ApprovalDetailViewModel {
        let m = ApprovalDetailViewModel(key: "auth:a1", approvals: fake, connections: connections)
        await m.settle()
        return m
    }

    @Test func theDocumentIsFetchedAtOpenAndApproveWaitsForItsEnd() async throws {
        let m = await model()
        #expect(fake.calls == ["authenticationDocument:a1"])
        guard case .shown(let d, let p)? = m.state.document else { throw CocoaError(.coderInvalidValue) }
        #expect(d == document && p.asked == .known(.proposalCreate))
        m.setPassword("pw")
        #expect(!m.state.canApprove(), "not before its end was on screen")
        m.approve()
        await m.settle()
        #expect(!fake.calls.contains { $0.hasPrefix("approve") })
        m.documentShownWhole(document.sha256)
        #expect(m.state.canApprove() && m.state.documentToApprove == document)
        m.approve()
        await m.settle()
        #expect(fake.calls.last == "approveAuthenticationDocument:a1" && m.state.done && fake.lastPassword == "pw")
    }

    @Test func aDocumentThatFailsItsChecksOffersOnlyDeny() async {
        fake.authDocument = .failure(.hash)
        let m = await model()
        #expect(m.state.document == .unshowable(.hash))
        m.setPassword("pw")
        m.documentShownWhole(document.sha256)
        #expect(!m.state.canApprove())
        m.deny()
        await m.settle()
        #expect(fake.calls.last == "denyAuthentication:a1" && m.state.done)
    }

    @Test func aFailedFetchIsSaidAndTriedAgain() async {
        fake.fail["authenticationDocument"] = VaultFailure(.noResponse)
        let m = await model()
        #expect(m.state.document == .failed(.noResponse))
        m.retryDocument()
        await m.settle()
        guard case .shown? = m.state.document else { Issue.record("not shown after Try again"); return }
        #expect(fake.calls == ["authenticationDocument:a1", "authenticationDocument:a1"])
    }

    @Test func aChangedDocumentIsShownFromTheStartAndNothingIsApproved() async {
        let m = await model()
        m.setPassword("pw")
        m.documentShownWhole(document.sha256)
        fake.documentApproval = .changed(.failure(.hash))
        m.approve()
        await m.settle()
        #expect(m.state.document == .unshowable(.hash) && m.state.documentSeen == nil && !m.state.done)
        #expect(m.state.error == nil && m.state.password.isEmpty && !m.state.busy && !m.state.canApprove())
    }

    /// The decision is made from the request the screen shows: once the repository no longer holds it, the approval is
    /// still only over its document, never without it.
    @Test func anAskNoLongerHeldIsStillApprovedOnlyOverItsDocument() async {
        let m = await model()
        m.setPassword("pw")
        m.documentShownWhole(document.sha256)
        fake.listed = []
        #expect(m.state.approval != nil && m.state.canApprove())
        m.approve()
        await m.settle()
        #expect(fake.calls.last == "approveAuthenticationDocument:a1" && !fake.calls.contains("approveAuthentication:a1"))
    }

    /// The guard on its own: a document shown and seen whole is not approvable once the request held names another.
    @Test func aDocumentSeenWholeIsNotApprovableForARequestNamingAnother() {
        var s = ApprovalDetailState(key: "auth:a1")
        var other = request
        other.documentSha256 = "bmV3"
        s.approval = .authentication(other)
        s.password = "pw"
        s.document = .shown(document, DocumentPresentation(document, context: nil)!)
        s.documentSeen = document.sha256
        #expect(s.documentToApprove == nil && !s.canApprove())
        s.approval = .authentication(request)
        #expect(s.documentToApprove == document && s.canApprove())
    }

    @Test func aReportAboutAnotherDocumentCountsForNothing() async {
        let m = await model()
        m.setPassword("pw")
        m.documentShownWhole("another hash")
        #expect(!m.state.canApprove() && m.state.documentSeen == nil)
    }

    @Test func onlyDenyIsOfferedWhileNoDocumentIsShown() async {
        fake.fail["authenticationDocument"] = VaultFailure(.noResponse)
        let m = await model()
        #expect(m.state.onlyDeny)
        fake.authDocument = .failure(.size)
        m.retryDocument()
        await m.settle()
        #expect(m.state.onlyDeny)
        fake.authDocument = .success(document)
        let shown = await model()
        #expect(!shown.state.onlyDeny)
    }

    @Test func aRequestThatNamesAnotherDocumentIsFetchedAgain() async {
        let m = await model()
        m.documentShownWhole(document.sha256)
        var changed = request
        changed.documentSha256 = "bmV3"
        fake.authDocument = .failure(.hash)
        fake.listed = [.authentication(changed)]
        await m.settle()
        try? await Task.sleep(for: .milliseconds(50))
        await m.settle()
        #expect(fake.calls.filter { $0 == "authenticationDocument:a1" }.count == 2)
        #expect(m.state.document == .unshowable(.hash) && m.state.documentSeen == nil && !m.state.canApprove())
    }

    @Test func aRequestWithoutADocumentIsApprovedAsBefore() async {
        var plain = request
        plain.documentSha256 = nil
        fake.listed = [.authentication(plain)]
        let m = await model()
        #expect(m.state.document == nil && fake.calls.isEmpty)
        m.setPassword("pw")
        #expect(m.state.canApprove())
        m.approve()
        await m.settle()
        #expect(fake.calls.last == "approveAuthentication:a1" && m.state.done)
    }

    /// The request arrives after the screen opened (from the feed, before the list answered): its document is fetched then.
    @Test func aRequestThatArrivesLaterHasItsDocumentFetched() async {
        fake.listed = []
        let m = await model()
        #expect(m.state.document == nil)
        fake.listed = [.authentication(request)]
        await m.settle()
        try? await Task.sleep(for: .milliseconds(50))
        await m.settle()
        guard case .shown? = m.state.document else { Issue.record("not fetched"); return }
    }
}
