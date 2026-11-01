import Foundation

/// A member's row of a vote's published results (BALLOT-PROTOCOL §8.2, §8.5): the row `rows.json` holds under the
/// member's record tag, with its inclusion proof to the results' `rows_root`. [ballot] is the row's `ballot` object as
/// the site has it (`vk`, `choice_id`, `ballot_sig`), or nil for an empty row.
public struct OwnRow: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ballot: JsonObject?
    public let index: UInt64
    public let treeSize: UInt64
    public let path: [[UInt8]]

    /// Never the row's ballot (its choice) in a log line.
    public var description: String { "OwnRow(\(index) of \(treeSize))" }
    public var debugDescription: String { description }
}

/// Why the site's results could not be taken as they are: said to the member as a problem with the published results.
/// The reason is a fixed word, never input bytes.
public struct ResultsProblem: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The part of the observer's check (BALLOT-PROTOCOL §8.4) the app does from the site's bytes for
/// `vote.results.submit` (VAULT-MESSAGING §10.19.6 step 1): the hash of `rows.json`, the rows in tag order, the tree
/// they make against `rows_root`, and the member's row. The signature, the anchor and the verdict are the vault's; it
/// never relies on this. Mirrors vettid-android `VoteRows`.
public enum VoteRows {
    /// The most rows read: a ceiling far above any electorate the results can name (the site's results are at most 512 KiB
    /// and a row is about 250 bytes, so about 2,000 rows), small enough to bound the work on a hostile `rows.json`.
    public static let maxRows = 100_000

    private static let keySize = 32
    private static let sigSize = 64
    private static let maxId = 32

    // swiftlint:disable cyclomatic_complexity
    /// Checks [rowsBytes] against [resultsBytes] and returns the row of [recordTag] with its proof. Throws
    /// ``ResultsProblem`` for anything that does not hold, including a tag that has no row.
    public static func ownRow(results resultsBytes: [UInt8], rows rowsBytes: [UInt8], recordTag: [UInt8]) throws -> OwnRow {
        let rowsHash: [UInt8]
        let rowsRoot: [UInt8]
        let eligible: UInt64
        do {
            let results = try StrictJson.parseObject(resultsBytes)
            rowsHash = try results.base64("rows_hash", VoteMerkle.hashSize)
            rowsRoot = try results.base64("rows_root", VoteMerkle.hashSize)
            eligible = try results.obj("counts").uint("eligible", min: 1, max: UInt64(maxRows))
        } catch {
            throw ResultsProblem("results")
        }
        if !Bytes.constantTimeEquals(Bytes.sha256(rowsBytes), rowsHash) { throw ResultsProblem("rows_hash") }
        var leaves: [[UInt8]] = []
        var found = -1
        var foundBallot: JsonObject?
        do {
            let rows = try StrictJson.parseObject(rowsBytes).array("rows")
            if UInt64(rows.count) != eligible { throw ResultsProblem("rows_count") }
            var previous: [UInt8]?
            for (i, e) in rows.enumerated() {
                let row = try e.asObject()
                let tag = try row.base64("record_tag", VoteMerkle.hashSize)
                // Sorted by tag, each once (§8.2): another order is not the tree the root was made over.
                if let previous, !previous.lexicographicallyPrecedes(tag) { throw ResultsProblem("rows_order") }
                previous = tag
                var ballot: JsonObject?
                switch row["ballot"] {
                case nil, .null?: ballot = nil
                case let v?: ballot = try v.asObject()
                }
                leaves.append(try ballot.map { try leaf(tag: tag, ballot: $0) } ?? tag)
                if Bytes.constantTimeEquals(tag, recordTag) {
                    found = i
                    foundBallot = ballot
                }
            }
        } catch let p as ResultsProblem {
            throw p
        } catch {
            throw ResultsProblem("rows")
        }
        if !Bytes.constantTimeEquals(VoteMerkle.root(leaves), rowsRoot) { throw ResultsProblem("rows_root") }
        guard found >= 0 else { throw ResultsProblem("no_row") }
        guard let path = VoteMerkle.proof(leaves, found) else { throw ResultsProblem("rows") }
        return OwnRow(ballot: foundBallot, index: UInt64(found), treeSize: UInt64(leaves.count), path: path)
    }
    // swiftlint:enable cyclomatic_complexity

    /// `ballot_leaf` (§5): `record_tag || lp(vk) || lp(choice_id) || lp(ballot_sig)`, `lp(x) = u16(len x) || x`.
    static func leaf(tag: [UInt8], ballot b: JsonObject) throws -> [UInt8] {
        let vk = try b.base64("vk", keySize)
        let sig = try b.base64("ballot_sig", sigSize)
        let choice = Array(try b.string("choice_id").utf8)
        // [a-z0-9-]{1,32}, as vettid-vault's ValidChoiceID: a row with another id is not one the vault would accept.
        let valid = choice.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
        if choice.isEmpty || choice.count > maxId || !valid { throw ResultsProblem("rows") }
        return Bytes.concat(tag, lp(vk), lp(choice), lp(sig))
    }

    private static func lp(_ x: [UInt8]) -> [UInt8] { Bytes.concat(Bytes.uintBE(UInt64(x.count), 2), x) }
}
