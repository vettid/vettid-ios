import CryptoKit
import Foundation
import VettIDCrypto

/// An approval's document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): the bytes of
/// `JCS({"action", "payload", "summary"})` a service attached to an `approval` challenge, as
/// `connection.authenticate.document` returned them, once they passed the app's checks (``check(_:sha256:size:context:)``).
/// Only a checked document is shown, and the hash an approval sends is ``sha256`` of exactly these bytes, never of a
/// re-serialised form.
public struct ApprovalDocument: Equatable, Sendable {
    /// The bounds of §10.4 "The document", as vettid-vault `vms/peerwire` has them.
    public static let maxBytes = 65536
    public static let maxDepth = 16
    public static let maxSummary = 1024
    public static let maxAction = 64

    /// The document's bytes, exactly as fetched.
    public let bytes: [UInt8]
    /// `d`, SHA-256 of ``bytes``.
    public let d: [UInt8]
    public let action: String
    public let summary: String
    /// `payload`, as parsed (members in the document's order, which is canonical).
    public let payload: JsonObject

    /// The `document_sha256` an approval sends: standard base64 of ``d``.
    public var sha256: String { Data(d).base64EncodedString() }

    public static func == (a: ApprovalDocument, b: ApprovalDocument) -> Bool { a.bytes == b.bytes }

    /// Why a document is not shown: any of these makes the screen say "This request can't be shown" and offer only Deny.
    public enum Failure: Error, Equatable, Sendable {
        /// `document` is not standard base64 with padding.
        case encoding
        /// Over ``maxBytes``, or not `document_size` long.
        case size
        /// Its SHA-256 is not `document_sha256` (or that is not 32 bytes of standard base64).
        case hash
        /// Not strict JSON (§5.3), nested over ``maxDepth``, a number that is not a plain integer within 2^53 − 1, or not
        /// exactly `action`, `payload` and `summary` within their bounds.
        case shape
        /// Not its own RFC 8785 form.
        case canonical
        /// The challenge's `context` does not end with the 16 hex digits of `d[0:8]`.
        case ref
    }

    /// Checks a fetched document as §10.4 asks of the app: [base64] decodes to bytes that are [size] long and hash to
    /// [sha256], and that parse as the receiving vault parsed them (its checks 2 to 4: strict, at most 16 levels with the
    /// document object as level 1, integers only, exactly the three members, canonical, and [context] ending with the
    /// reference).
    public static func check(_ base64: String, sha256: String?, size: Int?, context: String?) -> Result<ApprovalDocument, Failure> {
        guard base64.utf8.count <= (maxBytes + 2) / 3 * 4 else { return .failure(.size) }
        guard let bytes = try? Base64s.decodeStd(base64) else { return .failure(.encoding) }
        guard bytes.count <= maxBytes, let size, bytes.count == size else { return .failure(.size) }
        let d = Array(SHA256.hash(data: bytes))
        guard let sha256, let expected = try? Base64s.decodeStd(sha256, 32), expected == d else { return .failure(.hash) }
        return checkBytes(bytes, context: context)
    }

    /// The checks on the decoded bytes (the vault's 2 to 4).
    static func checkBytes(_ bytes: [UInt8], context: String?) -> Result<ApprovalDocument, Failure> {
        let d = Array(SHA256.hash(data: bytes))
        guard let doc = try? StrictJson.parseObject(bytes, maxDepth: maxDepth), doc.members.count == 3,
              case .string(_, let action)? = doc["action"], case .string(_, let summary)? = doc["summary"],
              case .object(let payload)? = doc["payload"], validAction(action), summary.utf8.count <= maxSummary,
              onlyIntegers(.object(doc))
        else { return .failure(.shape) }
        guard let canonical = try? Jcs.canonical(.object(doc)), canonical == bytes else { return .failure(.canonical) }
        // As bytes, as the vault's strings.HasSuffix compares: a String suffix compares characters, and a character that
        // joins the one before the reference (a prepended mark) would hide a reference the vault finds.
        guard let context, Array(context.utf8).suffix(16) == Array(ref(d).utf8) else { return .failure(.ref) }
        return .success(ApprovalDocument(bytes: bytes, d: d, action: action, summary: summary, payload: payload))
    }

    /// The 16 lower-case hex digits of `d[0:8]` a document's challenge's `context` ends with.
    public static func ref(_ d: [UInt8]) -> String { d.prefix(8).map { String(format: "%02x", $0) }.joined() }

    /// 1 to ``maxAction`` bytes of `[a-z0-9_.]`.
    static func validAction(_ a: String) -> Bool {
        !a.isEmpty && a.utf8.count <= maxAction
            && a.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F || $0 == 0x2E }
    }

    /// Every number, at any depth, a plain integer within 2^53 − 1 (VAULT-MESSAGING 0.90.16 §10.4 check 2).
    static func onlyIntegers(_ v: JsonValue) -> Bool {
        switch v {
        case .number(let raw): Jcs.isInteger(raw)
        case .array(_, let items): items.allSatisfy(onlyIntegers)
        case .object(let o): o.members.allSatisfy { onlyIntegers($0.value) }
        case .string, .bool, .null: true
        }
    }
}

/// How an approval over a document ended (``ApprovalsRepository/approveAuthentication(_:password:document:)``).
public enum DocumentApproval: Equatable, Sendable {
    /// Signed in the document form; the request left the list.
    case approved
    /// The vault had no record of this device fetching the document it showed, and fetching it again did not give the same
    /// bytes: nothing was approved, and the screen starts again from what this holds. Since a challenge's document is fixed
    /// and checked against the hash the ask announced, other bytes always fail the checks, so in practice this is a
    /// failure: "This request can't be shown", Deny only.
    case changed(Result<ApprovalDocument, ApprovalDocument.Failure>)
}
