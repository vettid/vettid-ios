import Foundation

/// The Merkle tree of a vote's rows (BALLOT-PROTOCOL §8.2, RFC 6962 §2.1 with SHA-256): leaf hash `H(0x00 || leaf)`,
/// node hash `H(0x01 || left || right)`, split at the largest power of two below n, the empty tree `H("")`. Proofs are
/// audit paths, nearest sibling first, verified per RFC 9162 §2.1.3.2. The app builds its own row's proof from the
/// site's `rows.json` for `vote.results.submit` (VAULT-MESSAGING §10.19.6); the vault verifies it again. Mirrors
/// vettid-android `VoteMerkle`.
public enum VoteMerkle {
    public static let hashSize = 32

    public static func leafHash(_ leaf: [UInt8]) -> [UInt8] { Bytes.sha256([0], leaf) }

    private static func nodeHash(_ l: [UInt8], _ r: [UInt8]) -> [UInt8] { Bytes.sha256([1], l, r) }

    /// The largest power of two below n (n >= 2).
    private static func split(_ n: Int) -> Int {
        var k = 1
        while k << 1 < n { k <<= 1 }
        return k
    }

    /// The tree head over [leaves], in order.
    public static func root(_ leaves: [[UInt8]]) -> [UInt8] {
        leaves.isEmpty ? Bytes.sha256() : rootOf(leaves.map(leafHash)[...])
    }

    private static func rootOf(_ h: ArraySlice<[UInt8]>) -> [UInt8] {
        if h.count == 1 { return h[h.startIndex] }
        let k = split(h.count)
        let mid = h.startIndex + k
        return nodeHash(rootOf(h[h.startIndex..<mid]), rootOf(h[mid...]))
    }

    /// The audit path of the leaf at [index]; nil when [index] is outside [leaves].
    public static func proof(_ leaves: [[UInt8]], _ index: Int) -> [[UInt8]]? {
        guard index >= 0, index < leaves.count else { return nil }
        return path(leaves.map(leafHash)[...], index)
    }

    private static func path(_ h: ArraySlice<[UInt8]>, _ m: Int) -> [[UInt8]] {
        if h.count == 1 { return [] }
        let k = split(h.count)
        let mid = h.startIndex + k
        if m < k { return path(h[h.startIndex..<mid], m) + [rootOf(h[mid...])] }
        return path(h[mid...], m - k) + [rootOf(h[h.startIndex..<mid])]
    }

    /// Whether [leaf] is at [index] of a tree of [size] leaves with head [root]. A path entry that is not 32 bytes
    /// fails.
    public static func verify(root: [UInt8], leaf: [UInt8], index: UInt64, size: UInt64, path: [[UInt8]]) -> Bool {
        guard index < size, root.count == hashSize else { return false }
        var fn = index
        var sn = size - 1
        var r = leafHash(leaf)
        for p in path {
            if sn == 0 || p.count != hashSize { return false }
            if fn & 1 == 1 || fn == sn {
                r = nodeHash(p, r)
                while fn & 1 == 0 && fn != 0 {
                    fn >>= 1
                    sn >>= 1
                }
            } else {
                r = nodeHash(r, p)
            }
            fn >>= 1
            sn >>= 1
        }
        return sn == 0 && Bytes.constantTimeEquals(r, root)
    }
}
