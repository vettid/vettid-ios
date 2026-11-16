import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies stay on one line each.
// swiftlint:disable line_length

/// An approval that carries a document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): the pending ask keeps what the
/// vault says of it, the app fetches and checks it, and approving sends the hash of exactly the bytes it fetched; on
/// `document_not_fetched` it fetches again and approves again only the same bytes.
@MainActor
@Suite struct ApprovalsDocumentFlowTests {
    let ops = FakeApprovalOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    static let doc = #"{"action":"vote.extend","payload":{"closes_at":1796720400,"outage":{"from":1,"source":"relay","to":2},"proposal_id":"p1"},"summary":"Extend"}"#
    static let other = #"{"action":"vote.extend","payload":{"closes_at":1796720401,"outage":{"from":1,"source":"relay","to":2},"proposal_id":"p1"},"summary":"Extend"}"#

    static func b64(_ s: String) -> String { Base64s.encodeStd(Array(s.utf8)) }
    static func sha(_ s: String) -> String { Base64s.encodeStd(Bytes.sha256(Array(s.utf8))) }
    static func ref(_ s: String) -> String { ApprovalDocument.ref(Bytes.sha256(Array(s.utf8))) }

    func manager() -> (ApprovalsManager, () -> [String]) {
        let ops = ops, now = now
        var unlocked: [String] = []
        let c = ConnectionsManager(ops: { FakeConnectionOps() }, now: { now })
        let m = ApprovalsManager(connections: c, ops: { ops }, openUnlockWindow: { unlocked.append($0) }, now: { now })
        return (m, { unlocked })
    }

    func pending(_ m: ApprovalsManager, _ body: String) {
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "connection.authenticate.pending", ts: now, body: Array(body.utf8))))
    }

    var exp: String { Timestamps.formatMillis(now.addingTimeInterval(600)) }

    func challenge(_ doc: String = Self.doc, required: Bool = true, size: Int? = nil) -> String {
        #"{"request_id":"a1","connection_id":"c1","purpose":"approval","context":"Extend a vote — ref \#(Self.ref(doc))","document_sha256":"\#(Self.sha(doc))","document_size":\#(size ?? doc.utf8.count)"# + (required ? #","document_required":true"# : "") + #","exp":"\#(exp)"}"#
    }

    func request(_ m: ApprovalsManager) throws -> AuthenticationRequest {
        guard case .authentication(let r)? = m.approvals.first else { throw CocoaError(.coderValueNotFound) }
        return r
    }

    @Test func thePendingAskKeepsWhatTheVaultSaysOfItsDocument() throws {
        let (m, _) = manager()
        pending(m, challenge())
        let r = try request(m)
        #expect(r.hasDocument && r.documentSha256 == Self.sha(Self.doc) && r.documentSize == Self.doc.utf8.count && r.documentRequired)
        pending(m, #"{"request_id":"a2","connection_id":"c1","purpose":"approval","exp":"\#(exp)"}"#)
        pending(m, #"{"request_id":"a3","connection_id":"c1","purpose":"approval","document_sha256":7,"document_size":"x","document_required":"true","exp":"\#(exp)"}"#)
        let byID = Dictionary(uniqueKeysWithValues: m.approvals.compactMap { a -> (String, AuthenticationRequest)? in
            guard case .authentication(let x) = a else { return nil }
            return (x.requestID, x)
        })
        #expect(byID["a2"]?.hasDocument == false && byID["a2"]?.documentRequired == false)
        // A malformed hash still names a document (never approved without it); it can only fail the checks.
        #expect(byID["a3"]?.hasDocument == true && byID["a3"]?.documentSize == nil && byID["a3"]?.documentRequired == false)
    }

    @Test func approvingSendsTheHashOfTheFetchedBytes() async throws {
        let (m, unlocked) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        #expect(try await m.approveAuthentication(r, password: "pw", document: d) == .approved)
        #expect(unlocked() == ["pw"] && ops.calls == ["authDocument:a1", "authApprove:a1:\(Self.sha(Self.doc))"])
        #expect(m.approvals.isEmpty)
    }

    @Test func aDocumentThatFailsItsChecksIsReturnedNotThrown() async throws {
        let (m, _) = manager()
        pending(m, challenge(size: Self.doc.utf8.count + 1))
        ops.documents = [Self.b64(Self.doc)]
        #expect(try await m.authenticationDocument(try request(m)) == .failure(.size))
        #expect(m.approvals.count == 1)
    }

    @Test func aFetchOfAnAskThatEndedDropsIt() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.errors["authDocument"] = FakeApprovalOps.error("not_found")
        let r = try request(m)
        await #expect(throws: VaultFailure.self) { _ = try await m.authenticationDocument(r) }
        #expect(m.approvals.isEmpty)
    }

    @Test func notFetchedFetchesAgainAndApprovesTheSameBytesOnce() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        ops.errors["authApprove"] = FakeApprovalOps.error("document_not_fetched")
        #expect(try await m.approveAuthentication(r, password: "pw", document: d) == .approved)
        let approve = "authApprove:a1:\(Self.sha(Self.doc))"
        #expect(ops.calls == ["authDocument:a1", approve, "authDocument:a1", approve] && m.approvals.isEmpty)
    }

    @Test func notFetchedWithOtherBytesApprovesNothing() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc), Self.b64(Self.other)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        ops.errors["authApprove"] = FakeApprovalOps.error("document_not_fetched")
        // The other bytes are not the vault's announced hash: they fail the checks, and nothing more is approved.
        #expect(try await m.approveAuthentication(r, password: "pw", document: d) == .changed(.failure(.hash)))
        #expect(ops.calls.filter { $0.hasPrefix("authApprove") }.count == 1 && m.approvals.count == 1)
    }

    @Test func aSecondNotFetchedIsThrownAndKeepsTheAsk() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        ops.errors["authApprove"] = FakeApprovalOps.error("document_not_fetched")
        ops.failAgain["authApprove"] = FakeApprovalOps.error("document_not_fetched")
        await #expect(throws: VaultFailure.self) { _ = try await m.approveAuthentication(r, password: "pw", document: d) }
        #expect(ops.calls.filter { $0.hasPrefix("authApprove") }.count == 2 && m.approvals.count == 1)
    }

    @Test func anAskThatEndedBeforeTheRefetchIsDropped() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        ops.errors["authApprove"] = FakeApprovalOps.error("document_not_fetched")
        ops.errors["authDocument"] = FakeApprovalOps.error("not_found")
        await #expect(throws: VaultFailure.self) { _ = try await m.approveAuthentication(r, password: "pw", document: d) }
        #expect(ops.calls.filter { $0.hasPrefix("authApprove") }.count == 1 && m.approvals.isEmpty)
    }

    @Test func aRefusedApprovalLeavesTheAskOpen() async throws {
        let (m, _) = manager()
        pending(m, challenge())
        ops.documents = [Self.b64(Self.doc)]
        let r = try request(m)
        guard case .success(let d) = try await m.authenticationDocument(r) else { throw CocoaError(.coderInvalidValue) }
        for code in ["bad_request", "update_required", "credential_locked"] {
            ops.errors["authApprove"] = FakeApprovalOps.error(code)
            await #expect(throws: VaultFailure.self) { _ = try await m.approveAuthentication(r, password: "pw", document: d) }
            #expect(m.approvals.count == 1, "\(code)")
        }
    }

    @Test func aChallengeWithADocumentIsNeverApprovedWithoutIt() async throws {
        let (m, unlocked) = manager()
        pending(m, challenge(required: false))
        await #expect(throws: VaultFailure.self) { try await m.approveAuthentication("a1", password: "pw") }
        #expect(ops.calls.isEmpty && unlocked().isEmpty && m.approvals.count == 1)
    }

    @Test func aMalformedHashStillNamesADocument() async throws {
        let (m, _) = manager()
        pending(m, #"{"request_id":"a1","connection_id":"c1","purpose":"approval","context":"x","document_sha256":null,"document_size":\#(Self.doc.utf8.count),"exp":"\#(exp)"}"#)
        let r = try request(m)
        #expect(r.hasDocument && r.documentSha256 == "")
        ops.documents = [Self.b64(Self.doc)]
        #expect(try await m.authenticationDocument(r) == .failure(.hash))
        await #expect(throws: VaultFailure.self) { try await m.approveAuthentication("a1", password: "pw") }
    }

    @Test func anApprovalWithoutADocumentSendsNoHash() async throws {
        let (m, _) = manager()
        pending(m, #"{"request_id":"a1","connection_id":"c1","purpose":"approval","exp":"\#(exp)"}"#)
        try await m.approveAuthentication("a1", password: "pw")
        #expect(ops.calls == ["authApprove:a1"])
    }
}

// swiftlint:enable line_length
