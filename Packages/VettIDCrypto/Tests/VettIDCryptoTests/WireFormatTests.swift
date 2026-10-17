import Foundation
import Testing
@testable import VettIDCrypto

/// Mirrors the strict JSON, string encoding, timestamp and ULID parts of vettid-android `WireFormatTest` and
/// `WireLocaleTest` (the padding, inner and envelope parts come with I0.4).
struct WireFormatTests {
    private func rejects(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectCrypto(.format, "\(json)", sourceLocation: sourceLocation) { _ = try StrictJson.parseObject(json) }
    }

    @Test func strictJson() throws {
        let o = try StrictJson.parseObject(#" { "a" : 1, "b" : [true, null, "xé\n"], "c": {"d": -1.5e3} } "#)
        #expect(try o.uint("a", min: 0, max: 10) == 1)
        #expect(try o.obj("c").raw == #"{"d": -1.5e3}"#)
        #expect(try o.array("b")[2].asString() == "xé\n")
        rejects(#"{"a":1,"a":2}"#)
        rejects(#"{"a":{"b":1,"b":1}}"#)
        rejects(#"{"a":1} x"#)
        rejects(#"{"a":1}{}"#)
        rejects("[1]")
        rejects(#"{"a":01}"#)
        rejects("{\"a\":\"x\u{01}\"}")
        rejects(#"{"a":"\x"}"#)
        rejects(#"{"a":tru}"#)
        rejects(#"{"a":1,}"#)
        rejects("{\"a\":" + String(repeating: "[", count: 40) + String(repeating: "]", count: 40) + "}")
        expectCrypto(.format) { _ = try StrictJson.parseObject([UInt8(ascii: "{"), 0xFF, UInt8(ascii: "}")]) }
        // Member names are case-sensitive and distinct.
        let ab = try StrictJson.parseObject(#"{"a":1,"A":2}"#)
        #expect(try ab.uint("A", min: 0, max: 9) == 2)
        // Integers: plain, no sign, fraction or exponent, at most 2^53 - 1.
        let n = try StrictJson.parseObject(#"{"a":-1,"b":1.0,"c":1e2,"d":9007199254740991,"e":9007199254740992}"#)
        for k in ["a", "b", "c", "e"] {
            expectCrypto(.format, "\(k)") { _ = try n.uint(k, min: 0, max: .max) }
        }
        #expect(try n.uint("d", min: 0, max: .max) == 9_007_199_254_740_991)
        expectCrypto(.format) { _ = try n.string("a") }
        expectCrypto(.format) { _ = try n.string("missing") }
        // Surrogates: pairs combine, lone ones decode to U+FFFD (as Go).
        let s = try StrictJson.parseObject(#"{"a":"😀","b":"\ud800x","c":"\udc00"}"#)
        #expect(try s.string("a") == "😀")
        #expect(try s.string("b") == "\u{FFFD}x")
        #expect(try s.string("c") == "\u{FFFD}")
    }

    /// Names are compared as bytes, as Go and Kotlin compare them: two spellings of "é" (precomposed and combining)
    /// are two different members, although Swift's `String ==` calls them equal.
    @Test func memberNamesAreBytesNotUnicodeEquivalence() throws {
        let o = try StrictJson.parseObject("{\"\u{E9}\":1,\"e\u{301}\":2}")
        #expect(o.members.count == 2)
        #expect(try o.uint("\u{E9}", min: 0, max: 9) == 1)
        #expect(try o.uint("e\u{301}", min: 0, max: 9) == 2)
        rejects("{\"\u{E9}\":1,\"\u{E9}\":2}")
    }

    @Test func rawTextIsTheSourceBytes() throws {
        let o = try StrictJson.parseObject(#"{"a" : { "x" : "éé" } , "b":[ 1 ,2 ]}"#)
        #expect(try o.obj("a").raw == #"{ "x" : "éé" }"#)
        #expect(o["b"]?.raw == "[ 1 ,2 ]")
        #expect(o.members.map(\.name) == ["a", "b"])
    }

    @Test func goCompatibleStringEncoding() throws {
        let raw = "a\"b\\c\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}<>&\u{2028}\u{2029}é😀"
        #expect(JsonBuilder.quote(raw) == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\u{7F}<>&\\u2028\\u2029é😀\"")
        let b = JsonBuilder()
        b.string("a", "x").uint("b", 3).bool("c", true).raw("d", "{}")
        #expect(b.build() == #"{"a":"x","b":3,"c":true,"d":{}}"#)
        #expect(try StrictJson.compactObject(Array(#" { "a" : [ 1 , 2 ] } "#.utf8)) == Array(#"{"a":[1,2]}"#.utf8))
        #expect(StrictJson.compact(Array(#"{"a": " x "}"#.utf8)) == Array(#"{"a":" x "}"#.utf8))
        #expect(JsonBuilder.array(["1", "\"x\""]) == #"[1,"x"]"#)
    }

    @Test func timestampsAndUlids() throws {
        let t0 = try Timestamps.parseSeconds("2026-10-01T12:00:00Z")
        #expect(Timestamps.formatMillis(t0.addingTimeInterval(0.123456)) == "2026-10-01T12:00:00.123Z")
        #expect(Timestamps.formatSeconds(try Timestamps.parseSeconds("2026-02-28T00:00:00Z")) == "2026-02-28T00:00:00Z")
        for s in ["2026-02-30T00:00:00Z", "2026-1-01T00:00:00Z", "2026-10-01T12:00:00.000Z", "2026-10-01 12:00:00Z"] {
            expectCrypto(.format, "\(s)") { _ = try Timestamps.parseSeconds(s) }
        }
        let badMillis = ["2026-10-01T12:00:00Z", "2026-10-01T12:00:00.1234Z", "2026-10-01T24:00:00.000Z", "2026-10-01T12:00:00.000+00:00"]
        for s in badMillis {
            expectCrypto(.format, "\(s)") { _ = try Timestamps.parseMillis(s) }
        }
        // Milliseconds round-trip exactly, whatever the Double underneath.
        for ms in ["000", "001", "123", "500", "999"] {
            let s = "2026-10-04T12:34:56.\(ms)Z"
            #expect(Timestamps.formatMillis(try Timestamps.parseMillis(s)) == s)
        }
        let u = Ulid.new(t0)
        #expect(Ulid.isValid(u))
        let oneMilli = deterministic(rep(0, 10)) { Ulid.new(Date(timeIntervalSince1970: 0.001)) }
        #expect(oneMilli == "0000000001" + String(repeating: "0", count: 16))
        let entropyOne = deterministic(rep(0, 9) + [1]) { Ulid.new(Date(timeIntervalSince1970: 0)) }
        #expect(entropyOne == "0000000000" + String(repeating: "0", count: 15) + "1")
        #expect(!Ulid.isValid("01JB2Z6V9K3M4N5P6Q7R8S9T0I")) // I is not Crockford
        #expect(!Ulid.isValid("01JB2Z6V9K3M4N5P6Q7R8S9T0"))
        #expect(!Ulid.isValid("81JB2Z6V9K3M4N5P6Q7R8S9T0V"))
    }

    /// The timestamps (§5.3) are ASCII and parse strictly whatever the phone's language. No formatter or locale is
    /// involved in the Swift code; this pins the formats.
    @Test func timestampsAreASCII() throws {
        let t = try Timestamps.parseMillis("2026-10-04T12:34:56.789Z")
        #expect(Timestamps.formatMillis(t) == "2026-10-04T12:34:56.789Z")
        #expect(Timestamps.formatSeconds(t) == "2026-10-04T12:34:56Z")
        #expect(Timestamps.formatMillis(t).utf8.allSatisfy { $0 < 0x80 })
    }
}
