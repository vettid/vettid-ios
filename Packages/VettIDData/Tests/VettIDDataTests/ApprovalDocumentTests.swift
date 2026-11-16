import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Documents stay on one line each.
// swiftlint:disable line_length

/// The app's checks of an approval's document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): the vector's document
/// passes, and every document vettid-vault's receiver drops (`vms/peerwire` `TestDocumentChecks`) is one the app does not
/// show, as are a document of another hash or size.
@Suite struct ApprovalDocumentTests {
    /// The vector, read from VettIDCrypto's copy (its `Resources/SOURCE.md`).
    static func vector() throws -> JsonObject {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../VettIDCrypto/Tests/VettIDCryptoTests/Resources/vectors/connauth_document.json")
        return try StrictJson.parseObject(Array(try Data(contentsOf: url)))
    }

    static func sha(_ b: [UInt8]) -> String { Base64s.encodeStd(Bytes.sha256(b)) }
    static func ref(_ doc: String) -> String { "ref " + ApprovalDocument.ref(Bytes.sha256(Array(doc.utf8))) }

    /// [doc] checked as fetched for a challenge whose `context` ends with its own reference, and whose hash and size are its
    /// own, unless given.
    func check(_ doc: String, context: String? = nil, sha: String? = nil, size: Int? = nil) -> ApprovalDocument.Failure? {
        let b = Array(doc.utf8)
        let r = ApprovalDocument.check(
            Base64s.encodeStd(b), sha256: sha ?? Self.sha(b), size: size ?? b.count, context: context ?? "Approve — \(Self.ref(doc))"
        )
        if case .failure(let f) = r { return f }
        return nil
    }

    @Test func theVectorsDocumentIsShown() throws {
        let v = try Self.vector()
        let doc = try v.string("document")
        let sha = try v.string("document_sha256_b64")
        let r = ApprovalDocument.check(
            Base64s.encodeStd(Array(doc.utf8)), sha256: sha, size: doc.utf8.count,
            context: try v.string("context")
        )
        guard case .success(let d) = r else { throw CocoaError(.coderInvalidValue) }
        #expect(d.bytes == Array(doc.utf8) && d.sha256 == sha)
        #expect(d.action == "proposal.create" && d.summary == "Adopt the 2027 budget")
        #expect(d.payload.members.map(\.name) == ["binding", "choices", "closes_at", "opens_at", "outage_rule", "quorum", "removed_may_vote", "text", "title"])
    }

    @Test func whatTheVaultDropsIsNotShown() {
        let good = #"{"action":"admin_set.add","payload":{"n":1},"summary":"Add Ann"}"#
        let deep = #"{"action":"a","payload":{"# + String(repeating: #""x":{"#, count: 15) + String(repeating: "}", count: 15) + #"},"summary":""}"#
        let deepOK = #"{"action":"a","payload":{"# + String(repeating: #""x":{"#, count: 14) + String(repeating: "}", count: 14) + #"},"summary":""}"#
        let deep33 = #"{"action":"a","payload":{"# + String(repeating: #""x":{"#, count: 31) + String(repeating: "}", count: 31) + #"},"summary":""}"#
        let pad = { (n: Int) -> String in
            let head = #"{"action":"a","payload":{"x":""#, tail = #""},"summary":""}"#
            return head + String(repeating: "a", count: n - head.utf8.count - tail.utf8.count) + tail
        }
        let edge = #"{"action":""# + String(repeating: "a", count: 64) + #"","payload":{},"summary":""# + String(repeating: "s", count: 1024) + #""}"#
        #expect(check(good) == nil)
        #expect(check(deepOK) == nil, "16 levels")
        #expect(check(pad(65536)) == nil)
        #expect(check(edge) == nil, "a 64-byte action and a 1,024-byte summary")
        let refused: [(String, ApprovalDocument.Failure)] = [
            (pad(65537), .size),
            ("x", .shape), ("[1]", .shape),
            (#"{"action":"a","extra":1,"payload":{},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{}}"#, .shape),
            (#"{"action":"a","payload":[],"summary":""}"#, .shape),
            (#"{"action":"A","payload":{},"summary":""}"#, .shape),
            (#"{"action":"","payload":{},"summary":""}"#, .shape),
            (#"{"action":""# + String(repeating: "a", count: 65) + #"","payload":{},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{},"summary":""# + String(repeating: "s", count: 1025) + #""}"#, .shape),
            (#"{"action":"a","payload":{"x":1,"x":2},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{"x":-1},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{"x":1.5},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{"x":1e3},"summary":""}"#, .shape),
            (#"{"action":"a","payload":{"x":[{"y":9007199254740992}]},"summary":""}"#, .shape),
            (#"{"action":"a-b","payload":{},"summary":""}"#, .shape),
            (#"{"action":"a/b","payload":{},"summary":""}"#, .shape),
            (#"{"action":"é","payload":{},"summary":""}"#, .shape),
            (deep, .shape), (deep33, .shape),
            // The vault refuses a lone surrogate as malformed; decoded here to U+FFFD, it is not its own canonical form.
            (#"{"action":"a","payload":{"x":"\ud800"},"summary":""}"#, .canonical),
            (#"{"payload":{},"action":"a","summary":""}"#, .canonical),
            (#"{"action": "a","payload":{},"summary":""}"#, .canonical),
            (#"{"action":"a","payload":{},"summary":"\u0041"}"#, .canonical),
            (#"{"action":"a","payload":{},"summary":"\/"}"#, .canonical),
            ("\u{FEFF}" + good, .shape),
            (good + " ", .canonical),
        ]
        for (doc, failure) in refused {
            #expect(check(doc) == failure, "\(doc.prefix(60))")
        }
        #expect(check(good, context: "Approve") == .ref)
        #expect(check(good, context: Self.ref(good) + " more") == .ref)
        #expect(check(good, context: Self.ref(good).uppercased()) == .ref)
        #expect(check(good, context: Self.ref(deepOK)) == .ref, "another document's reference")
    }

    @Test func aDocumentOfAnotherHashOrSizeOrEncodingIsNotShown() {
        let good = #"{"action":"a","payload":{},"summary":""}"#
        let b = Array(good.utf8)
        #expect(check(good, sha: Self.sha(Array("other".utf8))) == .hash)
        #expect(check(good, sha: "") == .hash)
        #expect(check(good, sha: Base64s.encodeStd(Array(Bytes.sha256(b).prefix(31)))) == .hash)
        #expect(check(good, size: b.count + 1) == .size)
        #expect(ApprovalDocument.check(Base64s.encodeStd(b), sha256: nil, size: b.count, context: Self.ref(good)) == .failure(.hash))
        #expect(ApprovalDocument.check(Base64s.encodeStd(b), sha256: Self.sha(b), size: nil, context: Self.ref(good)) == .failure(.size))
        #expect(ApprovalDocument.check(Base64s.encodeStd(b), sha256: Self.sha(b), size: b.count, context: nil) == .failure(.ref))
        for bad in ["%%%", String(Base64s.encodeStd(b).dropLast()), Base64s.encodeRawUrl(Array((good + "??>>").utf8)), "e30=\n"] {
            #expect(ApprovalDocument.check(bad, sha256: Self.sha(b), size: b.count, context: Self.ref(good)) == .failure(.encoding))
        }
        // An over-long string that is not even base64 is judged by its length first, as the vault does.
        #expect(ApprovalDocument.check(String(repeating: "%", count: 90000), sha256: Self.sha(b), size: b.count, context: "") == .failure(.size))
    }
}

// swiftlint:enable line_length
