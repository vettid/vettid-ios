import CryptoKit
import Foundation
import Testing
@testable import VettIDCrypto

// swiftlint:disable optional_data_string_conversion

/// RFC 8785 as vettid-vault `vms/jcs` writes it (VAULT-MESSAGING §10.4 "Approval documents"), and the approval document
/// vector (`connauth_document.json`): its document is its own canonical form, its hash is `d`, and the vault's signature
/// is the document form over it.
@Suite struct JcsTests {
    private func canonical(_ s: String) throws -> String {
        String(decoding: try Jcs.canonical(.object(try StrictJson.parseObject(s))), as: UTF8.self)
    }

    @Test func sortsTheMembersByUtf16CodeUnitsAtEveryDepth() throws {
        // U+1F600 is D83D DE00 in UTF-16, before U+E000; by scalar value it would come after.
        #expect(try canonical(#"{"\#u{E000}":1,"\#u{1F600}":2,"b":{"z":[],"a":null}}"#)
            == #"{"b":{"a":null,"z":[]},"\#u{1F600}":2,"\#u{E000}":1}"#)
        #expect(try canonical(#"{"ab":1,"a":2,"B":3}"#) == #"{"B":3,"a":2,"ab":1}"#)
    }

    @Test func escapesAsEcmaScript() throws {
        #expect(try canonical(#"{"s":"\u0041\/\"\\\b\f\n\r\t\u0001\u001f\u007f\u00e9\u2028"}"#)
            == "{\"s\":\"A/\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\u{7F}\u{E9}\u{2028}\"}")
    }

    @Test func writesNoWhiteSpaceAndKeepsArrayOrder() throws {
        #expect(try canonical(" { \"a\" : [ 3 , 1 , 2 ] , \"t\" : true , \"f\" : false } ") == #"{"a":[3,1,2],"f":false,"t":true}"#)
    }

    @Test func refusesEveryNumberButAPlainSafeInteger() throws {
        for n in ["-1", "1.5", "1e3", "9007199254740992"] {
            #expect(throws: CryptoError.self) { try canonical(#"{"n":\#(n)}"#) }
        }
        #expect(try canonical(#"{"n":9007199254740991,"z":0}"#) == #"{"n":9007199254740991,"z":0}"#)
        #expect(Jcs.isInteger("0") && !Jcs.isInteger("007") && !Jcs.isInteger(""))
    }

    @Test func theApprovalDocumentVector() throws {
        let v = try VectorDoc.load("connauth_document.json")
        let document = Array(try v.str("document").utf8)
        #expect(try Jcs.canonical(.object(try StrictJson.parseObject(document))) == document)
        let d = Array(SHA256.hash(data: document))
        #expect(d == (try v.hex("document_sha256_hex")))
        #expect(Base64s.encodeStd(d) == (try v.str("document_sha256_b64")))
        #expect(Array((try v.str("context")).utf8).suffix(16) == Array(Bytes.hex(Array(d.prefix(8))).utf8))

        // The document form: len(purpose) || purpose || d || m, under "vettid/vms/2/conn-auth-document".
        let m = try v.hex("message_document_hex")
        #expect(Array(m.prefix(9 + 32)) == [8] + Array("approval".utf8) + d)
        let label = try v.str("label_document")
        #expect(label == "vettid/vms/2/conn-auth-document")
        let key = try StrictJson.parseObject(try v.str("response_body")).base64("key", 32)
        #expect(Ed25519.verifyRaw(key, Array(label.utf8) + m, try v.b64("sig_b64")))
    }
}

// swiftlint:enable optional_data_string_conversion
