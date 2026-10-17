import Foundation
import Testing
@testable import VettIDCrypto

/// One vector file from Resources/vectors (copied from vettid-vault, see SOURCE.md). Mirrors vettid-android
/// `VectorDoc`.
struct VectorDoc {
    let o: JsonObject

    func sub(_ k: String) throws -> VectorDoc { VectorDoc(o: try o.obj(k)) }
    func str(_ k: String) throws -> String { try o.string(k) }
    func num(_ k: String) throws -> UInt64 { try o.uint(k, min: 0, max: StrictJson.maxSafeInteger) }
    func hex(_ k: String) throws -> [UInt8] { try Bytes.unhex(str(k)) }
    func b64(_ k: String) throws -> [UInt8] { try Base64s.decodeStd(str(k)) }

    static func load(_ name: String) throws -> VectorDoc {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "vectors"), "missing vector \(name)")
        return VectorDoc(o: try StrictJson.parseObject(Array(try Data(contentsOf: url))))
    }
}

/// n copies of byte [b].
func rep(_ b: UInt8, _ n: Int) -> [UInt8] { [UInt8](repeating: b, count: n) }

/// A deterministic randomness source that hands out [chunks] in order; each draw must request exactly the next
/// chunk's size, so the order of draws is pinned too. Mirrors vettid-android `chunks`.
final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]]

    init(_ chunks: [[UInt8]]) { queue = chunks }

    func next(_ n: Int) -> [UInt8] {
        lock.withLock {
            guard !queue.isEmpty else {
                Issue.record("unexpected random draw of \(n) bytes")
                return [UInt8](repeating: 0, count: n)
            }
            let c = queue.removeFirst()
            #expect(c.count == n, "random draw size")
            return c.count == n ? c : [UInt8](repeating: 0, count: n)
        }
    }
}

/// Runs [body] with deterministic randomness (the §16 test hook).
func deterministic<T>(_ chunks: [UInt8]..., body: () throws -> T) rethrows -> T {
    let source = Chunks(chunks)
    return try Randomness.withDeterministic({ source.next($0) }, body)
}

/// Expects [body] to throw a ``CryptoError`` of [kind].
func expectCrypto(
    _ kind: CryptoError.Kind,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("expected \(kind), nothing thrown. \(comment.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
    } catch let e as CryptoError {
        #expect(e.kind == kind, "\(e) \(comment.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
    }
}
