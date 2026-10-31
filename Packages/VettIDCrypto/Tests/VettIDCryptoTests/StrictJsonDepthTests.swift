import Foundation
import Testing
@testable import VettIDCrypto

/// A value copied into a larger document is parsed against the nesting left at its place in that document.
struct StrictJsonDepthTests {
    /// An object nested [depth] deep (depth 1: `{}`).
    static func nested(_ depth: Int) -> [UInt8] {
        Array((String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)).utf8)
    }

    @Test func theDepthLimitIsTheCallersAndTheDefaultIs32() throws {
        _ = try StrictJson.parseObject(Self.nested(32))
        #expect(throws: CryptoError.self) { try StrictJson.parseObject(Self.nested(33)) }
        for limit in [1, 26, 28, 29, 31] {
            _ = try StrictJson.parseObject(Self.nested(limit), maxDepth: limit)
            #expect(throws: CryptoError.self) { try StrictJson.parseObject(Self.nested(limit + 1), maxDepth: limit) }
        }
        // Arrays count too.
        let arrays = Array(("{\"a\":" + String(repeating: "[", count: 27) + String(repeating: "]", count: 27) + "}").utf8)
        _ = try StrictJson.parseObject(arrays, maxDepth: 28)
        #expect(throws: CryptoError.self) { try StrictJson.parseObject(arrays, maxDepth: 27) }
    }

    @Test func aDuplicateNameDeepInsideAndBadUTF8AreRefusedAtAnyLimit() {
        let dup = Array((String(repeating: #"{"a":"#, count: 20) + #"{"k":1,"k":2}"# + String(repeating: "}", count: 20)).utf8)
        #expect(throws: CryptoError.self) { try StrictJson.parseObject(dup, maxDepth: 29) }
        #expect(throws: CryptoError.self) { try StrictJson.compactObject([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D], maxDepth: 29) }
    }

    @Test func compactObjectKeepsTheDepthLimit() throws {
        let ok = try StrictJson.compactObject(Self.nested(26), maxDepth: 26)
        #expect(ok == Self.nested(26))
        #expect(throws: CryptoError.self) { try StrictJson.compactObject(Self.nested(27), maxDepth: 26) }
    }
}
