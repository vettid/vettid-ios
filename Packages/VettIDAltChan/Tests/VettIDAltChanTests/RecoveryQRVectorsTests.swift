import Foundation
import Testing
@testable import VettIDAltChan
import VettIDCrypto

/// The recovery QR payload (§11.11.2) and the transfer QR (§6.7.1) against vectors generated with vettid-vault's Go
/// code (Resources/SOURCE.md). Mirrors vettid-android `RecoveryQrVectorsTest`.
struct RecoveryQRVectorsTests {
    private let doc: JsonObject

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "recovery-qr", withExtension: "json", subdirectory: "vectors"))
        doc = try StrictJson.parseObject(Array(try Data(contentsOf: url)))
    }

    @Test func validPayloadsParseLikeGo() throws {
        let valid = try doc.array("valid").map { try $0.asObject() }
        #expect(valid.count == 3)
        for v in valid {
            let name = try v.string("name")
            let c = try RecoveryCode.parseQR(Array(try v.string("qr").utf8))
            #expect(c.vaultID == (try v.string("vault_id")), "\(name)")
            #expect(c.recoveryID == (try v.string("recovery_id")))
            #expect(c.code == (try v.string("code")))
            #expect(RecoveryCode.parseScanned("  " + (try v.string("qr")) + "\n") == c)
            // The portal's text form, typed back.
            #expect(RecoveryCodes.normalize(try v.string("grouped")) == (try v.string("code")))
            #expect(RecoveryCodes.grouped(try v.string("code")) == (try v.string("grouped")))
        }
    }

    @Test func invalidPayloadsAreRejectedLikeGo() throws {
        let invalid = try doc.array("invalid").map { try $0.asObject() }
        #expect(invalid.count >= 8)
        for v in invalid {
            let name = try v.string("name")
            let qr = try v.string("qr")
            #expect(throws: AltResultError.self, "\(name)") { try RecoveryCode.parseQR(Array(qr.utf8)) }
            #expect(RecoveryCode.parseScanned(qr) == nil, "\(name)")
        }
    }

    @Test func transferQRIsAnAppPairing() throws {
        let t = try doc.obj("transfer")
        let fromJSON = try InviteQr.parse(Array(try t.string("qr").utf8))
        let fromLink = try InviteQr.parseLink(try t.string("link"))
        #expect(fromJSON.kind == .app)
        #expect(try fromJSON.link() == (try t.string("link")))
        #expect(try fromLink.marshal() == Array(try t.string("qr").utf8))
        #expect(fromLink.exp == (try t.uint("exp", min: 1, max: .max)))
    }

    @Test func typedCodes() {
        let code = "SK01TG8WK2FYJ1Y5MEHJ5R5J7QZKWHX0"
        #expect(RecoveryCodes.normalize("sk01-tg8w-k2fy-j1y5-mehj-5r5j-7qzk-whx0") == code)
        #expect(RecoveryCodes.normalize("SKOI TG8W K2FY JLY5 MEHJ 5R5J 7QZK WHXO") == code)
        #expect(RecoveryCodes.normalize(String(code.dropLast())) == nil)
        #expect(RecoveryCodes.normalize(code + "0") == nil)
        #expect(RecoveryCodes.normalize(code.replacingOccurrences(of: "S", with: "U")) == nil) // U is not in the alphabet
        #expect(RecoveryCodes.normalize("") == nil)
        #expect(RecoveryCodes.isValid(code))
        // The code is never printed.
        let c = RecoveryCode(vaultID: "v", recoveryID: "01JA0RECVERY0000000000001X", code: code)
        #expect(!c.description.contains(code))
    }
}
