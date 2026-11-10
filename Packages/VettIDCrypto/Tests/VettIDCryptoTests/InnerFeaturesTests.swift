import Foundation
import Testing
@testable import VettIDCrypto

/// 0.86.0 (§5.3, §10.8): the inner `features` member round-trips, sits before `body`, and a malformed list is refused
/// like any malformed known member; a message without it is unchanged. Mirrors vettid-vault `TestInnerFeatures`.
struct InnerFeaturesTests {
    private let ts = Date(timeIntervalSince1970: 1_793_836_800) // 2026-11-05T00:00:00Z
    private let id = "01JB2Z6V9K3M4N5P6Q7R8S9T0V"

    @Test func theListRoundTripsBeforeTheBody() throws {
        let j = try Inner(id: id, type: HsTypes.confirm, ts: ts, features: ["hs_confirm", "vote"]).marshal(.sealed)
        #expect(try #require(String(bytes: j, encoding: .utf8)).contains(#""features":["hs_confirm","vote"],"body":{}"#))
        let out = try Inner.parse(j, .sealed)
        #expect(out.features == ["hs_confirm", "vote"])
        // Sealing assigns seq and keeps the list.
        #expect(out.withSeq(7).features == ["hs_confirm", "vote"])
    }

    @Test func anAbsentListIsNotWritten() throws {
        let pj = try Inner(id: id, type: "x.y", ts: ts).marshal(.sealed)
        #expect(!(try #require(String(bytes: pj, encoding: .utf8))).contains("features"))
        #expect(try Inner.parse(pj, .sealed).features == nil)
    }

    @Test func aMalformedListIsRefused() throws {
        let pj = try #require(String(bytes: try Inner(id: id, type: "x.y", ts: ts).marshal(.sealed), encoding: .utf8))
        let bad = [#"[]"#, #"["b","a"]"#, #"["a","a"]"#, #"["A"]"#, #"["a-b"]"#, #"[1]"#, #""a""#, #"[""#
            + String(repeating: "a", count: 33) + #""]"#]
        for b in bad {
            let raw = pj.replacingOccurrences(of: #""body":{}"#, with: #""features":"# + b + #","body":{}"#)
            #expect(throws: CryptoError.self, "accepted \(b)") { _ = try Inner.parse(Array(raw.utf8), .sealed) }
        }
        let tooMany = (0..<33).map { String(format: "f%02d", $0) }
        for b in [[], ["b", "a"], ["x y"], tooMany] {
            #expect(throws: CryptoError.self, "marshalled \(b)") {
                _ = try Inner(id: id, type: "x.y", ts: ts, features: b).marshal(.sealed)
            }
        }
        #expect(Inner.validFeatures(Array(tooMany.prefix(32))))
        #expect(Inner.validFeatures(DeviceFeatures.all))
    }
}
