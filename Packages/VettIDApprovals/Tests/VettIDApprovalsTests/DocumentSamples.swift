import Foundation
import VettIDCrypto
@testable import VettIDData

// Documents stay on one line each; the samples are valid UTF-8.
// swiftlint:disable line_length optional_data_string_conversion

/// TEST ONLY. Approval documents and their challenges (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents").
enum DocumentSamples {
    /// The §16 vector's document (vettid-vault `testdata/vectors/connauth_document.json`).
    static let proposal = #"{"action":"proposal.create","payload":{"binding":true,"choices":[{"label":"Yes"},{"label":"No"}],"closes_at":1796720400,"opens_at":1796115600,"outage_rule":"Extended by a relay outage over 1 hour, 24 h at most.","quorum":{"min_ballots":10,"text":"A tenth of the members."},"removed_may_vote":false,"text":"The members adopt the 2027 budget as circulated on 2026-11-20.\nThe board reports on it quarterly.","title":"Adopt the 2027 budget"},"summary":"Adopt the 2027 budget"}"#

    static func ref(_ doc: String) -> String { ApprovalDocument.ref(Bytes.sha256(Array(doc.utf8))) }
    static func context(_ doc: String) -> String { "Approve on Example Service — ref \(ref(canonical(doc)))" }

    /// [doc] in its canonical form (the samples are written for reading; a document is always canonical).
    static func canonical(_ doc: String) -> String {
        guard let o = try? StrictJson.parseObject(doc), let b = try? Jcs.canonical(.object(o)) else { fatalError("sample document") }
        return String(decoding: b, as: UTF8.self)
    }

    /// [doc], canonical, checked as fetched for its own challenge; it must pass.
    static func checked(_ doc: String) -> ApprovalDocument {
        let b = Array(canonical(doc).utf8)
        guard case .success(let d) = ApprovalDocument.check(
            Base64s.encodeStd(b), sha256: Base64s.encodeStd(Bytes.sha256(b)), size: b.count, context: context(doc)
        ) else { fatalError("sample document refused") }
        return d
    }

    /// A pending challenge that names [doc].
    static func request(_ doc: String, id: String = "a1", required: Bool = true) -> AuthenticationRequest {
        let b = Array(canonical(doc).utf8)
        var r = AuthenticationRequest(
            requestID: id, connectionID: "c1", context: context(doc), receivedAt: Date(), exp: nil, purpose: .approval
        )
        r.documentSha256 = Base64s.encodeStd(Bytes.sha256(b))
        r.documentSize = b.count
        r.documentRequired = required
        return r
    }
}

// swiftlint:enable line_length optional_data_string_conversion
